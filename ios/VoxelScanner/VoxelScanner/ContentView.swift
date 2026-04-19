import SwiftUI
import UIKit
import SceneKit
import simd
import AVKit

enum RangeMode: String, CaseIterable, Identifiable {
    case auto, manual, live, lidar, skeleton, orb, torch
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "AUTO"
        case .manual: return "MAN"
        case .live: return "LIVE"
        case .lidar: return "LIDAR"
        case .skeleton: return "SKEL"
        case .orb: return "ORB"
        case .torch: return "TORCH"
        }
    }
    var subtitle: String {
        switch self {
        case .auto: return "auto range"
        case .manual: return "manual range"
        case .live: return "live voxel cloud"
        case .lidar: return "rear lidar"
        case .skeleton: return "hand skeleton"
        case .orb: return "palm orb"
        case .torch: return "rear torch"
        }
    }
    var sfSymbol: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .manual: return "slider.horizontal.3"
        case .live: return "cube.transparent"
        case .lidar: return "dot.radiowaves.up.forward"
        case .skeleton: return "hand.raised"
        case .orb: return "circle.hexagongrid"
        case .torch: return "flashlight.on.fill"
        }
    }
    var blurb: String {
        switch self {
        case .auto: return "Depth range tracks the scene automatically."
        case .manual: return "Drag sliders to set the Z window by hand."
        case .live: return "Real-time voxel cloud you can orbit in 3D."
        case .lidar: return "Rear LiDAR scene depth. Longer range, works outdoors."
        case .skeleton: return "Vision detects 21 joints on up to 2 hands."
        case .orb: return "Neon orb grows as you open your palm."
        case .torch: return "Rear flashlight slider. Pauses depth."
        }
    }
    var needsHand: Bool { self == .skeleton || self == .orb }
    var needsDepth: Bool { self != .torch }
}

// MARK: - Theme

enum Theme {
    static let bg      = Color(red: 0x1C/255, green: 0x15/255, blue: 0x12/255)
    static let bgDeep  = Color(red: 0x12/255, green: 0x0D/255, blue: 0x0B/255)
    static let surface = Color(red: 0x2A/255, green: 0x20/255, blue: 0x1B/255)
    static let surfaceHi = Color(red: 0x35/255, green: 0x28/255, blue: 0x22/255)
    static let ivory   = Color(red: 0xF5/255, green: 0xEF/255, blue: 0xE6/255)
    static let muted   = Color(red: 0xC8/255, green: 0xB5/255, blue: 0xA5/255)
    static let salmon  = Color(red: 0xEA/255, green: 0xAC/255, blue: 0xB2/255)
    static let orange  = Color(red: 0xDD/255, green: 0x95/255, blue: 0x6B/255)
    static let sage    = Color(red: 0xA2/255, green: 0xC0/255, blue: 0xA7/255)
}

private extension Text {
    func monoCap(size: CGFloat = 11) -> Text {
        self.font(.system(size: size, weight: .medium, design: .monospaced))
            .tracking(1.3)
    }
}

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var mode: RangeMode = .auto
    @State private var optHue = true
    @State private var torchLevel: Float = 0

    @State private var modeSheet = false

    var body: some View {
        ZStack(alignment: .top) {
            // Full-bleed mocha background with subtle gradient.
            LinearGradient(
                colors: [Theme.bg, Theme.bgDeep],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            // Mode-specific viz fills the screen.
            vizArea
                .ignoresSafeArea(edges: [.horizontal, .bottom])

            VStack(spacing: 0) {
                TopBar(
                    eyebrow: "TODAY",
                    title: nowDateString(),
                    trailing: { modeSheet = true }
                )
                Spacer()
                BottomPanel(
                    mode: mode,
                    camera: camera,
                    torchLevel: $torchLevel,
                    optHue: $optHue,
                    onCapture: { camera.captureVoxels() }
                )
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            camera.start()
            applyMode(mode)
        }
        .onDisappear { camera.stop() }
        .sheet(isPresented: $modeSheet) {
            ModeSheet(
                mode: $mode,
                onSelect: { newMode in
                    mode = newMode
                    applyMode(newMode)
                    modeSheet = false
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Theme.bg)
        }
        .sheet(item: $camera.lastCapture) { capture in
            VoxelPreviewSheet(capture: capture) {
                camera.lastCapture = nil
            }
        }
        .background(
            VolumeCaptureTrigger(enabled: mode != .torch) {
                camera.captureVoxels()
            }
            .allowsHitTesting(false)
        )
    }

    @ViewBuilder
    private var vizArea: some View {
        if mode == .torch {
            TorchPanel(level: torchLevel)
        } else if mode == .live {
            LiveVoxelView(cloud: camera.liveCloud)
        } else if let img = camera.depthImage {
            ZStack {
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
                                                     with: .color(Theme.sage))
                                        }
                                    }
                                }
                            }
                        }
                    )
                if mode == .orb {
                    PalmOrb(palm: camera.palmCenter,
                            forward: camera.palmForward,
                            spread: camera.fingerSpread,
                            palmZ: camera.palmZ,
                            hueEnabled: optHue)
                        .allowsHitTesting(false)
                }
                if camera.isCalibrating {
                    BeachballSpinner()
                        .frame(width: 56, height: 56)
                        .shadow(color: .black.opacity(0.6), radius: 6)
                }
            }
        } else {
            VStack(spacing: 8) {
                ProgressView().tint(Theme.muted)
                Text("warming the sensor")
                    .monoCap()
                    .foregroundColor(Theme.muted)
            }
        }
    }

    private func nowDateString() -> String {
        let df = DateFormatter()
        df.dateFormat = "EEE dd MMM"
        return df.string(from: Date()).lowercased()
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
            if m != .orb { camera.hapticsEnabled = false }
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
        case .live:
            camera.autoMode = true
            camera.handMode = false
            camera.recalibrateAuto()
        case .skeleton, .orb:
            camera.autoMode = true
            camera.handMode = true
            camera.recalibrateAuto()
        case .torch:
            break
        case .lidar:
            camera.autoMode = true
            camera.handMode = false
            camera.recalibrateAuto()
        }
        camera.liveCloudEnabled = (m == .live)
        camera.lidarMode = (m == .lidar)
    }
}

