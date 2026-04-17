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
                        PinchProjectedShape(
                            thumb: camera.thumbTip,
                            index: camera.indexTip,
                            pinchZ: camera.pinchZ,
                            spinEnabled: optSpin,
                            hueEnabled: optHue
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
                            ToggleChip(label: "TILT", on: $optSpin)
                            ToggleChip(label: "HUE", on: $optHue)
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

/// A neon rounded square projected between the thumb and index finger.
/// Size = thumb↔index distance (spread to grow). Orientation tilts with the
/// pinch axis. Hue cycles with pinch distance. Brightness falls with Z so the
/// shape feels pushed "into" the scene as the hand moves away.
private struct PinchProjectedShape: View {
    let thumb: CGPoint?
    let index: CGPoint?
    let pinchZ: Float
    let spinEnabled: Bool
    let hueEnabled: Bool

    var body: some View {
        GeometryReader { geo in
            if let t = thumb, let i = index {
                let mid = CGPoint(x: (t.x + i.x) / 2, y: (t.y + i.y) / 2)
                let dxN = i.x - t.x
                let dyN = i.y - t.y
                let dist = hypot(dxN, dyN) // normalised units

                let minDim = min(geo.size.width, geo.size.height)
                // Spread-to-grow: each unit of normalised pinch distance → minDim px.
                let side = max(24, dist * minDim * 1.1)
                let hue: Double = hueEnabled
                    ? Double(min(max(dist / 0.4, 0), 1))
                    : 0.82

                // Orient the shape along the pinch axis.
                let angleRad = atan2(dyN, dxN)
                let roll = spinEnabled ? angleRad * 180 / .pi : 0

                // Perspective from hand Z: closer = brighter + slight pop.
                let z = pinchZ > 0 ? CGFloat(pinchZ) : 0.35
                let brightness: Double = {
                    let clamped = min(max(z, 0.15), 0.8)
                    return 0.55 + Double((0.8 - clamped) / 0.65) * 0.45
                }()
                let popScale: CGFloat = {
                    let clamped = min(max(z, 0.15), 0.8)
                    return 0.9 + (0.8 - clamped) / 0.65 * 0.25
                }()

                let cx = mid.x * geo.size.width
                let cy = mid.y * geo.size.height

                RoundedRectangle(cornerRadius: side * 0.18)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hue: hue, saturation: 1.0, brightness: brightness),
                                Color(hue: (hue + 0.15).truncatingRemainder(dividingBy: 1),
                                      saturation: 1.0, brightness: brightness * 0.7)
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
                    .scaleEffect(popScale)
                    .rotationEffect(.degrees(roll))
                    .shadow(color: Color(hue: hue, saturation: 1, brightness: 1)
                                .opacity(0.8 * brightness),
                            radius: 18)
                    .position(x: cx, y: cy)
                    .animation(.easeOut(duration: 0.06), value: mid)
                    .animation(.easeOut(duration: 0.1), value: dist)
                    .animation(.easeOut(duration: 0.15), value: pinchZ)
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
