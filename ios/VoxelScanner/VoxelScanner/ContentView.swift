import SwiftUI
import UIKit

enum RangeMode: String, CaseIterable, Identifiable {
    case auto, manual, skeleton, orb, torch
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "AUTO"
        case .manual: return "MANUAL"
        case .skeleton: return "SKEL"
        case .orb: return "ORB"
        case .torch: return "TORCH"
        }
    }
    var needsHand: Bool { self == .skeleton || self == .orb }
    var needsDepth: Bool { self != .torch }
}

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var mode: RangeMode = .auto
    @State private var optHue = true
    @State private var torchLevel: Float = 0

    init() {
        // Segmented picker text was black-on-black; force legible colours.
        let appearance = UISegmentedControl.appearance()
        appearance.setTitleTextAttributes(
            [.foregroundColor: UIColor.white.withAlphaComponent(0.7),
             .font: UIFont.boldSystemFont(ofSize: 12)], for: .normal)
        appearance.setTitleTextAttributes(
            [.foregroundColor: UIColor.white,
             .font: UIFont.boldSystemFont(ofSize: 12)], for: .selected)
        appearance.selectedSegmentTintColor = UIColor(white: 0.32, alpha: 1.0)
        appearance.backgroundColor = UIColor(white: 0.10, alpha: 1.0)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    if mode == .torch {
                        TorchPanel(level: torchLevel)
                    } else if let img = camera.depthImage {
                        Image(uiImage: img)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .overlay(
                                Group {
                                    if mode == .skeleton {
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
                                        }
                                    }
                                }
                            )
                    } else {
                        Text("Waiting for depth…")
                            .foregroundColor(.white.opacity(0.6))
                    }

                    if mode == .orb {
                        PalmOrb(
                            palm: camera.palmCenter,
                            forward: camera.palmForward,
                            spread: camera.fingerSpread,
                            palmZ: camera.palmZ,
                            hueEnabled: optHue
                        )
                        .allowsHitTesting(false)
                    }

                    if camera.isCalibrating {
                        BeachballSpinner()
                            .frame(width: 64, height: 64)
                            .shadow(color: .black.opacity(0.6), radius: 6)
                    }

                    if mode == .skeleton || mode == .orb {
                        VStack {
                            PinchMeter(value: min(max(camera.pinch / 0.35, 0), 1))
                                .frame(height: 22)
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                            Spacer()
                        }
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

                    if mode == .orb {
                        HStack(spacing: 16) {
                            ToggleChip(label: "HUE", on: $optHue)
                        }
                    } else if mode == .torch {
                        TorchSlider(level: $torchLevel) { v in
                            camera.setTorchBrightness(v)
                        }
                    } else if mode == .skeleton {
                        Text("21 joints per hand · up to 2 hands")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                            .frame(maxWidth: .infinity, alignment: .leading)
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
        // Torch mode stops the camera session entirely. Running it while the
        // TrueDepth session is live throws CMIO "device is busy" (-17281) and
        // takes the depth feed down with it — so we surrender the session
        // when the user opens the torch tab, and restart it on the way out.
        if m == .torch {
            camera.handMode = false
            camera.stop()
            return
        } else {
            camera.torchEnabled = false
            camera.setTorchBrightness(0)
            torchLevel = 0
            if !camera.isRunning { camera.start() }
        }

        switch m {
        case .auto:
            camera.autoMode = true
            camera.handMode = false
            camera.recalibrateAuto()
        case .manual:
            camera.autoMode = false
            camera.handMode = false
        case .skeleton, .orb:
            camera.autoMode = true
            camera.handMode = true
            camera.recalibrateAuto()
        case .torch:
            break
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

/// A glowing orb anchored at the palm centre. When the hand is pinched the
/// orb sits right in the palm; as the fingers spread, the orb is pushed away
/// along the palm-forward direction (wrist → knuckles). Closer hand = brighter.
private struct PalmOrb: View {
    let palm: CGPoint?
    let forward: CGVector
    let spread: CGFloat
    let palmZ: Float
    let hueEnabled: Bool

    var body: some View {
        GeometryReader { geo in
            if let p = palm {
                let minDim = min(geo.size.width, geo.size.height)
                // Orb always sits on the palm centre. Spread "pushes it toward
                // the camera" — which on a flat screen means it grows (the palm
                // normal is the Z axis from the user's POV).
                let cx = p.x * geo.size.width
                let cy = p.y * geo.size.height

                let pinchedSpread: CGFloat = 0.06
                let openSpread: CGFloat = 0.32
                let t = min(max((spread - pinchedSpread) / (openSpread - pinchedSpread), 0), 1)
                let size = minDim * (0.06 + 0.22 * t)  // 0.06 · minDim when pinched → 0.28 when open

                let hue: Double = hueEnabled
                    ? Double(t)
                    : 0.55
                // `forward` is received but no longer drives screen offset —
                // on a flat display the palm normal points at the camera, so
                // spread is expressed as orb size instead of screen translation.
                let z = palmZ > 0 ? CGFloat(palmZ) : 0.35
                let brightness: Double = {
                    let clamped = min(max(z, 0.15), 0.8)
                    return 0.6 + Double((0.8 - clamped) / 0.65) * 0.4
                }()

                ZStack {
                    // Glow halo.
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(hue: hue, saturation: 1, brightness: brightness).opacity(0.9),
                                    Color(hue: hue, saturation: 1, brightness: brightness).opacity(0.0)
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: size
                            )
                        )
                        .frame(width: size * 2.6, height: size * 2.6)

                    // Orb body with specular highlight for sphere feel.
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.white.opacity(0.95),
                                    Color(hue: hue, saturation: 1, brightness: brightness),
                                    Color(hue: hue, saturation: 1, brightness: brightness * 0.4)
                                ],
                                center: UnitPoint(x: 0.35, y: 0.3),
                                startRadius: size * 0.02,
                                endRadius: size * 0.6
                            )
                        )
                        .frame(width: size, height: size)
                        .overlay(
                            Circle().stroke(Color.white.opacity(0.5), lineWidth: 1)
                        )
                }
                .position(x: cx, y: cy)
                .animation(.easeOut(duration: 0.08), value: p)
                .animation(.easeOut(duration: 0.12), value: spread)
                .animation(.easeOut(duration: 0.15), value: palmZ)
            }
        }
    }
}

