import Foundation
import AVFoundation
import CoreVideo
import CoreImage
import UIKit
import Combine
import Vision
import CoreHaptics
import ARKit
import simd

/// Depth-only TrueDepth manager. Emits a live grayscale UIImage of the
/// current depth buffer plus (optionally auto-computed) min/max Z.
final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published var isRunning = false
    @Published var statusMessage: String?
    @Published var depthImage: UIImage?
    @Published var depthFPS: Int = 0

    /// Visualisation window in meters. Driven either by sliders (manual) or
    /// by the auto-range estimator.
    @Published var minZ: Float = 0.20
    @Published var maxZ: Float = 0.60

    /// When true, minZ/maxZ are recomputed every frame from the depth
    /// distribution. Sliders should be disabled in the UI.
    @Published var autoMode: Bool = true
    @Published var isCalibrating: Bool = false

    /// When true, run Vision hand-pose on the RGB stream and publish landmarks.
    @Published var handMode: Bool = false
    /// Hand joints in normalised display-space coords (0..1, origin top-left),
    /// aligned to the rotated depth view. Grouped per hand.
    @Published var hands: [[CGPoint]] = []

    /// Derived gesture state from the first detected hand.
    @Published var handCenter: CGPoint? = nil   // normalised display-space
    @Published var pinch: CGFloat = 0           // 0..1, distance thumb↔index (display-space units)
    @Published var handZ: Float = 0             // meters, sampled at hand center; 0 if unavailable
    @Published var thumbTip: CGPoint? = nil     // normalised display-space
    @Published var indexTip: CGPoint? = nil
    @Published var pinchZ: Float = 0            // meters, sampled at pinch midpoint

    // Palm-driven state (for ORB mode).
    @Published var palmCenter: CGPoint? = nil
    @Published var palmForward: CGVector = .zero   // unit vector wrist → palm, in display-space
    @Published var fingerSpread: CGFloat = 0       // mean fingertip→palm distance (display units)
    @Published var palmZ: Float = 0                // meters

    // Capture pipeline.
    @Published var lastCapture: VoxelCapture? = nil
    @Published var isCapturing: Bool = false

    // Live voxel cloud (throttled to ~10 Hz while enabled).
    @Published var liveCloudEnabled: Bool = false
    @Published var liveCloud: LiveCloud? = nil
    private var lastLiveStamp: CFTimeInterval = 0
    private var currentRGBBuffer: CVPixelBuffer?
    private let rgbBufferLock = NSLock()

    /// Rear-camera LiDAR mode. When true, the TrueDepth AVCaptureSession
    /// is paused and an ARSession with sceneDepth drives `depthImage`.
    @Published var lidarMode: Bool = false {
        didSet {
            guard oldValue != lidarMode else { return }
            if lidarMode { switchToLidar() } else { switchToTrueDepth() }
        }
    }
    @Published var lidarSupported: Bool = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    private var arSession: ARSession?

    /// Drive the rear torch brightness from the orb spread (0..1). The torch
    /// device is independent from the front TrueDepth session.
    @Published var torchEnabled: Bool = false {
        didSet {
            if !torchEnabled { setTorch(level: 0) }
        }
    }

    /// Drive a continuous CoreHaptics buzz from orb spread + hand depth.
    @Published var hapticsEnabled: Bool = false {
        didSet {
            if hapticsEnabled { startHaptics() } else { stopHaptics() }
        }
    }

    // Eagerly resolved in init() so we don't race on the Swift `lazy` machinery
    // from multiple queues. Read-only after init.
    private var torchDevice: AVCaptureDevice?

    private let torchQueue = DispatchQueue(label: "voxelscanner.torch")
    private var torchQueuedLevel: Float = 0      // only mutated on torchQueue
    private var torchAppliedLevel: Float = -1    // ditto
    private var torchLastApplyStamp: CFTimeInterval = 0
    private var torchHoldingLock: Bool = false

    /// Quantise to 6 steps so tiny finger jitter doesn't cause a fresh hardware
    /// write. The front TrueDepth session + concurrent rear torch writes are a
    /// stress path for AVFoundation — fewer writes = fewer crashes.
    private func quantiseTorchLevel(_ l: Float) -> Float {
        let steps: [Float] = [0, 0.2, 0.4, 0.6, 0.8, 1.0]
        var best = steps[0]
        var bestD = Float.greatestFiniteMagnitude
        for s in steps {
            let d = abs(s - l)
            if d < bestD { bestD = d; best = s }
        }
        return best
    }

    /// Public entry point for the Torch tab's slider.
    func setTorchBrightness(_ level: Float) {
        setTorch(level: level)
    }

    private func setTorch(level: Float) {
        let raw = max(0, min(1, level))
        let target = quantiseTorchLevel(raw)
        torchQueue.async { [weak self] in
            guard let self = self else { return }
            self.torchQueuedLevel = target
            self.applyTorchIfNeeded()
        }
    }

    /// Must run on torchQueue. Applies the queued level if it has changed and
    /// at least 200ms have passed since the last hardware write.
    private func applyTorchIfNeeded() {
        guard let d = torchDevice else { return }
        let now = CACurrentMediaTime()
        let target = torchQueuedLevel
        if target == torchAppliedLevel { return }
        if now - torchLastApplyStamp < 0.2 {
            // Too soon since last write; schedule a trailing apply.
            torchQueue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.applyTorchIfNeeded()
            }
            return
        }
        torchLastApplyStamp = now

        // Defensive: bail if the torch isn't currently available (e.g. thermal).
        if !d.isTorchAvailable {
            NSLog("[VoxelScanner] torch unavailable — skipping write")
            return
        }

        do {
            if target <= 0.01 {
                if torchHoldingLock {
                    if d.torchMode != .off { d.torchMode = .off }
                    d.unlockForConfiguration()
                    torchHoldingLock = false
                } else {
                    try d.lockForConfiguration()
                    if d.torchMode != .off { d.torchMode = .off }
                    d.unlockForConfiguration()
                }
            } else {
                if !torchHoldingLock {
                    try d.lockForConfiguration()
                    torchHoldingLock = true
                }
                try d.setTorchModeOn(level: max(0.01, target))
            }
            torchAppliedLevel = target
        } catch {
            NSLog("[VoxelScanner] torch apply error: \(error)")
            if torchHoldingLock {
                d.unlockForConfiguration()
                torchHoldingLock = false
            }
        }
    }

    private let sessionQueue = DispatchQueue(label: "voxelscanner.session")
    private let dataQueue = DispatchQueue(label: "voxelscanner.data")

    private let depthOutput = AVCaptureDepthDataOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()

    private var frameCount = 0
    private var lastFpsStamp = CACurrentMediaTime()

    // EMA state for auto-range, to keep the visualisation stable frame-to-frame.
    private var emaLo: Float = 0.25
    private var emaHi: Float = 0.55

    private var loggedFirstFrame = false

    // Snapshot of the last depth frame, so the Vision/video delegate can sample
    // Z at a hand joint without re-reading the raw CVPixelBuffer.
    private var lastDepthValues: [Float] = []
    private var lastDepthW: Int = 0
    private var lastDepthH: Int = 0
    private let depthSnapshotLock = NSLock()

    // When > 0, the next N frames snap EMA to the measured range (fast lock),
    // and isCalibrating is published true while this counter is running.
    private var calibrateFramesRemaining: Int = 0

    /// Trigger a fresh auto-range lock: clears EMA history so the next frames
    /// snap to the current scene instead of easing from the old values.
    func recalibrateAuto() {
        dataQueue.async { [weak self] in
            guard let self = self else { return }
            self.calibrateFramesRemaining = 12
            DispatchQueue.main.async { self.isCalibrating = true }
        }
    }

    override init() {
        super.init()
        // Resolve torch device once, on init, on the calling thread (main).
        // Avoids a Swift lazy-var race when setTorch is first called from
        // different queues concurrently.
        if let d = AVCaptureDevice.default(.builtInWideAngleCamera,
                                           for: .video, position: .back),
           d.hasTorch {
            self.torchDevice = d
        } else if let d = AVCaptureDevice.default(for: .video), d.hasTorch {
            self.torchDevice = d
        }
        sessionQueue.async { [weak self] in self?.configure() }
    }

    // MARK: - Setup

    private func configure() {
        NSLog("[VoxelScanner] configure() begin")
        guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera,
                                                   for: .depthData,
                                                   position: .front) else {
            NSLog("[VoxelScanner] NO TrueDepth camera")
            DispatchQueue.main.async { self.statusMessage = "No TrueDepth camera available" }
            return
        }
        NSLog("[VoxelScanner] got device: \(device.localizedName)")

        do {
            let input = try AVCaptureDeviceInput(device: device)

            session.beginConfiguration()
            session.sessionPreset = .photo

            guard session.canAddInput(input) else {
                session.commitConfiguration()
                DispatchQueue.main.async { self.statusMessage = "Cannot add camera input" }
                return
            }
            session.addInput(input)

            guard session.canAddOutput(depthOutput) else {
                session.commitConfiguration()
                DispatchQueue.main.async { self.statusMessage = "Cannot add depth output" }
                return
            }
            session.addOutput(depthOutput)
            depthOutput.isFilteringEnabled = true
            depthOutput.setDelegate(self, callbackQueue: dataQueue)
            depthOutput.connection(with: .depthData)?.isEnabled = true
            if let conn = depthOutput.connection(with: .depthData),
               conn.isCameraIntrinsicMatrixDeliverySupported {
                conn.isCameraIntrinsicMatrixDeliveryEnabled = true
            }

            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
            }

            if let depthFormat = device.activeFormat.supportedDepthDataFormats.first(where: {
                CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
            }) ?? device.activeFormat.supportedDepthDataFormats.first {
                try device.lockForConfiguration()
                device.activeDepthDataFormat = depthFormat
                device.unlockForConfiguration()
                let dims = CMVideoFormatDescriptionGetDimensions(depthFormat.formatDescription)
                DispatchQueue.main.async {
                    self.statusMessage = "Depth \(dims.width)x\(dims.height)"
                }
            }

            session.commitConfiguration()
            NSLog("[VoxelScanner] session configured; preset=\(session.sessionPreset.rawValue) inputs=\(session.inputs.count) outputs=\(session.outputs.count)")
        } catch {
            session.commitConfiguration()
            DispatchQueue.main.async { self.statusMessage = "Setup error: \(error.localizedDescription)" }
        }
    }

    // MARK: - Control

    func start() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.requestAuthorization { granted in
                guard granted else {
                    DispatchQueue.main.async { self.statusMessage = "Camera permission denied" }
                    return
                }
                if !self.session.isRunning {
                    NSLog("[VoxelScanner] startRunning()")
                    self.session.startRunning()
                    NSLog("[VoxelScanner] startRunning returned; isRunning=\(self.session.isRunning)")
                }
                DispatchQueue.main.async {
                    self.isRunning = self.session.isRunning
                    if !self.isRunning { self.statusMessage = "Session failed to start" }
                }
            }
        }
    }

    func stop() {
        setTorch(level: 0)
        stopHaptics()
        arSession?.pause()
        arSession = nil
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    private func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: completion(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video) { completion($0) }
        default: completion(false)
        }
    }

    // MARK: - Haptics

    private var hapticEngine: CHHapticEngine?
    private var hapticPlayer: CHHapticAdvancedPatternPlayer?

    private func startHaptics() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            NSLog("[VoxelScanner] haptics unsupported on this device")
            return
        }
        do {
            if hapticEngine == nil {
                let engine = try CHHapticEngine()
                engine.playsHapticsOnly = true
                engine.isAutoShutdownEnabled = false
                engine.resetHandler = { [weak self] in
                    guard let self = self else { return }
                    try? self.hapticEngine?.start()
                    self.rebuildHapticPlayer()
                    try? self.hapticPlayer?.start(atTime: CHHapticTimeImmediate)
                }
                engine.stoppedHandler = { reason in
                    NSLog("[VoxelScanner] haptic engine stopped: \(reason.rawValue)")
                }
                hapticEngine = engine
            }
            try hapticEngine?.start()
            rebuildHapticPlayer()
            try hapticPlayer?.start(atTime: CHHapticTimeImmediate)
            // Start silent — the video delegate will ramp intensity from spread.
            updateHaptics(intensity: 0, sharpness: 0.5)
            // Quick "on" confirmation pulse so the user knows it's live.
            playConfirmationTap()
        } catch {
            NSLog("[VoxelScanner] haptic start error: \(error)")
        }
    }

    /// Quick ticking pattern fired the instant a capture is requested.
    /// Runs even if continuous haptics are disabled.
    func playCaptureStartFeedback() {
        ensureHapticEngine()
        guard let engine = hapticEngine else { return }
        do {
            let ticks: [CHHapticEvent] = (0..<4).map { i in
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.95)
                    ],
                    relativeTime: TimeInterval(i) * 0.05
                )
            }
            let pattern = try CHHapticPattern(events: ticks, parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            NSLog("[VoxelScanner] capture-start haptic error: \(error)")
        }
    }

    /// Soft low "boom" fired when the capture has finished voxelising.
    func playCaptureDoneFeedback() {
        ensureHapticEngine()
        guard let engine = hapticEngine else { return }
        do {
            let events = [
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.15)
                    ],
                    relativeTime: 0
                ),
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.1)
                    ],
                    relativeTime: 0.05,
                    duration: 0.22
                )
            ]
            let pattern = try CHHapticPattern(events: events, parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            NSLog("[VoxelScanner] capture-done haptic error: \(error)")
        }
    }

    /// Make sure the engine is running — used by the one-shot capture feedbacks
    /// so they work regardless of whether the continuous HAPTIC toggle is on.
    private func ensureHapticEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            if hapticEngine == nil {
                let engine = try CHHapticEngine()
                engine.playsHapticsOnly = true
                engine.isAutoShutdownEnabled = true
                hapticEngine = engine
            }
            try hapticEngine?.start()
        } catch {
            NSLog("[VoxelScanner] haptic ensure error: \(error)")
        }
    }

    private func playConfirmationTap() {
        guard let engine = hapticEngine else { return }
        do {
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7)
                ],
                relativeTime: 0
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let p = try engine.makePlayer(with: pattern)
            try p.start(atTime: CHHapticTimeImmediate)
        } catch {
            NSLog("[VoxelScanner] confirm tap error: \(error)")
        }
    }

    private func rebuildHapticPlayer() {
        do {
            // Base values must be > 0: dynamic parameters are multipliers.
            // value=0 base ⇒ 0 × anything = silent (this was the bug).
            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
            // One long continuous event we modulate via dynamic parameters.
            let event = CHHapticEvent(eventType: .hapticContinuous,
                                      parameters: [intensity, sharpness],
                                      relativeTime: 0,
                                      duration: 60 * 60)  // 1 hour
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            hapticPlayer = try hapticEngine?.makeAdvancedPlayer(with: pattern)
            hapticPlayer?.loopEnabled = true
        } catch {
            NSLog("[VoxelScanner] haptic pattern error: \(error)")
        }
    }

    private func stopHaptics() {
        try? hapticPlayer?.stop(atTime: CHHapticTimeImmediate)
        hapticPlayer = nil
        hapticEngine?.stop(completionHandler: nil)
    }

    /// Modulate the live haptic event. Values are clamped to [0, 1].
    fileprivate func updateHaptics(intensity: Float, sharpness: Float) {
        guard let player = hapticPlayer else { return }
        let i = max(0, min(1, intensity))
        let s = max(0, min(1, sharpness))
        let ip = CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                          value: i,
                                          relativeTime: 0)
        let sp = CHHapticDynamicParameter(parameterID: .hapticSharpnessControl,
                                          value: s,
                                          relativeTime: 0)
        try? player.sendParameters([ip, sp], atTime: CHHapticTimeImmediate)
    }

    // MARK: - Capture pipeline

    /// Latest depth frame snapshot, captured each frame on dataQueue when
    /// a capture is pending. Protected by captureLock.
    private var pendingDepthSnap: DepthSnapshot?
    /// Latest RGB CVPixelBuffer (retained while capture is pending).
    private var pendingRGBBuffer: CVPixelBuffer?
    private var captureRequested: Bool = false
    private let captureLock = NSLock()

    struct DepthSnapshot {
        let values: [Float]
        let width: Int
        let height: Int
        let intrinsics: simd_float3x3
        let intrinsicsReferenceDims: CGSize
    }

    /// User taps the capture button. Next depth frame + next RGB frame are
    /// snapshotted and voxelised on a background queue, result published to
    /// `lastCapture`.
    func captureVoxels() {
        captureLock.lock()
        captureRequested = true
        pendingDepthSnap = nil
        pendingRGBBuffer = nil
        captureLock.unlock()
        DispatchQueue.main.async { self.isCapturing = true }
        playCaptureStartFeedback()
    }

    private func tryFinishCapture() {
        captureLock.lock()
        guard captureRequested,
              let depth = pendingDepthSnap,
              let rgb = pendingRGBBuffer else {
            captureLock.unlock()
            return
        }
        captureRequested = false
        pendingDepthSnap = nil
        pendingRGBBuffer = nil
        captureLock.unlock()

        // Voxelise + JPEG encode on a background queue so we don't block the
        // camera delegate queue.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cap = VoxelCapture.build(depth: depth, rgb: rgb)
            DispatchQueue.main.async {
                self?.lastCapture = cap
                self?.isCapturing = false
                self?.playCaptureDoneFeedback()
            }
        }
    }

    // MARK: - Auto range

    /// Sample the depth buffer sparsely, then take robust percentiles:
    /// - 3rd percentile → near edge of the object (skips sparkle noise)
    /// - 65th percentile → approximate back of the object (skips background wall)
    /// Result is clamped into a sensible arm's-length band and eased via EMA
    /// so sliders don't flicker between frames.
    private func estimateRange(base: UnsafeRawPointer, w: Int, h: Int, rowBytes: Int) -> (Float, Float)? {
        var samples = [Float]()
        samples.reserveCapacity(2000)
        let stride = 3
        var y = 0
        while y < h {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            var x = 0
            while x < w {
                let z = row[x]
                if z.isFinite && z > 0.08 && z < 2.5 {
                    samples.append(z)
                }
                x += stride
            }
            y += stride
        }
        guard samples.count > 80 else { return nil }
        samples.sort()

        func pct(_ p: Double) -> Float { samples[Int(Double(samples.count - 1) * p)] }
        let near = pct(0.05)
        let far  = pct(0.45)

        // Tight window = more colour bits across the subject. Cap hard so a
        // back wall doesn't balloon the range and flatten everything.
        let minWindow: Float = 0.06
        let maxWindow: Float = 0.25
        let nearFloor: Float = 0.10     // sensor noise floor; don't anchor closer than this
        let lo = max(near, nearFloor)
        var hi = max(far, lo + minWindow)
        if hi - lo > maxWindow { hi = lo + maxWindow }
        return (lo, hi)
    }

    // MARK: - Depth → rotated grayscale image

    private func renderRotatedCW(base: UnsafeRawPointer, w: Int, h: Int, rowBytes: Int,
                                 lo: Float, hi: Float) -> UIImage? {
        // Rotate 90° clockwise: source (u, v) → dest (H-1-v, u) in dest of size (H, W).
        let dW = h
        let dH = w
        var bytes = [UInt8](repeating: 0, count: dW * dH * 4) // BGRA

        let range = max(0.001, hi - lo)

        for v in 0..<h {
            let row = base.advanced(by: v * rowBytes).assumingMemoryBound(to: Float.self)
            for u in 0..<w {
                let z = row[u]
                let dx = (h - 1) - v
                let dy = u
                let i = (dy * dW + dx) * 4

                let r: UInt8, g: UInt8, b: UInt8
                if !z.isFinite || z <= 0 {
                    r = 0; g = 0; b = 0
                } else {
                    // 0 = near (hot), 1 = far (cool). Clamp outside window.
                    let t: Float
                    if z < lo { t = 0 }
                    else if z > hi { t = 1 }
                    else { t = (z - lo) / range }
                    (r, g, b) = Self.turbo(t)
                }
                bytes[i + 0] = b
                bytes[i + 1] = g
                bytes[i + 2] = r
                bytes[i + 3] = 255
            }
        }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)
        guard let cg = CGImage(width: dW,
                               height: dH,
                               bitsPerComponent: 8,
                               bitsPerPixel: 32,
                               bytesPerRow: dW * 4,
                               space: cs,
                               bitmapInfo: bitmapInfo,
                               provider: provider,
                               decode: nil,
                               shouldInterpolate: false,
                               intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Approximate Google "Turbo" colormap (Mikhailov 2019) — smooth, perceptually
    /// ordered, high contrast across the whole range. Input t in [0, 1].
    private static func turbo(_ t: Float) -> (UInt8, UInt8, UInt8) {
        let x = max(0, min(1, t))
        // Polynomial fit (good enough for 8-bit display).
        let r = 0.13572138 + x * (4.61539260 + x * (-42.66032258 + x * (132.13108234 + x * (-152.94239396 + x * 59.28637943))))
        let g = 0.09140261 + x * (2.19418839 + x * (4.84296658 + x * (-14.18503333 + x * (4.27729857 + x * 2.82956604))))
        let b = 0.10667330 + x * (12.64194608 + x * (-60.58204836 + x * (110.36276771 + x * (-89.90310912 + x * 27.34824973))))
        func c(_ v: Float) -> UInt8 { UInt8(max(0, min(255, v * 255))) }
        return (c(r), c(g), c(b))
    }
}

