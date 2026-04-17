import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraManager()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    if let img = camera.depthImage {
                        Image(uiImage: img)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                    } else {
                        Text("Waiting for depth…")
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(spacing: 12) {
                    HStack {
                        Text(camera.statusMessage ?? "—")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                        Spacer()
                        Text("\(camera.depthFPS) fps")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.white.opacity(0.8))
                    }

                    SliderRow(label: "MIN Z",
                              value: $camera.minZ,
                              range: 0.05...2.0,
                              format: "%.2f m")
                    SliderRow(label: "MAX Z",
                              value: $camera.maxZ,
                              range: 0.05...2.0,
                              format: "%.2f m")
                }
                .padding(16)
                .background(Color.black)
            }
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }
}

private struct SliderRow: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let format: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption.bold())
                .foregroundColor(.white)
                .frame(width: 60, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: format, value))
                .font(.caption.monospacedDigit())
                .foregroundColor(.white)
                .frame(width: 70, alignment: .trailing)
        }
    }
}