// MARK: - Chrome

/// Slim header: eyebrow label + larger title + trailing "•••" button that
/// opens the mode sheet.
private struct TopBar: View {
    let eyebrow: String
    let title: String
    let trailing: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow).monoCap().foregroundColor(Theme.muted)
                Text(title).monoCap(size: 13).foregroundColor(Theme.ivory)
            }
            Spacer()
            Button(action: trailing) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Theme.ivory)
                    .frame(width: 36, height: 36)
                    .background(Theme.surface.opacity(0.6))
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
    }
}

/// Bottom glass card: hero metric on the left (voxel count / fps / %),
/// compact mode pill + fps pill, mode-contextual controls, and the FAB.
private struct BottomPanel: View {
    let mode: RangeMode
    @ObservedObject var camera: CameraManager
    @Binding var torchLevel: Float
    @Binding var optHue: Bool
    let onCapture: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            // Hero row: big numeral + caption, mode pill on the right.
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: -2) {
                    Text(heroValue)
                        .font(.system(size: 68, weight: .thin, design: .rounded))
                        .foregroundColor(Theme.ivory)
                        .monospacedDigit()
                    Text(heroCaption)
                        .monoCap()
                        .foregroundColor(Theme.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    ModePill(mode: mode)
                    if mode != .torch && mode != .live {
                        Text("\(camera.depthFPS) fps")
                            .monoCap()
                            .foregroundColor(Theme.muted)
                    }
                }
            }

            // Mode-contextual controls.
            Group {
                switch mode {
                case .manual:
                    VStack(spacing: 10) {
                        ThemedSlider(label: "min z", value: $camera.minZ,
                                     range: 0.05...2.0, tint: Theme.salmon)
                        ThemedSlider(label: "max z", value: $camera.maxZ,
                                     range: 0.05...2.0, tint: Theme.orange)
                    }
                case .auto, .live:
                    RangeBar(lo: camera.minZ, hi: camera.maxZ,
                             floor: 0.05, ceil: 2.0)
                case .torch:
                    ThemedSlider(label: "brightness",
                                 value: $torchLevel,
                                 range: 0...1,
                                 tint: Theme.orange,
                                 onChange: { camera.setTorchBrightness($0) })
                case .skeleton:
                    PinchStatBar(value: min(max(camera.pinch / 0.35, 0), 1),
                                 hands: camera.hands.count)
                case .orb:
                    VStack(spacing: 8) {
                        PinchStatBar(value: min(max(camera.pinch / 0.35, 0), 1),
                                     hands: camera.hands.count)
                        HStack(spacing: 10) {
                            ToggleChip(label: "HUE", on: $optHue)
                            ToggleChip(label: "HAPTIC", on: $camera.hapticsEnabled)
                        }
                    }
                }
            }

            // Shutter row.
            HStack {
                Text(camera.statusMessage?.uppercased() ?? "READY")
                    .monoCap()
                    .foregroundColor(Theme.muted)
                    .lineLimit(1)
                Spacer()
                FABShutter(busy: camera.isCapturing,
                           enabled: mode != .torch,
                           action: onCapture)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 22)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Theme.surface.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.04), lineWidth: 1)
                )
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var heroValue: String {
        switch mode {
        case .auto, .manual, .skeleton, .orb:
            return "\(camera.depthFPS)"
        case .live:
            return "\(camera.liveCloud?.positions.count ?? 0)"
        case .torch:
            return "\(Int(torchLevel * 100))"
        }
    }
    private var heroCaption: String {
        switch mode {
        case .auto, .manual, .skeleton, .orb: return "fps · \(mode.subtitle)"
        case .live: return "voxels · live cloud"
        case .torch: return "% · rear torch"
        }
    }
}