// MARK: - LiDAR (ARKit scene-depth) session

extension CameraManager: ARSessionDelegate {
    fileprivate func switchToLidar() {
        guard lidarSupported else {
            DispatchQueue.main.async { self.statusMessage = "LiDAR not supported on this device" }
            return
        }
        // Pause the TrueDepth session so both cameras aren't fighting.
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.session.isRunning { self.session.stopRunning() }

            DispatchQueue.main.async {
                let config = ARWorldTrackingConfiguration()
                config.frameSemantics = [.sceneDepth]
                let s = ARSession()
                s.delegate = self
                s.run(config, options: [.resetTracking, .removeExistingAnchors])
                self.arSession = s
                self.statusMessage = "LIDAR — rear camera · \(ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) ? "smoothed" : "raw")"
                self.isRunning = true
            }
        }
    }

    fileprivate func switchToTrueDepth() {
        // Tear down AR.
        arSession?.pause()
        arSession = nil
        // Resume the TrueDepth session.
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async {
                self.isRunning = self.session.isRunning
            }
        }
    }

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let sceneDepth = frame.sceneDepth else { return }
        let pb = sceneDepth.depthMap
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else {
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            return
        }
        // Auto-range from the depth distribution so the turbo colormap looks
        // good regardless of room size. We reuse estimateRange() as-is.
        var lo = minZ, hi = maxZ
        if autoMode {
            if let range = estimateRange(base: base, w: w, h: h, rowBytes: rowBytes) {
                let alpha: Float = 0.25
                emaLo = emaLo + alpha * (range.0 - emaLo)
                emaHi = emaHi + alpha * (range.1 - emaHi)
                lo = emaLo; hi = emaHi
            }
        }
        let img = renderRotatedCW(base: base, w: w, h: h, rowBytes: rowBytes, lo: lo, hi: hi)
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)

        frameCount += 1
        let now = CACurrentMediaTime()
        let elapsed = now - lastFpsStamp
        let pushFps = elapsed >= 1.0
        let fpsValue = pushFps ? Int(Double(frameCount) / elapsed) : nil
        if pushFps { frameCount = 0; lastFpsStamp = now }

        DispatchQueue.main.async {
            if let img = img { self.depthImage = img }
            if self.autoMode { self.minZ = lo; self.maxZ = hi }
            if let f = fpsValue { self.depthFPS = f }
        }
    }

    public func session(_ session: ARSession, didFailWithError error: Error) {
        NSLog("[VoxelScanner] ARSession failed: \(error)")
        DispatchQueue.main.async {
            self.statusMessage = "LiDAR error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Depth delegate

extension CameraManager: AVCaptureDepthDataOutputDelegate {
    func depthDataOutput(_ output: AVCaptureDepthDataOutput,
                         didOutput depthData: AVDepthData,
                         timestamp: CMTime,
                         connection: AVCaptureConnection) {
        let depth = depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData
            : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)

        let pb = depth.depthDataMap
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        if !loggedFirstFrame {
            loggedFirstFrame = true
            NSLog("[VoxelScanner] FIRST depth frame w=\(w) h=\(h) rowBytes=\(rowBytes) type=\(depth.depthDataType)")
        }
        guard let base = CVPixelBufferGetBaseAddress(pb) else {
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            return
        }

        var lo = minZ, hi = maxZ
        if autoMode {
            if let range = estimateRange(base: base, w: w, h: h, rowBytes: rowBytes) {
                if calibrateFramesRemaining > 0 {
                    // Snap hard on the first calibration frame, then blend fast.
                    let alpha: Float = calibrateFramesRemaining == 12 ? 1.0 : 0.6
                    emaLo = emaLo + alpha * (range.0 - emaLo)
                    emaHi = emaHi + alpha * (range.1 - emaHi)
                    calibrateFramesRemaining -= 1
                    if calibrateFramesRemaining == 0 {
                        DispatchQueue.main.async { self.isCalibrating = false }
                    }
                } else {
                    let alpha: Float = 0.25
                    emaLo = emaLo + alpha * (range.0 - emaLo)
                    emaHi = emaHi + alpha * (range.1 - emaHi)
                }
                lo = emaLo
                hi = emaHi
            }
        }

        let img = renderRotatedCW(base: base, w: w, h: h, rowBytes: rowBytes, lo: lo, hi: hi)

        // Live voxel cloud — throttled to ~10 Hz. Must run while we still hold
        // the depth pixel-buffer lock so we can read raw floats directly.
        if liveCloudEnabled {
            let now = CACurrentMediaTime()
            if now - lastLiveStamp >= 0.1 {
                lastLiveStamp = now
                rgbBufferLock.lock()
                let rgb = currentRGBBuffer
                rgbBufferLock.unlock()
                if let rgb = rgb {
                    var intrinsics = matrix_identity_float3x3
                    var refDims = CGSize(width: CGFloat(w), height: CGFloat(h))
                    if let cal = depth.cameraCalibrationData {
                        intrinsics = cal.intrinsicMatrix
                        refDims = cal.intrinsicMatrixReferenceDimensions
                    }
                    let cloud = LiveCloud.buildFromDepthBuffer(
                        depthBase: base, w: w, h: h, rowBytes: rowBytes,
                        rgb: rgb,
                        intrinsics: intrinsics, intrinsicsReferenceDims: refDims
                    )
                    DispatchQueue.main.async { self.liveCloud = cloud }
                }
            }
        }

        // If a capture is pending, copy the full depth frame + intrinsics.
        captureLock.lock()
        let needDepthSnap = captureRequested && pendingDepthSnap == nil
        captureLock.unlock()
        if needDepthSnap {
            var snap = [Float](repeating: 0, count: w * h)
            snap.withUnsafeMutableBufferPointer { dst in
                for v in 0..<h {
                    let row = base.advanced(by: v * rowBytes).assumingMemoryBound(to: Float.self)
                    for u in 0..<w { dst[v * w + u] = row[u] }
                }
            }
            var intrinsics = matrix_identity_float3x3
            var refDims = CGSize(width: CGFloat(w), height: CGFloat(h))
            if let cal = depth.cameraCalibrationData {
                intrinsics = cal.intrinsicMatrix
                refDims = cal.intrinsicMatrixReferenceDimensions
            }
            captureLock.lock()
            pendingDepthSnap = DepthSnapshot(values: snap, width: w, height: h,
                                             intrinsics: intrinsics,
                                             intrinsicsReferenceDims: refDims)
            captureLock.unlock()
            tryFinishCapture()
        }

        // Snapshot depth values for the hand-Z sampler (cheap: 160x120 = 19,200 floats).
        if handMode {
            var snap = [Float](repeating: 0, count: w * h)
            snap.withUnsafeMutableBufferPointer { dst in
                for v in 0..<h {
                    let row = base.advanced(by: v * rowBytes).assumingMemoryBound(to: Float.self)
                    for u in 0..<w { dst[v * w + u] = row[u] }
                }
            }
            depthSnapshotLock.lock()
            lastDepthValues = snap
            lastDepthW = w
            lastDepthH = h
            depthSnapshotLock.unlock()
        }

        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        guard let img = img else { return }

        frameCount += 1
        let now = CACurrentMediaTime()
        let elapsed = now - lastFpsStamp
        let pushFps = elapsed >= 1.0
        let fpsValue = pushFps ? Int(Double(frameCount) / elapsed) : nil
        if pushFps { frameCount = 0; lastFpsStamp = now }

        DispatchQueue.main.async {
            self.depthImage = img
            if self.autoMode {
                self.minZ = lo
                self.maxZ = hi
            }
            if let f = fpsValue { self.depthFPS = f }
        }
    }

    func depthDataOutput(_ output: AVCaptureDepthDataOutput,
                         didDrop depthData: AVDepthData,
                         timestamp: CMTime,
                         connection: AVCaptureConnection,
                         reason: AVCaptureOutput.DataDroppedReason) {
        NSLog("[VoxelScanner] depth DROPPED reason=\(reason.rawValue)")
    }
}

// MARK: - Depth sampling

extension CameraManager {
    /// Sample median Z in a 5x5 neighbourhood around a normalised display-space
    /// point. Returns 0 if no valid samples are available.
    fileprivate func sampleDepthZ(at p: CGPoint) -> Float {
        depthSnapshotLock.lock()
        defer { depthSnapshotLock.unlock() }
        guard !lastDepthValues.isEmpty else { return 0 }
        let w = lastDepthW, h = lastDepthH
        // Display is rotated 90° CW from the raw buffer: disp_x = vy, disp_y = vx
        // where vx, vy are normalised raw coords. So raw coords from display:
        //   vx = p.y; vy = p.x
        let rawU = Int((p.y) * CGFloat(w))
        let rawV = Int((p.x) * CGFloat(h))
        var samples: [Float] = []
        let k = 2
        for dv in -k...k {
            for du in -k...k {
                let u = rawU + du, v = rawV + dv
                if u < 0 || u >= w || v < 0 || v >= h { continue }
                let z = lastDepthValues[v * w + u]
                if z.isFinite && z > 0.05 && z < 3.0 { samples.append(z) }
            }
        }
        guard !samples.isEmpty else { return 0 }
        samples.sort()
        return samples[samples.count / 2]
    }
}

// MARK: - Live voxel cloud

/// Fast, no-file-export voxelisation path used by the live preview.
struct LiveCloud: Equatable {
    let positions: [SIMD3<Float>]
    let colors: [SIMD3<UInt8>]
    let bboxMin: SIMD3<Float>
    let bboxMax: SIMD3<Float>
    let stamp: CFTimeInterval

    static func == (lhs: LiveCloud, rhs: LiveCloud) -> Bool { lhs.stamp == rhs.stamp }

    static func buildFromDepthBuffer(
        depthBase: UnsafeRawPointer, w: Int, h: Int, rowBytes: Int,
        rgb: CVPixelBuffer,
        intrinsics: simd_float3x3, intrinsicsReferenceDims: CGSize
    ) -> LiveCloud {
        CVPixelBufferLockBaseAddress(rgb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(rgb, .readOnly) }
        let rgbW = CVPixelBufferGetWidth(rgb)
        let rgbH = CVPixelBufferGetHeight(rgb)
        let rgbRowBytes = CVPixelBufferGetBytesPerRow(rgb)
        guard let rgbBase = CVPixelBufferGetBaseAddress(rgb) else {
            return LiveCloud(positions: [], colors: [], bboxMin: .zero, bboxMax: .zero,
                             stamp: CACurrentMediaTime())
        }
        let rgbPtr = rgbBase.assumingMemoryBound(to: UInt8.self)

        let m = intrinsics
        let refW = Float(intrinsicsReferenceDims.width)
        let refH = Float(intrinsicsReferenceDims.height)
        let sX = Float(w) / max(1, refW)
        let sY = Float(h) / max(1, refH)
        let fx = m[0, 0] * sX, fy = m[1, 1] * sY
        let cx = m[2, 0] * sX, cy = m[2, 1] * sY

        let minZ: Float = 0.15, maxZ: Float = 1.2
        let voxelSize: Float = 0.006   // slightly coarser than capture for speed
        // Reject depth edges (occlusion-boundary smearing → stretched ghosts).
        let gradTol: Float = 0.04      // 4 cm absolute neighbour delta

        let rgbSX = Float(rgbW) / Float(w)
        let rgbSY = Float(rgbH) / Float(h)

        struct Bin { var ix: Int; var iy: Int; var iz: Int; var r: Int; var g: Int; var b: Int; var n: Int }
        var bins: [Int64: Bin] = [:]
        bins.reserveCapacity(4096)

        // Edge crop — the outer ~5% of the sensor is noisy.
        let margin = max(2, min(w, h) / 20)
        let vStart = margin, vEnd = h - margin
        let uStart = margin, uEnd = w - margin

        for v in vStart..<vEnd {
            let row = depthBase.advanced(by: v * rowBytes).assumingMemoryBound(to: Float.self)
            let rowAbove = depthBase.advanced(by: (v - 1) * rowBytes).assumingMemoryBound(to: Float.self)
            let rowBelow = depthBase.advanced(by: (v + 1) * rowBytes).assumingMemoryBound(to: Float.self)
            for u in uStart..<uEnd {
                let z = row[u]
                if !z.isFinite || z < minZ || z > maxZ { continue }
                // Gradient filter: skip pixels adjacent to a big depth jump.
                let zL = row[u - 1], zR = row[u + 1]
                let zU = rowAbove[u], zD = rowBelow[u]
                if abs(z - zL) > gradTol || abs(z - zR) > gradTol ||
                   abs(z - zU) > gradTol || abs(z - zD) > gradTol { continue }

                let X = (Float(u) - cx) * z / fx
                let Y = (Float(v) - cy) * z / fy
                let ix = Int((X / voxelSize).rounded())
                let iy = Int((Y / voxelSize).rounded())
                let iz = Int((z / voxelSize).rounded())
                let ru = min(rgbW - 1, max(0, Int(Float(u) * rgbSX)))
                let rv = min(rgbH - 1, max(0, Int(Float(v) * rgbSY)))
                let p = rv * rgbRowBytes + ru * 4
                let b = Int(rgbPtr[p + 0])
                let g = Int(rgbPtr[p + 1])
                let r = Int(rgbPtr[p + 2])
                let key = (Int64(ix) & 0x1FFFFF)
                        | ((Int64(iy) & 0x1FFFFF) << 21)
                        | ((Int64(iz) & 0x1FFFFF) << 42)
                if var bin = bins[key] {
                    bin.r += r; bin.g += g; bin.b += b; bin.n += 1
                    bins[key] = bin
                } else {
                    bins[key] = Bin(ix: ix, iy: iy, iz: iz, r: r, g: g, b: b, n: 1)
                }
            }
        }

        var positions: [SIMD3<Float>] = []
        var colors: [SIMD3<UInt8>] = []
        positions.reserveCapacity(bins.count)
        colors.reserveCapacity(bins.count)
        var mn = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var mx = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        for bin in bins.values {
            let p = SIMD3<Float>(Float(bin.ix), Float(bin.iy), Float(bin.iz)) * voxelSize
            positions.append(p)
            let n = max(1, bin.n)
            colors.append(SIMD3<UInt8>(UInt8(bin.r / n), UInt8(bin.g / n), UInt8(bin.b / n)))
            mn = simd_min(mn, p); mx = simd_max(mx, p)
        }
        return LiveCloud(positions: positions, colors: colors,
                         bboxMin: positions.isEmpty ? .zero : mn,
                         bboxMax: positions.isEmpty ? .zero : mx,
                         stamp: CACurrentMediaTime())
    }
}

// MARK: - Voxel capture

/// Result of a capture press: a point cloud plus the raw files needed by the
/// Three.js `index.html` LOAD CAPTURE flow.
struct VoxelCapture: Identifiable {
    let id = UUID()
    let positions: [SIMD3<Float>]   // meters, camera space (Y down, Z forward)
    let colors: [SIMD3<UInt8>]       // per-voxel RGB 0..255
    let voxelSize: Float
    let bboxMin: SIMD3<Float>
    let bboxMax: SIMD3<Float>

    // Raw files, matching the web loader's folder format.
    let rgbJpeg: Data
    let depthFloat32: Data
    let intrinsicsJson: Data

    // Structured copies of the raw state so volumetric crop can regenerate
    // the depth binary from updated bounds without re-capturing.
    let depthValues: [Float]
    let depthW: Int
    let depthH: Int
    let intrinsicsMatrix: simd_float3x3
    let intrinsicsReferenceDims: CGSize

    static func build(depth: CameraManager.DepthSnapshot, rgb: CVPixelBuffer) -> VoxelCapture {
        // ---- JPEG-encode the RGB frame for sharing.
        let (rgbJpeg, rgbW, rgbH, rgbPixels) = encodeRGB(rgb)

        // ---- Intrinsics, rescaled from reference dims to depth dims.
        let m = depth.intrinsics
        let refW = Float(depth.intrinsicsReferenceDims.width)
        let refH = Float(depth.intrinsicsReferenceDims.height)
        let sX = Float(depth.width) / max(1, refW)
        let sY = Float(depth.height) / max(1, refH)
        let fx = m[0, 0] * sX
        let fy = m[1, 1] * sY
        let cx = m[2, 0] * sX
        let cy = m[2, 1] * sY

        // ---- Voxelise (matches index.html loadCapture to the millimetre).
        let minZ: Float = 0.15
        let maxZ: Float = 1.2
        let voxelSize: Float = 0.004

        struct Bin { var ix: Int; var iy: Int; var iz: Int; var r: Int; var g: Int; var b: Int; var n: Int }
        var bins: [Int64: Bin] = [:]
        bins.reserveCapacity(4096)

        let rgbSX = Float(rgbW) / Float(depth.width)
        let rgbSY = Float(rgbH) / Float(depth.height)
        let dw = depth.width, dh = depth.height

        let gradTol: Float = 0.04
        let margin = max(2, min(dw, dh) / 20)
        let vStart = margin, vEnd = dh - margin
        let uStart = margin, uEnd = dw - margin

        depth.values.withUnsafeBufferPointer { depthPtr in
            rgbPixels.withUnsafeBufferPointer { rgbPtr in
                for v in vStart..<vEnd {
                    for u in uStart..<uEnd {
                        let z = depthPtr[v * dw + u]
                        if !z.isFinite || z < minZ || z > maxZ { continue }
                        // Gradient filter: kill pixels straddling depth edges.
                        let zL = depthPtr[v * dw + (u - 1)]
                        let zR = depthPtr[v * dw + (u + 1)]
                        let zU = depthPtr[(v - 1) * dw + u]
                        let zD = depthPtr[(v + 1) * dw + u]
                        if abs(z - zL) > gradTol || abs(z - zR) > gradTol ||
                           abs(z - zU) > gradTol || abs(z - zD) > gradTol { continue }
                        let X = (Float(u) - cx) * z / fx
                        let Y = (Float(v) - cy) * z / fy
                        let ix = Int((X / voxelSize).rounded())
                        let iy = Int((Y / voxelSize).rounded())
                        let iz = Int((z / voxelSize).rounded())
                        let ru = min(rgbW - 1, max(0, Int(Float(u) * rgbSX)))
                        let rv = min(rgbH - 1, max(0, Int(Float(v) * rgbSY)))
                        let p = (rv * rgbW + ru) * 4
                        // BGRA layout from the video output.
                        let b = Int(rgbPtr[p + 0])
                        let g = Int(rgbPtr[p + 1])
                        let r = Int(rgbPtr[p + 2])
                        // Pack key: iz in top bits, iy in middle, ix in bottom.
                        let key = (Int64(ix) & 0x1FFFFF)
                                | ((Int64(iy) & 0x1FFFFF) << 21)
                                | ((Int64(iz) & 0x1FFFFF) << 42)
                        if var bin = bins[key] {
                            bin.r += r; bin.g += g; bin.b += b; bin.n += 1
                            bins[key] = bin
                        } else {
                            bins[key] = Bin(ix: ix, iy: iy, iz: iz, r: r, g: g, b: b, n: 1)
                        }
                    }
                }
            }
        }

        var positions: [SIMD3<Float>] = []
        var colors: [SIMD3<UInt8>] = []
        positions.reserveCapacity(bins.count)
        colors.reserveCapacity(bins.count)
        var mn = SIMD3<Float>(Float.greatestFiniteMagnitude,
                              Float.greatestFiniteMagnitude,
                              Float.greatestFiniteMagnitude)
        var mx = SIMD3<Float>(-Float.greatestFiniteMagnitude,
                              -Float.greatestFiniteMagnitude,
                              -Float.greatestFiniteMagnitude)
        for bin in bins.values {
            let px = Float(bin.ix) * voxelSize
            let py = Float(bin.iy) * voxelSize
            let pz = Float(bin.iz) * voxelSize
            let p = SIMD3<Float>(px, py, pz)
            positions.append(p)
            let denom = max(1, bin.n)
            colors.append(SIMD3<UInt8>(UInt8(bin.r / denom),
                                       UInt8(bin.g / denom),
                                       UInt8(bin.b / denom)))
            mn = simd_min(mn, p); mx = simd_max(mx, p)
        }

        // ---- Serialise raw depth as little-endian float32.
        let depthFloat32 = depth.values.withUnsafeBufferPointer { Data(buffer: $0) }

        // ---- Intrinsics JSON matching loadCapture().
        let intr: [String: Any] = [
            "depth_width": depth.width,
            "depth_height": depth.height,
            "rgb_width": rgbW,
            "rgb_height": rgbH,
            "intrinsic_matrix_reference_dimensions": [
                Int(depth.intrinsicsReferenceDims.width),
                Int(depth.intrinsicsReferenceDims.height)
            ],
            // Column-major, same as AVCameraCalibrationData.
            "intrinsic_matrix": [
                [m[0, 0], m[0, 1], m[0, 2]],
                [m[1, 0], m[1, 1], m[1, 2]],
                [m[2, 0], m[2, 1], m[2, 2]]
            ]
        ]
        let intrJson = (try? JSONSerialization.data(withJSONObject: intr,
                                                    options: [.prettyPrinted])) ?? Data()

        return VoxelCapture(
            positions: positions,
            colors: colors,
            voxelSize: voxelSize,
            bboxMin: positions.isEmpty ? .zero : mn,
            bboxMax: positions.isEmpty ? .zero : mx,
            rgbJpeg: rgbJpeg,
            depthFloat32: depthFloat32,
            intrinsicsJson: intrJson,
            depthValues: depth.values,
            depthW: depth.width,
            depthH: depth.height,
            intrinsicsMatrix: depth.intrinsics,
            intrinsicsReferenceDims: depth.intrinsicsReferenceDims
        )
    }

    /// Zero-out depth pixels outside the crop volume. Web loader's minZ > 0
    /// filter then drops them automatically, so the uploaded folder produces
    /// the same cropped cloud the user saw in the preview.
    func croppedDepthBinary(cropMin: SIMD3<Float>, cropMax: SIMD3<Float>) -> Data {
        // Skip if crop equals the full bbox — nothing to mask.
        if cropMin == bboxMin && cropMax == bboxMax { return depthFloat32 }

        let m = intrinsicsMatrix
        let refW = Float(intrinsicsReferenceDims.width)
        let refH = Float(intrinsicsReferenceDims.height)
        let sX = Float(depthW) / max(1, refW)
        let sY = Float(depthH) / max(1, refH)
        let fx = m[0, 0] * sX, fy = m[1, 1] * sY
        let cx = m[2, 0] * sX, cy = m[2, 1] * sY

        var out = depthValues
        out.withUnsafeMutableBufferPointer { buf in
            for v in 0..<depthH {
                for u in 0..<depthW {
                    let z = buf[v * depthW + u]
                    if !z.isFinite || z <= 0 { continue }
                    let X = (Float(u) - cx) * z / fx
                    let Y = (Float(v) - cy) * z / fy
                    if X < cropMin.x || X > cropMax.x ||
                       Y < cropMin.y || Y > cropMax.y ||
                       z < cropMin.z || z > cropMax.z {
                        buf[v * depthW + u] = 0
                    }
                }
            }
        }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Write the three capture files to a temp folder and return a zip URL
    /// suitable for UIActivityViewController. If a crop is passed the depth
    /// binary is regenerated with out-of-volume pixels zeroed.
    func writeSharePackage(cropMin: SIMD3<Float>? = nil,
                           cropMax: SIMD3<Float>? = nil) -> URL? {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("capture-\(Int(Date().timeIntervalSince1970))")
        let depthBin: Data = (cropMin != nil && cropMax != nil)
            ? croppedDepthBinary(cropMin: cropMin!, cropMax: cropMax!)
            : depthFloat32
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            try rgbJpeg.write(to: base.appendingPathComponent("rgb.jpg"))
            try depthBin.write(to: base.appendingPathComponent("depth_float32.bin"))
            try intrinsicsJson.write(to: base.appendingPathComponent("intrinsics.json"))
        } catch {
            NSLog("[VoxelScanner] capture write error: \(error)")
            return nil
        }
        // NSFileCoordinator's .forUploading option zips the folder for us —
        // the Apple-sanctioned way to bundle a directory on iOS.
        var zipURL: URL?
        var coordError: NSError?
        let coord = NSFileCoordinator()
        coord.coordinate(readingItemAt: base,
                         options: [.forUploading],
                         error: &coordError) { tempZip in
            // Copy into a stable location so the URL stays valid after the block.
            let dest = fm.temporaryDirectory
                .appendingPathComponent("capture-\(Int(Date().timeIntervalSince1970)).zip")
            try? fm.removeItem(at: dest)
            do {
                try fm.copyItem(at: tempZip, to: dest)
                zipURL = dest
            } catch {
                NSLog("[VoxelScanner] zip copy error: \(error)")
            }
        }
        if let coordError = coordError {
            NSLog("[VoxelScanner] coord error: \(coordError)")
        }
        return zipURL
    }

    // MARK: - RGB helpers

    private static func encodeRGB(_ pb: CVPixelBuffer) -> (Data, Int, Int, [UInt8]) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let src = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h {
                let rowOffset = y * rowBytes
                for x in 0..<(w * 4) {
                    pixels[y * w * 4 + x] = src[rowOffset + x]
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)

        // Encode to JPEG via CoreImage for sharing.
        let ci = CIImage(cvPixelBuffer: pb)
        // Front-camera video buffers arrive landscape + mirrored; apply the
        // right transform so rgb.jpg looks upright when a human opens it.
        // The web loader detects this rotation via intrinsics.rgb_width/
        // height vs the actual JPEG dimensions and samples accordingly.
        let oriented = ci.oriented(.leftMirrored)
        let context = CIContext(options: nil)
        var jpegData = Data()
        if let cg = context.createCGImage(oriented, from: oriented.extent),
           let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.85) {
            jpegData = data
        }
        return (jpegData, w, h, pixels)
    }
}

