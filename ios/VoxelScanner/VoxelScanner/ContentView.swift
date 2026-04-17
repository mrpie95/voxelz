import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraManager()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Top half: live RGB preview
                    ZStack {
                        CameraPreviewView(session: camera.session)
                        VStack {
                            HStack {
                                Text("RGB")
                                    .font(.caption.bold())
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.black.opacity(0.5))
                                    .cornerRadius(6)
                                    .padding(8)
                                Spacer()
                            }
                            Spacer()
                        }
                    }
                    .frame(height: geo.size.height * 0.5)
                    .clipped()

                    // Bottom half: live voxel preview
                    ZStack {
                        VoxelPreviewView(camera: camera)
                        VStack {
                            HStack {
                                Text("VOXELS · DRAG TO ORBIT")
                                    .font(.caption.bold())
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.black.opacity(0.5))
                                    .cornerRadius(6)
                                    .padding(8)
                                Spacer()
                            }
                            Spacer()
                        }
                    }
                    .frame(height: geo.size.height * 0.5)
                    .clipped()
                }
                .ignoresSafeArea()

                // Overlay: shutter + status
                VStack {
                    Spacer()
                    if let status = camera.statusMessage {
                        Text(status)
                            .font(.footnote)
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(8)
                            .padding(.bottom, 12)
                    }
                    Button(action: { camera.captureOneFrame() }) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 70, height: 70)
                            .overlay(Circle().stroke(Color.black.opacity(0.3), lineWidth: 2))
                            .shadow(color: .black.opacity(0.5), radius: 6)
                    }
                    .padding(.bottom, 32)
                    .disabled(!camera.isRunning)
                }
            }
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }
}