private struct ModePill: View {
    let mode: RangeMode
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: mode.sfSymbol)
                .font(.system(size: 11, weight: .semibold))
            Text(mode.title.lowercased())
                .monoCap(size: 10)
        }
        .foregroundColor(Theme.bg)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.ivory))
    }
}

/// Themed slider. Caption + colored track + value readout on the right.
private struct ThemedSlider: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let tint: Color
    var onChange: ((Float) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 6, height: 6)
                    Text(label)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Theme.ivory)
                }
                Spacer()
                Text(readout)
                    .font(.system(size: 13, design: .rounded).monospacedDigit())
                    .foregroundColor(Theme.muted)
            }
            Slider(value: $value, in: range) { editing in
                if !editing { onChange?(value) }
            }
            .tint(tint)
            .onChange(of: value) { _, new in
                onChange?(new)
            }
        }
    }

    private var readout: String {
        if range.upperBound > 1.5 { return String(format: "%.2f m", value) }
        return String(format: "%.0f %%", value * 100)
    }
}

/// Non-interactive bar that visualises the current depth window inside the
/// available 5–200 cm range. Two dots at min/max, tint in between.
private struct RangeBar: View {
    let lo: Float
    let hi: Float
    let floor: Float
    let ceil: Float

    var body: some View {
        GeometryReader { geo in
            let span = max(0.001, ceil - floor)
            let a = CGFloat((lo - floor) / span) * geo.size.width
            let b = CGFloat((hi - floor) / span) * geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Theme.salmon, Theme.orange],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: max(4, b - a))
                    .offset(x: a)
            }
        }
        .frame(height: 8)
        .overlay(alignment: .leading) {
            HStack {
                Text(String(format: "%.0f cm", lo * 100))
                    .monoCap(size: 10)
                    .foregroundColor(Theme.muted)
                Spacer()
                Text(String(format: "%.0f cm", hi * 100))
                    .monoCap(size: 10)
                    .foregroundColor(Theme.muted)
            }
            .offset(y: 18)
        }
        .padding(.bottom, 16)
    }
}

private struct PinchStatBar: View {
    let value: CGFloat   // 0..1
    let hands: Int
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                HStack(spacing: 6) {
                    Circle().fill(Theme.sage).frame(width: 6, height: 6)
                    Text("pinch")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.ivory)
                }
                Spacer()
                Text("\(hands) hand\(hands == 1 ? "" : "s")")
                    .monoCap(size: 11).foregroundColor(Theme.muted)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Theme.sage, Theme.salmon],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, geo.size.width * value))
                }
            }
            .frame(height: 6)
        }
    }
}

/// Round cream shutter button with a thin ring. Shows a spinner while busy.
private struct FABShutter: View {
    let busy: Bool
    let enabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Theme.ivory.opacity(enabled ? 0.9 : 0.3), lineWidth: 2)
                    .frame(width: 60, height: 60)
                if busy {
                    ProgressView().tint(Theme.ivory)
                } else {
                    Circle()
                        .fill(Theme.ivory.opacity(enabled ? 1.0 : 0.3))
                        .frame(width: 48, height: 48)
                }
            }
        }
        .disabled(!enabled || busy)
    }
}

