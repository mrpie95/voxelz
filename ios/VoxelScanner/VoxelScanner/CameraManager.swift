import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UIKit
import Combine

final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published var isRunning = false
    @Published var statusMessage: String?

    private let sessionQueue = DispatchQueue(label: "voxelscanner.session")
    private let dataQueue = DispatchQueue(label: "voxelscanner.data")

    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?

    private var captureNextFrame = false
    private let ciContext = CIContext()

    override init() {
        super.init()
        sessionQueue.async { [weak self] in self?.configure() }
    }

    // MARK: - Setup

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .vga640x480

        guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) else {
            DispatchQueue.main.async { self.statusMessage = "No TrueDepth camera available" }
            session.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                return
            }
            session.addInput(input)

            guard session.canAddOutput(videoOutput) else {
                session.commitConfiguration()
                return
            }
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            session.addOutput(videoOutput)

            guard session.canAddOutput(depthOutput) else {
                session.commitConfiguration()
                return
            }
            depthOutput.isFilteringEnabled = false
            session.addOutput(depthOutput)

            if let connection = depthOutput.connection(with: .depthData) {
                connection.isEnabled = true
            }

            // Pick a depth format compatible with the active video format.
            if let depthFormat = device.activeFormat.supportedDepthDataFormats.first(where: {
                CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
            }) ?? device.activeFormat.supportedDepthDataFormats.first {
                try device.lockForConfiguration()
                device.activeDepthDataFormat = depthFormat
                device.unlockForConfiguration()
            }

            synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
            synchronizer?.setDelegate(self, queue: dataQueue)

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
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                DispatchQueue.main.async {
                    self.isRunning = self.session.isRunning
                    self.statusMessage = self.isRunning ? "Ready. Tap to capture." : "Session failed to start."
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

    func captureOneFrame() {
        captureNextFrame = true
        DispatchQueue.main.async { self.statusMessage = "Capturing…" }
    }

    private func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { completion($0) }
        default:
            completion(false)
        }
    }
}

// MARK: - Synchronized output

extension CameraManager: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput dataCollection: AVCaptureSynchronizedDataCollection) {
        guard captureNextFrame else { return }

        guard let syncedVideo = dataCollection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
              let syncedDepth = dataCollection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData,
              !syncedVideo.sampleBufferWasDropped,
              !syncedDepth.depthDataWasDropped else {
            return
        }

        captureNextFrame = false

        let depthData = syncedDepth.depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let sampleBuffer = syncedVideo.sampleBuffer

        do {
            let urls = try saveFrame(sampleBuffer: sampleBuffer, depthData: depthData)
            DispatchQueue.main.async {
                self.statusMessage = "Saved: \(urls.rgb.lastPathComponent)"
            }
        } catch {
            DispatchQueue.main.async {
                self.statusMessage = "Save failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Save

    private struct SavedURLs { let rgb: URL; let depth: URL; let intrinsics: URL }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func saveFrame(sampleBuffer: CMSampleBuffer, depthData: AVDepthData) throws -> SavedURLs {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let folder = docs.appendingPathComponent("captures/\(timestamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let rgbURL = folder.appendingPathComponent("rgb.jpg")
        let depthURL = folder.appendingPathComponent("depth_float32.bin")
        let intrinsicsURL = folder.appendingPathComponent("intrinsics.json")

        try saveJPEG(sampleBuffer: sampleBuffer, to: rgbURL)
        try saveDepthRaw(depthData: depthData, to: depthURL)
        try saveIntrinsics(depthData: depthData, sampleBuffer: sampleBuffer, to: intrinsicsURL)

        return SavedURLs(rgb: rgbURL, depth: depthURL, intrinsics: intrinsicsURL)
    }

    private func saveJPEG(sampleBuffer: CMSampleBuffer, to url: URL) throws {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw NSError(domain: "VoxelScanner", code: 1, userInfo: [NSLocalizedDescriptionKey: "No RGB pixel buffer"])
        }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        try ciContext.writeJPEGRepresentation(of: ciImage, to: url, colorSpace: colorSpace,
                                              options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9])
    }

    private func saveDepthRaw(depthData: AVDepthData, to url: URL) throws {
        let map = depthData.depthDataMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }

        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(map)
        guard let base = CVPixelBufferGetBaseAddress(map) else {
            throw NSError(domain: "VoxelScanner", code: 2, userInfo: [NSLocalizedDescriptionKey: "Depth base address nil"])
        }

        // Pack into tightly-rowed float32 buffer (width*height floats).
        var packed = Data(capacity: width * height * MemoryLayout<Float32>.size)
        for row in 0..<height {
            let rowPtr = base.advanced(by: row * bytesPerRow)
            packed.append(Data(bytes: rowPtr, count: width * MemoryLayout<Float32>.size))
        }
        try packed.write(to: url)
    }

    private func saveIntrinsics(depthData: AVDepthData, sampleBuffer: CMSampleBuffer, to url: URL) throws {
        var payload: [String: Any] = [:]

        let depthMap = depthData.depthDataMap
        payload["depth_width"] = CVPixelBufferGetWidth(depthMap)
        payload["depth_height"] = CVPixelBufferGetHeight(depthMap)
        payload["depth_pixel_format"] = "float32"

        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            payload["rgb_width"] = CVPixelBufferGetWidth(pb)
            payload["rgb_height"] = CVPixelBufferGetHeight(pb)
        }

        if let calib = depthData.cameraCalibrationData {
            let m = calib.intrinsicMatrix
            payload["intrinsic_matrix"] = [
                [m.columns.0.x, m.columns.0.y, m.columns.0.z],
                [m.columns.1.x, m.columns.1.y, m.columns.1.z],
                [m.columns.2.x, m.columns.2.y, m.columns.2.z]
            ]
            payload["intrinsic_matrix_reference_dimensions"] = [
                calib.intrinsicMatrixReferenceDimensions.width,
                calib.intrinsicMatrixReferenceDimensions.height
            ]
            payload["pixel_size_mm"] = calib.pixelSize
            if let lens = calib.lensDistortionLookupTable {
                payload["lens_distortion_lookup_count"] = lens.count / MemoryLayout<Float>.size
            }
        }

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }
}

