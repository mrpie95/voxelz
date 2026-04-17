import SwiftUI
import SceneKit
import AVFoundation
import CoreVideo
import simd

/// Live 3D point-cloud preview of the current TrueDepth frame.
/// Colors sampled from the RGB frame; orbit/pan with touch.
struct VoxelPreviewView: UIViewRepresentable {
    let camera: CameraManager

    func makeCoordinator() -> Coordinator { Coordinator(camera: camera) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.backgroundColor = UIColor(red: 0.04, green: 0.0, blue: 0.09, alpha: 1.0)
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling2X
        view.autoenablesDefaultLighting = false
        camera.frameConsumer = context.coordinator
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.camera.frameConsumer = nil
    }

    final class Coordinator: NSObject, CameraFrameConsumer {
        let camera: CameraManager
        let scene = SCNScene()
        private let pointNode = SCNNode()
        private let cameraNode = SCNNode()

        init(camera: CameraManager) {
            self.camera = camera
            super.init()
            scene.background.contents = UIColor(red: 0.04, green: 0.0, blue: 0.09, alpha: 1.0)

            cameraNode.camera = SCNCamera()
            cameraNode.camera?.zNear = 0.01
            cameraNode.camera?.zFar = 10.0
            cameraNode.position = SCNVector3(0, 0, 0.6)
            scene.rootNode.addChildNode(cameraNode)

            scene.rootNode.addChildNode(pointNode)
        }

        // MARK: - CameraFrameConsumer

        func cameraManager(_ manager: CameraManager,
                           didOutputDepth depth: AVDepthData,
                           rgb: CVPixelBuffer) {
            guard let geometry = Self.buildPointCloud(depth: depth, rgb: rgb) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.pointNode.geometry = geometry
            }
        }

        // MARK: - Point cloud builder

        private static func buildPointCloud(depth: AVDepthData, rgb: CVPixelBuffer) -> SCNGeometry? {
            let depthMap = depth.depthDataMap
            CVPixelBufferLockBaseAddress(depthMap, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

            let dW = CVPixelBufferGetWidth(depthMap)
            let dH = CVPixelBufferGetHeight(depthMap)
            let dRowBytes = CVPixelBufferGetBytesPerRow(depthMap)
            guard let dBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }

            guard let calib = depth.cameraCalibrationData else { return nil }
            let refW = Float(calib.intrinsicMatrixReferenceDimensions.width)
            let refH = Float(calib.intrinsicMatrixReferenceDimensions.height)
            let sX = Float(dW) / refW
            let sY = Float(dH) / refH
            let im = calib.intrinsicMatrix
            let fx = im.columns.0.x * sX
            let fy = im.columns.1.y * sY
            let cx = im.columns.2.x * sX
            let cy = im.columns.2.y * sY

            // RGB pixel buffer (BGRA)
            CVPixelBufferLockBaseAddress(rgb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(rgb, .readOnly) }
            let rW = CVPixelBufferGetWidth(rgb)
            let rH = CVPixelBufferGetHeight(rgb)
            let rRowBytes = CVPixelBufferGetBytesPerRow(rgb)
            guard let rBase = CVPixelBufferGetBaseAddress(rgb) else { return nil }
            let rgbScaleX = Float(rW) / Float(dW)
            let rgbScaleY = Float(rH) / Float(dH)

            let minZ: Float = 0.15
            let maxZ: Float = 1.0

            var vertices = [SIMD3<Float>]()
            var colors = [SIMD3<Float>]()
            vertices.reserveCapacity(dW * dH / 2)
            colors.reserveCapacity(dW * dH / 2)

            for v in 0..<dH {
                let depthRow = dBase.advanced(by: v * dRowBytes).assumingMemoryBound(to: Float.self)
                let rv = min(rH - 1, max(0, Int(Float(v) * rgbScaleY)))
                let rgbRow = rBase.advanced(by: rv * rRowBytes).assumingMemoryBound(to: UInt8.self)
                for u in 0..<dW {
                    let z = depthRow[u]
                    guard z.isFinite, z >= minZ, z <= maxZ else { continue }
                    let X = (Float(u) - cx) * z / fx
                    let Y = (Float(v) - cy) * z / fy
                    // camera space (Y down, Z forward) -> SceneKit (Y up, -Z forward)
                    vertices.append(SIMD3<Float>(X, -Y, -z))

                    let ru = min(rW - 1, max(0, Int(Float(u) * rgbScaleX)))
                    let p = ru * 4
                    // BGRA
                    let b = Float(rgbRow[p + 0]) / 255.0
                    let g = Float(rgbRow[p + 1]) / 255.0
                    let r = Float(rgbRow[p + 2]) / 255.0
                    colors.append(SIMD3<Float>(r, g, b))
                }
            }

            guard !vertices.isEmpty else { return nil }
            let count = vertices.count

            let vertexData = vertices.withUnsafeBufferPointer { Data(buffer: $0) }
            let colorData = colors.withUnsafeBufferPointer { Data(buffer: $0) }

            let vertexSource = SCNGeometrySource(
                data: vertexData,
                semantic: .vertex,
                vectorCount: count,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<SIMD3<Float>>.stride
            )
            let colorSource = SCNGeometrySource(
                data: colorData,
                semantic: .color,
                vectorCount: count,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<SIMD3<Float>>.stride
            )

            let element = SCNGeometryElement(
                data: nil,
                primitiveType: .point,
                primitiveCount: count,
                bytesPerIndex: MemoryLayout<Int32>.size
            )
            element.pointSize = 4
            element.minimumPointScreenSpaceRadius = 1.5
            element.maximumPointScreenSpaceRadius = 5

            let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.isDoubleSided = true
            material.writesToDepthBuffer = true
            geometry.firstMaterial = material
            return geometry
        }
    }
}