/// Mode picker shown as a bottom sheet with big cards, replacing the
/// segmented tab row.
private struct ModeSheet: View {
    @Binding var mode: RangeMode
    let onSelect: (RangeMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("modes")
                .monoCap()
                .foregroundColor(Theme.muted)
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(RangeMode.allCases) { m in
                        ModeCard(mode: m, active: m == mode) {
                            onSelect(m)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
    }
}

private struct ModeCard: View {
    let mode: RangeMode
    let active: Bool
    let onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: mode.sfSymbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(active ? Theme.bg : Theme.ivory)
                    .frame(width: 46, height: 46)
                    .background(
                        Circle().fill(active ? Theme.ivory : Theme.surface)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.subtitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.ivory)
                    Text(mode.blurb)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.muted)
                }
                Spacer()
                if active {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Theme.salmon)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(active ? Theme.surface : Theme.surface.opacity(0.5))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ToggleChip: View {
    let label: String
    @Binding var on: Bool
    var body: some View {
        Button(action: { on.toggle() }) {
            Text(label.lowercased())
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .tracking(1.0)
                .foregroundColor(on ? Theme.bg : Theme.ivory)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(on ? Theme.ivory : Theme.surface)
                .cornerRadius(10)
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

/// Live point-cloud view that swaps its geometry each time `cloud` changes.
private struct LiveVoxelView: UIViewRepresentable {
    let cloud: LiveCloud?

    final class Coordinator {
        weak var scnView: SCNView?
        var node: SCNNode?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.backgroundColor = UIColor(white: 0.05, alpha: 1.0)
        v.allowsCameraControl = true
        v.antialiasingMode = .multisampling4X
        v.scene = SCNScene()

        let camNode = SCNNode()
        camNode.camera = {
            let c = SCNCamera()
            c.zNear = 0.01; c.zFar = 50
            return c
        }()
        camNode.position = SCNVector3(0, 0, 0.6)
        camNode.look(at: SCNVector3(0, 0, 0))
        v.scene?.rootNode.addChildNode(camNode)
        v.pointOfView = camNode

        context.coordinator.scnView = v
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        guard let cloud = cloud, !cloud.positions.isEmpty else { return }
        // Tear down the old geometry and swap in a fresh one. At 10 Hz with
        // ~15k points this is cheap enough to do naively.
        context.coordinator.node?.removeFromParentNode()

        let centre = (cloud.bboxMin + cloud.bboxMax) * 0.5
        var verts: [SIMD3<Float>] = []
        var cols: [SIMD3<Float>] = []
        verts.reserveCapacity(cloud.positions.count)
        cols.reserveCapacity(cloud.positions.count)
        for i in 0..<cloud.positions.count {
            let p = cloud.positions[i] - centre
            verts.append(SIMD3<Float>(p.x, -p.y, -p.z))
            let c = cloud.colors[i]
            cols.append(SIMD3<Float>(Float(c.x)/255, Float(c.y)/255, Float(c.z)/255))
        }

        let posData = verts.withUnsafeBufferPointer { Data(buffer: $0) }
        let colData = cols.withUnsafeBufferPointer { Data(buffer: $0) }
        let posSource = SCNGeometrySource(
            data: posData, semantic: .vertex,
            vectorCount: verts.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        let colSource = SCNGeometrySource(
            data: colData, semantic: .color,
            vectorCount: cols.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        var indices: [Int32] = (0..<Int32(verts.count)).map { $0 }
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData, primitiveType: .point,
            primitiveCount: verts.count,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        element.pointSize = 0.006
        element.minimumPointScreenSpaceRadius = 0.5
        element.maximumPointScreenSpaceRadius = 200.0

        let geo = SCNGeometry(sources: [posSource, colSource], elements: [element])
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = UIColor.white
        mat.isDoubleSided = true
        geo.materials = [mat]

        let node = SCNNode(geometry: geo)
        node.eulerAngles = SCNVector3(0, 0, -Float.pi / 2)
        uiView.scene?.rootNode.addChildNode(node)
        context.coordinator.node = node
    }
}

/// Hardware volume buttons trigger the capture via AVCaptureEventInteraction.
/// iOS 17.2+ only — falls back to no-op on older OSes.
private struct VolumeCaptureTrigger: UIViewRepresentable {
    let enabled: Bool
    let onCapture: () -> Void

    final class Host: UIView {
        var onCapture: (() -> Void)?
        fileprivate var interaction: Any?
    }

    func makeUIView(context: Context) -> Host {
        let v = Host()
        v.backgroundColor = .clear
        v.onCapture = onCapture
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction(
                primary: { ev in
                    if ev.phase == .began { v.onCapture?() }
                },
                secondary: { ev in
                    if ev.phase == .began { v.onCapture?() }
                }
            )
            interaction.isEnabled = enabled
            v.addInteraction(interaction)
            v.interaction = interaction
        }
        return v
    }

    func updateUIView(_ uiView: Host, context: Context) {
        uiView.onCapture = onCapture
        if #available(iOS 17.2, *) {
            if let i = uiView.interaction as? AVCaptureEventInteraction {
                i.isEnabled = enabled
            }
        }
    }
}

/// Circular shutter-style button. Shows a spinner while busy.
private struct CaptureButton: View {
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 76, height: 76)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.9), lineWidth: 3)
                    )
                if busy {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                } else {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 60, height: 60)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 8)
        }
        .disabled(busy)
    }
}