// MARK: - Video delegate (RGB → Vision hand pose)

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // If a capture was requested, retain the latest RGB buffer and try to
        // finish (we need both depth + RGB snapshots).
        captureLock.lock()
        let needRGB = captureRequested && pendingRGBBuffer == nil
        captureLock.unlock()
        if needRGB {
            captureLock.lock()
            pendingRGBBuffer = pb
            captureLock.unlock()
            tryFinishCapture()
        }

        // Keep a current-RGB reference for the live voxel pipeline.
        if liveCloudEnabled {
            rgbBufferLock.lock()
            currentRGBBuffer = pb
            rgbBufferLock.unlock()
        }

        guard handMode else { return }

        // TrueDepth front camera, device in portrait: buffer native orientation
        // is landscape-right AND mirrored (selfie). `.leftMirrored` tells Vision
        // to rotate + unmirror so its output is upright and un-flipped.
        let handler = VNImageRequestHandler(cvPixelBuffer: pb,
                                            orientation: .leftMirrored,
                                            options: [:])
        do {
            try handler.perform([handRequest])
            let observations = handRequest.results ?? []
            var out: [[CGPoint]] = []
            var center: CGPoint? = nil
            var pinchDist: CGFloat = 0
            var centerZ: Float = 0
            var thumbPt: CGPoint? = nil
            var indexPt: CGPoint? = nil
            var pinchZv: Float = 0
            var palmC: CGPoint? = nil
            var palmFwd: CGVector = .zero
            var spreadV: CGFloat = 0
            var palmZv: Float = 0

            for (idx, obs) in observations.enumerated() {
                guard let all = try? obs.recognizedPoints(.all) else { continue }
                // Vision unmirrored via `.leftMirrored`, but our depth view is
                // the raw (mirrored) selfie. Flip x back to match the display.
                func mapped(_ p: VNRecognizedPoint) -> CGPoint {
                    CGPoint(x: 1 - p.location.x, y: 1 - p.location.y)
                }
                let pts: [CGPoint] = all.values
                    .filter { $0.confidence > 0.3 }
                    .map(mapped)
                if pts.isEmpty { continue }
                out.append(pts)

                if idx == 0 {
                    let sumX = pts.reduce(0) { $0 + $1.x }
                    let sumY = pts.reduce(0) { $0 + $1.y }
                    let c = CGPoint(x: sumX / CGFloat(pts.count),
                                    y: sumY / CGFloat(pts.count))
                    center = c
                    if let thumb = all[.thumbTip], let index = all[.indexTip],
                       thumb.confidence > 0.3, index.confidence > 0.3 {
                        let t = mapped(thumb), i = mapped(index)
                        pinchDist = hypot(t.x - i.x, t.y - i.y)
                        thumbPt = t
                        indexPt = i
                        let mid = CGPoint(x: (t.x + i.x) / 2, y: (t.y + i.y) / 2)
                        pinchZv = sampleDepthZ(at: mid)
                    }
                    centerZ = sampleDepthZ(at: c)

                    // Palm geometry — wrist + 4 MCPs define the palm plate.
                    if let wrist = all[.wrist], wrist.confidence > 0.3,
                       let imcp = all[.indexMCP], imcp.confidence > 0.3,
                       let mmcp = all[.middleMCP], mmcp.confidence > 0.3,
                       let rmcp = all[.ringMCP], rmcp.confidence > 0.3,
                       let lmcp = all[.littleMCP], lmcp.confidence > 0.3 {
                        let w = mapped(wrist)
                        let im = mapped(imcp)
                        let mm = mapped(mmcp)
                        let rm = mapped(rmcp)
                        let lm = mapped(lmcp)
                        let pc = CGPoint(
                            x: (w.x + im.x + mm.x + rm.x + lm.x) / 5,
                            y: (w.y + im.y + mm.y + rm.y + lm.y) / 5
                        )
                        palmC = pc
                        palmZv = sampleDepthZ(at: pc)

                        // Forward = unit vector from wrist toward palm (finger direction).
                        let fx = pc.x - w.x, fy = pc.y - w.y
                        let flen = hypot(fx, fy)
                        if flen > 0.0001 {
                            palmFwd = CGVector(dx: fx / flen, dy: fy / flen)
                        }

                        // Spread = average fingertip-to-palm distance.
                        var dists: [CGFloat] = []
                        for key in [VNHumanHandPoseObservation.JointName.thumbTip,
                                    .indexTip, .middleTip, .ringTip, .littleTip] {
                            if let p = all[key], p.confidence > 0.3 {
                                let m = mapped(p)
                                dists.append(hypot(m.x - pc.x, m.y - pc.y))
                            }
                        }
                        if !dists.isEmpty {
                            spreadV = dists.reduce(0, +) / CGFloat(dists.count)
                        }
                    }
                }
            }

            // Normalised spread used by both torch + haptics drivers.
            let pinchedSpread: CGFloat = 0.06
            let openSpread: CGFloat = 0.32
            let spreadT: CGFloat = palmC != nil
                ? max(0, min(1, (spreadV - pinchedSpread) / (openSpread - pinchedSpread)))
                : 0

            if torchEnabled, palmC != nil {
                setTorch(level: Float(spreadT))
            }

            if hapticsEnabled {
                // Intensity = spread (0 pinched → 1 open).
                // Sharpness = closeness (closer hand → sharper click).
                let z = palmZv > 0 ? palmZv : 0.4
                let zClamped = max(0.15, min(0.6, z))
                let sharpness = Float(1 - (CGFloat(zClamped) - 0.15) / 0.45)
                updateHaptics(intensity: Float(spreadT), sharpness: sharpness)
            }

            DispatchQueue.main.async {
                self.hands = out
                self.handCenter = center
                self.pinch = pinchDist
                self.handZ = centerZ
                self.thumbTip = thumbPt
                self.indexTip = indexPt
                self.pinchZ = pinchZv
                self.palmCenter = palmC
                self.palmForward = palmFwd
                self.fingerSpread = spreadV
                self.palmZ = palmZv
            }
        } catch {
            NSLog("[VoxelScanner] hand pose error: \(error)")
        }
    }
}
