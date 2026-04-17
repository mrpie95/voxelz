import Foundation
import AVFoundation
import CoreVideo
import UIKit
import Combine

/// Depth-only TrueDepth manager. No RGB, no synchronizer, no file saving —
/// just render the live depth map so we can verify the sensor works.
final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published var isRunning = false
    @Published var statusMessage: String?
    @Published var depthImage: UIImage?
    @Published var depthFPS: Int = 0

    @Published var minZ: Float = 0.20    // meters — closer than this = transparent
    @Published var maxZ: Float = 0.80    // meters — farther than this = transparent

    private let sessionQueue = DispatchQueue(label: "voxelscanner.session")
    private let dataQueue = DispatchQueue(label: "voxelscanner.data")

    private let depthOutput = AVCaptureDepthDataOutput()

    private var frameCount = 0
    private var lastFpsStamp = CACurrentMediaTime()

    override init() {
        super.init()
        sessionQueue.async { [weak self] in self?.configure() }
    }

    // MARK: - Setup

    private func configure() {
        guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera,
                                                   for: .depthData,
                                                   position: .front) else {
            DispatchQueue.main.async { self.statusMessage = "No TrueDepth camera available" }
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)

            session.beginConfiguration()
            session.sessionPreset = .photo

            if session.canAddInput(input) {
                session.addInput(input)
            } else {
                session.commitConfiguration()
                DispatchQueue.main.async { self.statusMessage = "Cannot add camera input" }
                return
            }

            if session.canAddOutput(depthOutput) {
                session.addOutput(depthOutput)
            } else {
                session.commitConfiguration()
                DispatchQueue.main.async { self.statusMessage = "Cannot add depth output" }
                return
            }
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
                    self.statusMessage = "Depth format: \(dims.width)x\(dims.height)"
                }
            }

            session.commitConfiguration()
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
                if !self.session.isRunning { self.session.startRunning() }
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

    // MARK: - Depth rendering

    private func render(_ pb: CVPixelBuffer) -> UIImage? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }

        let lo = minZ, hi = maxZ
        let range = max(0.001, hi - lo)

        var bytes = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in 0..<w {
                let z = row[x]
                let out: UInt8
                if !z.isFinite || z <= 0 {
                    out = 0
                } else if z < lo {
                    out = 255                    // closer than window: saturated
                } else if z > hi {
                    out = 30                     // farther than window: dark
                } else {
                    let n = (z - lo) / range     // 0 (close) → 1 (far)
                    out = UInt8((1.0 - n) * 225 + 30)
                }
                bytes[y * w + x] = out
            }
        }

        let cs = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        guard let cg = CGImage(width: w,
                               height: h,
                               bitsPerComponent: 8,
                               bitsPerPixel: 8,
                               bytesPerRow: w,
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

        guard let img = render(depth.depthDataMap) else { return }

        frameCount += 1
        let now = CACurrentMediaTime()
        if now - lastFpsStamp >= 1.0 {
            let fps = Int(Double(frameCount) / (now - lastFpsStamp))
            frameCount = 0
            lastFpsStamp = now
            DispatchQueue.main.async {
                self.depthFPS = fps
                self.depthImage = img
            }
        } else {
            DispatchQueue.main.async { self.depthImage = img }
        }
    }

    func depthDataOutput(_ output: AVCaptureDepthDataOutput,
                         didDrop depthData: AVDepthData,
                         timestamp: CMTime,
                         connection: AVCaptureConnection,
                         reason: AVCaptureOutput.DataDroppedReason) {
        // ignore drops
    }
}