/// Sheet presented after a capture. Shows the voxel point cloud, a summary,
/// and a big Share button that writes rgb.jpg + depth_float32.bin +
/// intrinsics.json into a zip compatible with the Three.js LOAD CAPTURE flow.
private struct VoxelPreviewSheet: View {
    let capture: VoxelCapture
    let onDismiss: () -> Void
    @State private var shareURL: URL?
    @State private var cropMin: SIMD3<Float>
    @State private var cropMax: SIMD3<Float>
    @State private var showCrop: Bool = false

    init(capture: VoxelCapture, onDismiss: @escaping () -> Void) {
        self.capture = capture
        self.onDismiss = onDismiss
        _cropMin = State(initialValue: capture.bboxMin)
        _cropMax = State(initialValue: capture.bboxMax)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                VoxelSceneView(capture: capture,
                               cropMin: cropMin,
                               cropMax: cropMax,
                               showCropBox: showCrop)
                    .ignoresSafeArea(edges: .top)

                VStack(spacing: 10) {
                    HStack {
                        Text("\(visibleCount) voxels")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                        Spacer()
                        let size = cropMax - cropMin
                        Text(String(format: "%.1f × %.1f × %.1f cm",
                                    size.x * 100, size.y * 100, size.z * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.white.opacity(0.7))
                    }

                    HStack(spacing: 10) {
                        Button(action: { withAnimation { showCrop.toggle() } }) {
                            Text(showCrop ? "HIDE CROP" : "CROP")
                                .font(.caption.bold())
                                .foregroundColor(showCrop ? .black : .white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(showCrop ? Color.yellow : Color.white.opacity(0.12))
                                .cornerRadius(8)
                        }
                        Button(action: resetCrop) {
                            Text("RESET")
                                .font(.caption.bold())
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(Color.white.opacity(0.12))
                                .cornerRadius(8)
                        }
                    }

                    if showCrop {
                        CropControls(capture: capture,
                                     cropMin: $cropMin,
                                     cropMax: $cropMax)
                    }

                    HStack(spacing: 12) {
                        Button(action: onDismiss) {
                            Text("CLOSE")
                                .font(.caption.bold())
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.white.opacity(0.12))
                                .cornerRadius(10)
                        }
                        Button(action: share) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("SHARE!")
                                    .font(.caption.bold())
                            }
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white)
                            .cornerRadius(10)
                        }
                    }
                }
                .padding(16)
                .background(Color.black)
            }
        }
        .sheet(item: Binding(
            get: { shareURL.map { ShareItem(url: $0) } },
            set: { if $0 == nil { shareURL = nil } }
        )) { item in
            ShareSheet(items: [item.url])
        }
    }

    private var visibleCount: Int {
        var n = 0
        for p in capture.positions {
            if p.x >= cropMin.x, p.x <= cropMax.x,
               p.y >= cropMin.y, p.y <= cropMax.y,
               p.z >= cropMin.z, p.z <= cropMax.z { n += 1 }
        }
        return n
    }

    private func resetCrop() {
        cropMin = capture.bboxMin
        cropMax = capture.bboxMax
    }

    private func share() {
        shareURL = capture.writeSharePackage(cropMin: cropMin, cropMax: cropMax)
    }
}

/// Compact 3-axis crop control. Each axis has a min slider + max slider.
private struct CropControls: View {
    let capture: VoxelCapture
    @Binding var cropMin: SIMD3<Float>
    @Binding var cropMax: SIMD3<Float>

    var body: some View {
        VStack(spacing: 6) {
            axisRow(label: "X",
                    min: capture.bboxMin.x, max: capture.bboxMax.x,
                    lo: Binding(get: { cropMin.x },
                                set: { cropMin.x = min($0, cropMax.x) }),
                    hi: Binding(get: { cropMax.x },
                                set: { cropMax.x = max($0, cropMin.x) }))
            axisRow(label: "Y",
                    min: capture.bboxMin.y, max: capture.bboxMax.y,
                    lo: Binding(get: { cropMin.y },
                                set: { cropMin.y = min($0, cropMax.y) }),
                    hi: Binding(get: { cropMax.y },
                                set: { cropMax.y = max($0, cropMin.y) }))
            axisRow(label: "Z",
                    min: capture.bboxMin.z, max: capture.bboxMax.z,
                    lo: Binding(get: { cropMin.z },
                                set: { cropMin.z = min($0, cropMax.z) }),
                    hi: Binding(get: { cropMax.z },
                                set: { cropMax.z = max($0, cropMin.z) }))
        }
        .padding(10)
        .background(Color.white.opacity(0.06))
        .cornerRadius(10)
    }