/// Full-bleed "torch is on" visual for the TORCH tab. Brightness scales with
/// the slider so you get on-screen feedback even before the LED kicks in.
private struct TorchPanel: View {
    let level: Float
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RadialGradient(
                colors: [
                    Color(red: 1.0, green: 0.95, blue: 0.8).opacity(0.9 * Double(level)),
                    Color.clear
                ],
                center: .center,
                startRadius: 20,
                endRadius: 400
            )
            VStack(spacing: 14) {
                Image(systemName: level > 0.05 ? "flashlight.on.fill" : "flashlight.off.fill")
                    .font(.system(size: 72, weight: .regular))
                    .foregroundColor(Color.yellow.opacity(0.9))
                    .shadow(color: Color.yellow.opacity(0.8 * Double(level)), radius: 30)
                Text("\(Int(level * 100))%")
                    .font(.system(size: 44, weight: .bold).monospacedDigit())
                    .foregroundColor(.white.opacity(0.9))
            }
        }
    }
}

/// Big slider for the TORCH tab. Debounced outward via the onChange callback.
private struct TorchSlider: View {
    @Binding var level: Float
    let onChange: (Float) -> Void
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("TORCH")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                Spacer()
                Text("\(Int(level * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white.opacity(0.8))
            }
            Slider(value: $level, in: 0...1)
                .tint(.yellow)
                .onChange(of: level) { _, newValue in
                    onChange(newValue)
                }
            Text("Depth feed is paused while TORCH is active")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Horizontal bar that fills with a rainbow gradient as `value` (0..1) rises.
/// Used as a live readout of the hand-pinch amount.
private struct PinchMeter: View {
    let value: CGFloat
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 11)
                    .fill(Color.black.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11)
                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                    )
                RoundedRectangle(cornerRadius: 11)
                    .fill(
                        LinearGradient(
                            colors: [.cyan, .green, .yellow, .orange, .pink],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(4, geo.size.width * value))
                    .animation(.easeOut(duration: 0.08), value: value)
                HStack {
                    Text("PINCH")
                        .font(.caption2.bold())
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.leading, 10)
                    Spacer()
                    Text("\(Int(value * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.trailing, 10)
                }
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
