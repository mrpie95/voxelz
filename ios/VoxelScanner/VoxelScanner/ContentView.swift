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

                    if camera.isCalibrating {
                        BeachballSpinner()
                            .frame(width: 64, height: 64)
                            .shadow(color: .black.opacity(0.6), radius: 6)
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

                    HStack(spacing: 12) {
                        Text("RANGE")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                        Picker("Mode", selection: $camera.autoMode) {
                            Text("AUTO").tag(true)
                            Text("MANUAL").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: camera.autoMode) { _, newValue in
                            if newValue { camera.recalibrateAuto() }
                        }
                    }

                    SliderRow(label: "MIN Z",
                              value: $camera.minZ,
                              range: 0.05...2.0,
                              format: "%.2f m",
                              enabled: !camera.autoMode)
                    SliderRow(label: "MAX Z",
                              value: $camera.maxZ,
                              range: 0.05...2.0,
                              format: "%.2f m",
                              enabled: !camera.autoMode)
                }
                .padding(16)
                .background(Color.black)
            }
        }
        .onAppear {
            camera.start()
            if camera.autoMode { camera.recalibrateAuto() }
        }
        .onDisappear { camera.stop() }
    }
}

/// Classic Mac-OS-style rainbow pinwheel ("beachball of death").
private struct BeachballSpinner: View {
    @State private var spin = false
    private let colors: [Color] = [
        .red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink
    ]

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                ForEach(0..<colors.count, id: \.self) { i in
                    Wedge()
                        .fill(colors[i])
                        .rotationEffect(.degrees(Double(i) * (360.0 / Double(colors.count))))
                }
                Circle()
                    .fill(Color.white)
                    .frame(width: size * 0.25, height: size * 0.25)
            }
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
        }
    }
}

private struct Wedge: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        p.move(to: c)
        p.addArc(center: c, radius: r,
                 startAngle: .degrees(-90 - 22.5),
                 endAngle: .degrees(-90 + 22.5),
                 clockwise: false)
        p.closeSubpath()
        return p
    }
}

private struct SliderRow: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let format: String
    let enabled: Bool

    var body: some View {
        HStack {
            Text(label)
                .font(.caption.bold())
                .foregroundColor(enabled ? .white : .white.opacity(0.4))
                .frame(width: 60, alignment: .leading)
            Slider(value: $value, in: range)
                .disabled(!enabled)
                .opacity(enabled ? 1.0 : 0.5)
            Text(String(format: format, value))
                .font(.caption.monospacedDigit())
                .foregroundColor(enabled ? .white : .white.opacity(0.6))
                .frame(width: 70, alignment: .trailing)
        }
    }
}
