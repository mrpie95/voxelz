import Foundation
import AVFoundation
import CoreVideo
import UIKit
import Combine
import Vision

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

    /// Drive the rear torch brightness from the orb spread (0..1). The torch
    /// device is independent from the front TrueDepth session.
    @Published var torchEnabled: Bool = false {
        didSet {
            if !torchEnabled { setTorch(level: 0) }
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

// MARK: - Video delegate (RGB → Vision hand pose)

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard handMode, let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

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

            // Drive rear torch brightness from spread (0 when pinched, 1 fully open).
            if torchEnabled, palmC != nil {
                let pinchedSpread: CGFloat = 0.06
                let openSpread: CGFloat = 0.32
                let t = max(0, min(1, (spreadV - pinchedSpread) / (openSpread - pinchedSpread)))
                setTorch(level: Float(t))
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
