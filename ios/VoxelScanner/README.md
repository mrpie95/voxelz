# VoxelScanner (iOS)

A TrueDepth front-camera scanner for iPhone. Turns the live depth stream into
a colored voxel point cloud you can capture, crop, and hand off to the
Three.js web viewer at the repo root.

Built as a hand-authored Xcode project with a single-file SwiftUI UI plus a
camera / voxel manager that wires together AVFoundation, Vision, CoreHaptics,
and SceneKit.

## Requirements

- Xcode 15 or later (Swift 5.9+)
- iOS 17+ deployment target (iOS 17.2+ to use the hardware volume-button
  shutter trigger)
- **Physical device with a TrueDepth front camera** — iPhone X and later
  (X, XS, XR, 11, 12, 13, 14, 15, 16 series) and iPad Pro models that ship
  TrueDepth. The Simulator does not expose depth, so you must run on real
  hardware.

## Open & run

```bash
open ios/VoxelScanner/VoxelScanner.xcodeproj
```

1. Select your Apple Developer team under **Signing & Capabilities**.
2. Adjust `PRODUCT_BUNDLE_IDENTIFIER` if `com.voxelz.VoxelScanner` is taken.
3. Plug in a TrueDepth iPhone, pick it as the run destination, build & run.
4. Grant the camera prompt on first launch.

## Interface

Mocha/cream theme. Full-bleed visualization behind a slim top bar and a
glass bottom card.

- **Top bar** — date eyebrow + circular `•••` button that opens the mode
  sheet with big ModeCards (icon, title, blurb).
- **Bottom card** — thin-weight hero numeral (fps / voxels / %), a small
  ivory mode pill, mode-contextual controls, status line, and a round cream
  shutter FAB.
- **Volume buttons** — either volume button fires the shutter from any
  non-TORCH mode (iOS 17.2+ via `AVCaptureEventInteraction`).

### Modes

| Mode       | What it does                                                       |
| ---------- | ------------------------------------------------------------------ |
| **AUTO**   | Depth range auto-tracks the scene (5th–45th percentile + EMA).     |
| **MANUAL** | Drag min/max Z sliders to pin the window yourself.                 |
| **LIVE**   | Real-time voxel cloud rendered in SceneKit at ~10 Hz.              |
| **SKEL**   | 21-joint Vision hand-pose overlay (up to 2 hands).                 |
| **ORB**    | Neon sphere anchored at the palm; grows as you spread your hand.   |
| **TORCH**  | Dedicated slider for the rear flashlight (pauses the depth feed).  |

### Depth visualization

- 90° CW rotated render matching portrait orientation.
- Polynomial-fit **Turbo colormap** (near = hot, far = cool) so small depth
  steps are readable.
- Auto range recalibrates on mode entry with an animated beachball overlay.
- 4-neighbour **depth-edge gradient filter** kills the stretched "ghost"
  points at occlusion boundaries; outer 5% of the sensor is cropped for
  noise.

### Hand pipeline

- `VNDetectHumanHandPoseRequest` runs on the RGB stream, orientation hint
  `.leftMirrored` to match the selfie-facing depth view.
- Palm center and wrist→knuckle direction are derived from the joints;
  palm-Z is sampled from the depth buffer at the palm center.
- **ORB mode** drives a neon sphere whose size = finger spread and whose
  brightness = sampled palm Z.
- **HAPTIC chip** in ORB runs a live CoreHaptics continuous event:
  intensity ← spread, sharpness ← palm distance. A quick tick+boom pattern
  also plays on shutter press / voxelisation completion.

## Voxel capture

Tap the shutter (or press either volume button). The next frame pair is
snapshotted and voxelised in a background task.

- **4 mm voxel bins** (capture) / **6 mm** (live).
- Rescaled camera intrinsics, edge-filtered depth, 0.15 m < Z < 1.2 m.
- Colour per voxel is the mean of the RGB pixels that fell in the bin.

### Preview sheet

A bottom sheet slides up with:

- SceneKit point-cloud view (built-in pinch-to-zoom / orbit).
- Live voxel count + bbox dimensions in centimetres.
- **CROP** — expands three axis sliders (cyan = min, pink = max) plus a
  yellow wireframe box in 3D; hides points outside the volume in real time.
- **RESET** — returns the crop to the full bbox.
- **SHARE!** — zips `rgb.jpg + depth_float32.bin + intrinsics.json` and
  opens the iOS share sheet. Depth pixels outside the crop volume are
  zeroed in the exported binary so the web viewer reproduces the same
  cropped cloud.

### Share package format

```
capture-<unixtime>.zip
├── rgb.jpg                # color frame, JPEG, oriented upright
├── depth_float32.bin      # Float32 little-endian, width × height
└── intrinsics.json        # camera calibration + image sizes
```

`intrinsics.json` fields (snake_case, matching the web loader):

```json
{
  "depth_width": 320,
  "depth_height": 240,
  "rgb_width":  1920,
  "rgb_height": 1440,
  "intrinsic_matrix_reference_dimensions": [4032, 3024],
  "intrinsic_matrix": [
    [fx, 0,  0 ],
    [0,  fy, 0 ],
    [cx, cy, 1 ]
  ]
}
```

AirDrop the zip to your Mac, unzip, then hit **LOAD CAPTURE** in
`index.html` and the Three.js viewer voxelises the same data and drops it
into the JED TIME / CHROMA SHIFT neon scene.

## App icon

The icon is rendered programmatically from
`ios/VoxelScanner/scripts/generate_icon.swift`. Aperture-style iris blades
around an isometric voxel cube in the app's mocha / ivory / salmon / orange
palette. Regenerate with:

```bash
swift ios/VoxelScanner/scripts/generate_icon.swift
```

Output lands in `Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`.

## Project layout

```
ios/VoxelScanner/
├── VoxelScanner/
│   ├── VoxelScannerApp.swift       # @main entry
│   ├── ContentView.swift           # all UI, theme, preview sheet, SceneKit wrappers
│   ├── CameraManager.swift         # AVFoundation + Vision + CoreHaptics + voxelisation
│   ├── Info.plist                  # NSCameraUsageDescription, portrait only, etc.
│   └── Assets.xcassets/
│       └── AppIcon.appiconset/
├── scripts/
│   └── generate_icon.swift         # CoreGraphics app-icon renderer
├── VoxelScanner.xcodeproj/         # hand-authored pbxproj
└── README.md
```

## What's next

- Volumetric crop with direct-manipulation handles (tap a wall in 3D and
  drag it) instead of axis sliders — partial scaffolding in ContentView.
- Multi-frame fusion into a proper 3D scan (ARKit-driven camera pose +
  incremental voxel merge).
- Live stream of voxels to the Three.js viewer over websocket so the web
  scene fills up as you scan.