    private func axisRow(label: String, min lo0: Float, max hi0: Float,
                         lo: Binding<Float>, hi: Binding<Float>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2.bold())
                .foregroundColor(.white)
                .frame(width: 18, alignment: .leading)
            Slider(value: lo, in: lo0...hi0)
                .tint(.cyan)
            Slider(value: hi, in: lo0...hi0)
                .tint(.pink)
        }
    }
}

// --- Direct-manipulation crop (work in progress, not yet wired up) ---

fileprivate enum CropFaceID: Int, CaseIterable {
    case xPlus, xMinus, yPlus, yMinus, zPlus, zMinus

    var displayNormal: SIMD3<Float> {
        switch self {
        case .xPlus:  return SIMD3(1, 0, 0)
        case .xMinus: return SIMD3(-1, 0, 0)
        case .yPlus:  return SIMD3(0, 1, 0)
        case .yMinus: return SIMD3(0, -1, 0)
        case .zPlus:  return SIMD3(0, 0, 1)
        case .zMinus: return SIMD3(0, 0, -1)
        }
    }

    /// `outward` = displacement along displayNormal in metres (positive = the
    /// face moves outward from the box centre). Returns new crop bounds.
    func apply(outward: Float,
               startMin: SIMD3<Float>, startMax: SIMD3<Float>,
               bboxMin: SIMD3<Float>, bboxMax: SIMD3<Float>)
    -> (SIMD3<Float>, SIMD3<Float>) {
        var mn = startMin, mx = startMax
        switch self {
        case .xPlus:  mx.x = min(bboxMax.x, max(startMin.x, startMax.x + outward))
        case .xMinus: mn.x = max(bboxMin.x, min(startMax.x, startMin.x - outward))
        // Display Y is flipped from camera Y (we render with -y), so the +Y
        // handle on-screen corresponds to cropMin.y in camera space.
        case .yPlus:  mn.y = max(bboxMin.y, min(startMax.y, startMin.y - outward))
        case .yMinus: mx.y = min(bboxMax.y, max(startMin.y, startMax.y + outward))
        case .zPlus:  mn.z = max(bboxMin.z, min(startMax.z, startMin.z - outward))
        case .zMinus: mx.z = min(bboxMax.z, max(startMin.z, startMax.z + outward))
        }
        return (mn, mx)
    }
}

fileprivate struct CropDragState {
    let face: CropFaceID
    let planePoint: SIMD3<Float>
    let planeNormal: SIMD3<Float>   // camera forward in world space
    let startWorldHit: SIMD3<Float>
    let worldOutwardDir: SIMD3<Float>
    let startMin: SIMD3<Float>
    let startMax: SIMD3<Float>
}

