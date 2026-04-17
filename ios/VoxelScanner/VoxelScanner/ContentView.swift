import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraManager()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreviewView(session: camera.session)
                .ignoresSafeArea()

            VStack {
                Spacer()

                if let status = camera.statusMessage {
                    Text(status)
                        .font(.footnote)
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(8)
                        .padding(.bottom, 12)
                }

                Button(action: { camera.captureOneFrame() }) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 76, height: 76)
                        .overlay(
                            Circle().stroke(Color.black.opacity(0.3), lineWidth: 2)
                        )
                }
                .padding(.bottom, 40)
                .disabled(!camera.isRunning)
            }
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }
}
