import Foundation
import AVFoundation
import CoreVideo
import UIKit
import Combine

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

    private let sessionQueue = DispatchQueue(label: "voxelscanner.session")
    private let dataQueue = DispatchQueue(label: "voxelscanner.data")

    private let depthOutput = AVCaptureDepthDataOutput()

    private var frameCount = 0
    private var lastFpsStamp = CACurrentMediaTime()

    // EMA state for auto-range, to keep the visualisation stable frame-to-frame.
    private var emaLo: Float = 0.25
    private var emaHi: Float = 0.55

    private var loggedFirstFrame = false

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
        let near = pct(0.03)
        let far  = pct(0.65)

        // Ensure a minimum window so the grayscale has real dynamic range,
        // and cap the window so a distant wall doesn't wash it out.
        let minWindow: Float = 0.08
        let maxWindow: Float = 0.45
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
        var bytes = [UInt8](repeating: 0, count: dW * dH)

        let range = max(0.001, hi - lo)

        for v in 0..<h {
            let row = base.advanced(by: v * rowBytes).assumingMemoryBound(to: Float.self)
            for u in 0..<w {
                let z = row[u]
                let gray: UInt8
                if !z.isFinite || z <= 0 {
                    gray = 0
                } else if z < lo {
                    gray = 255
                } else if z > hi {
                    gray = 25
                } else {
                    let n = (z - lo) / range
                    gray = UInt8((1.0 - n) * 225 + 30)
                }
                let dx = (h - 1) - v
                let dy = u
                bytes[dy * dW + dx] = gray
            }
        }

        let cs = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        guard let cg = CGImage(width: dW,
                               height: dH,
                               bitsPerComponent: 8,
                               bitsPerPixel: 8,
                               bytesPerRow: dW,
                               space: cs,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider,
                               decode: nil,
                               shouldInterpolate: false,
                               intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
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