/// SCNView subclass that intercepts touches on crop handles before the
/// built-in camera controller sees them.
final class CropSCNView: SCNView {
    fileprivate var drag: CropDragState?
    fileprivate var handleNodes: [CropFaceID: SCNNode] = [:]
    fileprivate weak var wrapperNode: SCNNode?
    fileprivate var onDragUpdate: ((SIMD3<Float>, SIMD3<Float>) -> Void)?
    fileprivate var onDragEnd: (() -> Void)?
    fileprivate var bboxMin: SIMD3<Float> = .zero
    fileprivate var bboxMax: SIMD3<Float> = .zero
    fileprivate var cropMinNow: SIMD3<Float> = .zero
    fileprivate var cropMaxNow: SIMD3<Float> = .zero
    fileprivate var dragEnabled: Bool = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard dragEnabled, let t = touches.first else {
            super.touchesBegan(touches, with: event); return
        }
        let pt = t.location(in: self)
        let hits = hitTest(pt, options: [
            SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue,
            SCNHitTestOption.ignoreHiddenNodes: true
        ])
        for hit in hits {
            for (face, node) in handleNodes where hit.node === node {
                if let d = startDrag(face: face, touchPt: pt) {
                    drag = d
                    return
                }
            }
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let d = drag, let t = touches.first else {
            super.touchesMoved(touches, with: event); return
        }
        let pt = t.location(in: self)
        guard let hit = rayIntersect(screen: pt,
                                     planePoint: d.planePoint,
                                     planeNormal: d.planeNormal) else { return }
        let worldDelta = hit - d.startWorldHit
        let outward = simd_dot(worldDelta, d.worldOutwardDir)
        let (mn, mx) = d.face.apply(outward: outward,
                                    startMin: d.startMin,
                                    startMax: d.startMax,
                                    bboxMin: bboxMin,
                                    bboxMax: bboxMax)
        cropMinNow = mn; cropMaxNow = mx
        onDragUpdate?(mn, mx)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if drag != nil {
            drag = nil
            onDragEnd?()
        } else {
            super.touchesEnded(touches, with: event)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if drag != nil {
            drag = nil
            onDragEnd?()
        } else {
            super.touchesCancelled(touches, with: event)
        }
    }

    private func startDrag(face: CropFaceID, touchPt: CGPoint) -> CropDragState? {
        guard let wrapper = wrapperNode,
              let pov = pointOfView else { return nil }
        guard let handle = handleNodes[face] else { return nil }
        let handleWorld = simd_float3(handle.simdWorldPosition)
        // Drag plane faces the camera.
        let camFront = normalize(simd_float3(pov.simdWorldFront))
        let planeNormal = camFront
        guard let startHit = rayIntersect(screen: touchPt,
                                          planePoint: handleWorld,
                                          planeNormal: planeNormal) else { return nil }
        // Face outward direction in world space: wrapper rotates display → world.
        let outwardLocal = face.displayNormal
        let outwardWorld = normalize(simd_make_float3(
            wrapper.simdConvertVector(SIMD3<Float>(outwardLocal), to: nil)
        ))
        return CropDragState(
            face: face,
            planePoint: handleWorld,
            planeNormal: planeNormal,
            startWorldHit: startHit,
            worldOutwardDir: outwardWorld,
            startMin: cropMinNow,
            startMax: cropMaxNow
        )
    }

    private func rayIntersect(screen: CGPoint,
                              planePoint: SIMD3<Float>,
                              planeNormal: SIMD3<Float>) -> SIMD3<Float>? {
        let nearV = unprojectPoint(SCNVector3(Float(screen.x), Float(screen.y), 0))
        let farV = unprojectPoint(SCNVector3(Float(screen.x), Float(screen.y), 1))
        let origin = SIMD3<Float>(Float(nearV.x), Float(nearV.y), Float(nearV.z))
        let end = SIMD3<Float>(Float(farV.x), Float(farV.y), Float(farV.z))
        let dir = end - origin
        let denom = simd_dot(dir, planeNormal)
        if abs(denom) < 1e-6 { return nil }
        let t = simd_dot(planePoint - origin, planeNormal) / denom
        return origin + dir * t
    }
}

fileprivate extension SCNNode {
    func simdConvertVector(_ v: SIMD3<Float>, to other: SCNNode?) -> SIMD3<Float> {
        let vv = SCNVector3(v.x, v.y, v.z)
        let out = convertVector(vv, to: other)
        return SIMD3<Float>(Float(out.x), Float(out.y), Float(out.z))
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) { }
}

/// SceneKit 3D point cloud view. Uses the built-in camera controls so the user
/// can pinch / rotate the cloud with one finger. Rebuilds the geometry and
/// crop-box wireframe whenever the bounds change.
private struct VoxelSceneView: UIViewRepresentable {
    let capture: VoxelCapture
    let cropMin: SIMD3<Float>
    let cropMax: SIMD3<Float>
    let showCropBox: Bool

    final class Coordinator {
        var pointsNode: SCNNode?
        var cropNode: SCNNode?
        var wrapper: SCNNode?  // holds point + crop, rotated -π/2 around Z
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.backgroundColor = UIColor(white: 0.05, alpha: 1.0)
        v.allowsCameraControl = true
        v.antialiasingMode = .multisampling4X

        let scene = SCNScene()
        v.scene = scene

        // Wrapper node holds all world content; we apply the -π/2 Z rotation
        // here so everything (points + crop box) stays aligned.
        let wrapper = SCNNode()
        wrapper.eulerAngles = SCNVector3(0, 0, -Float.pi / 2)
        scene.rootNode.addChildNode(wrapper)
        context.coordinator.wrapper = wrapper

        let extent = simd_length(capture.bboxMax - capture.bboxMin)
        let cam = SCNCamera()
        cam.zNear = 0.01; cam.zFar = 50
        let camNode = SCNNode()
        camNode.camera = cam
        camNode.position = SCNVector3(0, 0, max(0.25, extent * 1.6))
        camNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camNode)
        v.pointOfView = camNode

