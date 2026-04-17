import SwiftUI

enum RangeMode: String, CaseIterable, Identifiable {
    case auto, manual, hand
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "AUTO"
        case .manual: return "MANUAL"
        case .hand: return "HAND"
        }
    }
}

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var mode: RangeMode = .auto
    @State private var optSpin = true
    @State private var optHue = true
    @State private var optScale = true

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
                            .overlay(
                                GeometryReader { geo in
                                    Canvas { ctx, size in
                                        for hand in camera.hands {
                                            for p in hand {
                                                let c = CGPoint(x: p.x * size.width,
                                                                y: p.y * size.height)
                                                let r: CGFloat = 5
                                                let rect = CGRect(x: c.x - r, y: c.y - r,
                                                                  width: r * 2, height: r * 2)
                                                ctx.fill(Path(ellipseIn: rect),
                                                         with: .color(.green))
                                            }
                                        }
                                        _ = geo
                                    }
                                }
                            )
                    } else {
                        Text("Waiting for depth…")
                            .foregroundColor(.white.opacity(0.6))
                    }

                    if camera.handMode {
                        HandControlledShape(
                            center: camera.handCenter,
                            pinch: camera.pinch,
                            handZ: camera.handZ,
                            spinEnabled: optSpin,
                            hueEnabled: optHue,
                            scaleEnabled: optScale
                        )
                        .allowsHitTesting(false)
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
                        Text("MODE")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                        Picker("Mode", selection: $mode) {
                            ForEach(RangeMode.allCases) { m in
                                Text(m.title).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: mode) { _, newValue in
                            applyMode(newValue)
                        }
                    }

                    if mode == .hand {
                        HStack(spacing: 16) {
                            ToggleChip(label: "SPIN", on: $optSpin)
                            ToggleChip(label: "HUE", on: $optHue)
                            ToggleChip(label: "SCALE", on: $optScale)
                        }
                    } else {
                        SliderRow(label: "MIN Z",
                                  value: $camera.minZ,
                                  range: 0.05...2.0,
                                  format: "%.2f m",
                                  enabled: mode == .manual)
                        SliderRow(label: "MAX Z",
                                  value: $camera.maxZ,
                                  range: 0.05...2.0,
                                  format: "%.2f m",
                                  enabled: mode == .manual)
                    }
                }
                .padding(16)
                .background(Color.black)
            }
        }
        .onAppear {
            camera.start()
            applyMode(mode)
        }
        .onDisappear { camera.stop() }
    }

    private func applyMode(_ m: RangeMode) {
        switch m {
        case .auto:
            camera.autoMode = true
            camera.handMode = false
            camera.recalibrateAuto()
        case .manual:
            camera.autoMode = false
            camera.handMode = false
        case .hand:
            camera.autoMode = true    // keep Z window auto-tracking the hand
            camera.handMode = true
            camera.recalibrateAuto()
        }
    }
}

private struct ToggleChip: View {
    let label: String
    @Binding var on: Bool
    var body: some View {
        Button(action: { on.toggle() }) {
            Text(label)
                .font(.caption.bold())
                .foregroundColor(on ? .black : .white.opacity(0.7))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(on ? Color.white : Color.white.opacity(0.12))
                .cornerRadius(8)
        }
    }
}

/// A big neon rounded square whose rotation, hue, and scale are driven by
/// the currently-detected hand. No hand = nothing is shown.
private struct HandControlledShape: View {
    let center: CGPoint?
    let pinch: CGFloat   // 0..~0.5 in display-space units
    let handZ: Float     // meters; 0 if unavailable
    let spinEnabled: Bool
    let hueEnabled: Bool
    let scaleEnabled: Bool

    var body: some View {
        GeometryReader { geo in
            if let c = center {
                let yaw = spinEnabled ? (c.x - 0.5) * 180 : 0
                let pitch = spinEnabled ? (0.5 - c.y) * 180 : 0
                let hue: Double = hueEnabled
                    ? Double(min(max(pinch / 0.4, 0), 1))
                    : 0.82     // fixed neon purple when hue control is off
                let scale: CGFloat = {
                    guard scaleEnabled else { return 1.0 }
                    let z = handZ > 0 ? CGFloat(handZ) : 0.4
                    let t = (0.6 - min(max(z, 0.2), 0.6)) / 0.4
                    return 0.6 + t * 0.8
                }()
                let side = min(geo.size.width, geo.size.height) * 0.45
                RoundedRectangle(cornerRadius: side * 0.18)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hue: hue, saturation: 1.0, brightness: 1.0),
                                Color(hue: (hue + 0.15).truncatingRemainder(dividingBy: 1),
                                      saturation: 1.0, brightness: 0.7)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: side * 0.18)
                            .stroke(Color.white.opacity(0.9), lineWidth: 2)
                    )
                    .frame(width: side, height: side)
                    .scaleEffect(scale)
                    .rotation3DEffect(.degrees(yaw), axis: (x: 0, y: 1, z: 0))
                    .rotation3DEffect(.degrees(pitch), axis: (x: 1, y: 0, z: 0))
                    .shadow(color: Color(hue: hue, saturation: 1, brightness: 1).opacity(0.8),
                            radius: 18)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .animation(.easeOut(duration: 0.08), value: c)
                    .animation(.easeOut(duration: 0.15), value: pinch)
                    .animation(.easeOut(duration: 0.15), value: handZ)
            }
        }
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