        rebuildPoints(coordinator: context.coordinator)
        rebuildCropBox(coordinator: context.coordinator)
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        rebuildPoints(coordinator: context.coordinator)
        rebuildCropBox(coordinator: context.coordinator)
    }

    private func rebuildPoints(coordinator: Coordinator) {
        guard let wrapper = coordinator.wrapper else { return }
        coordinator.pointsNode?.removeFromParentNode()
        if capture.positions.isEmpty { return }

        let centre = (capture.bboxMin + capture.bboxMax) * 0.5
        var verts: [SIMD3<Float>] = []
        var cols: [SIMD3<Float>] = []
        verts.reserveCapacity(capture.positions.count)
        cols.reserveCapacity(capture.positions.count)
        for i in 0..<capture.positions.count {
            let p = capture.positions[i]
            // Crop test is in original (pre-rotation) world space.
            if p.x < cropMin.x || p.x > cropMax.x ||
               p.y < cropMin.y || p.y > cropMax.y ||
               p.z < cropMin.z || p.z > cropMax.z { continue }
            let q = p - centre
            verts.append(SIMD3<Float>(q.x, -q.y, -q.z))
            let c = capture.colors[i]
            cols.append(SIMD3<Float>(Float(c.x)/255, Float(c.y)/255, Float(c.z)/255))
        }
        if verts.isEmpty { return }

        let posData = verts.withUnsafeBufferPointer { Data(buffer: $0) }
        let colData = cols.withUnsafeBufferPointer { Data(buffer: $0) }
        let posSource = SCNGeometrySource(
            data: posData, semantic: .vertex,
            vectorCount: verts.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        let colSource = SCNGeometrySource(
            data: colData, semantic: .color,
            vectorCount: cols.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        var indices: [Int32] = (0..<Int32(verts.count)).map { $0 }
        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData, primitiveType: .point,
            primitiveCount: verts.count,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        element.pointSize = 0.004
        element.minimumPointScreenSpaceRadius = 0.5
        element.maximumPointScreenSpaceRadius = 200.0

        let geo = SCNGeometry(sources: [posSource, colSource], elements: [element])
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = UIColor.white
        mat.isDoubleSided = true
        geo.materials = [mat]

        let node = SCNNode(geometry: geo)
        wrapper.addChildNode(node)
        coordinator.pointsNode = node
    }

    private func rebuildCropBox(coordinator: Coordinator) {
        guard let wrapper = coordinator.wrapper else { return }
        coordinator.cropNode?.removeFromParentNode()
        guard showCropBox else { return }

        let centre = (capture.bboxMin + capture.bboxMax) * 0.5
        let cMin = cropMin - centre
        let cMax = cropMax - centre
        // Flip Y/Z to match the points. Axis-aligned box corners.
        let lo = SIMD3<Float>(cMin.x, -cMax.y, -cMax.z)
        let hi = SIMD3<Float>(cMax.x, -cMin.y, -cMin.z)

        // 8 corners + 12 edges as line primitives.
        let corners: [SIMD3<Float>] = [
            SIMD3(lo.x, lo.y, lo.z), SIMD3(hi.x, lo.y, lo.z),
            SIMD3(hi.x, hi.y, lo.z), SIMD3(lo.x, hi.y, lo.z),
            SIMD3(lo.x, lo.y, hi.z), SIMD3(hi.x, lo.y, hi.z),
            SIMD3(hi.x, hi.y, hi.z), SIMD3(lo.x, hi.y, hi.z)
        ]
        let edgeIdx: [Int32] = [
            0,1, 1,2, 2,3, 3,0,      // bottom ring
            4,5, 5,6, 6,7, 7,4,      // top ring
            0,4, 1,5, 2,6, 3,7       // verticals
        ]

        let posData = corners.withUnsafeBufferPointer { Data(buffer: $0) }
        let posSource = SCNGeometrySource(
            data: posData, semantic: .vertex,
            vectorCount: corners.count,
            usesFloatComponents: true, componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride
        )
        let idxData = edgeIdx.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: idxData, primitiveType: .line,
            primitiveCount: edgeIdx.count / 2,
            bytesPerIndex: MemoryLayout<Int32>.size
        )

        let geo = SCNGeometry(sources: [posSource], elements: [element])
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = UIColor.yellow
        mat.emission.contents = UIColor.yellow
        mat.isDoubleSided = true
        geo.materials = [mat]

        let node = SCNNode(geometry: geo)
        wrapper.addChildNode(node)
        coordinator.cropNode = node
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
