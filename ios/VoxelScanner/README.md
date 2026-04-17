# VoxelScanner (iOS) — Milestone 1

Captures a single synchronized TrueDepth + RGB frame from the iPhone front
camera and writes it to the app's Documents folder.

This is milestone 1 of 5 — **frame capture only**. No voxelization, stitching,
or JSON export yet.

## Requirements

- Xcode 15 or later
- iOS 17+ deployment target
- **Physical device with a TrueDepth front camera** (iPhone X and later:
  X, XS, XR, 11, 12, 13, 14, 15, 16 series, plus the iPad Pro lines that ship
  TrueDepth). The Simulator does not expose TrueDepth, so you must run on
  real hardware.

## Open & run

```bash
open ios/VoxelScanner/VoxelScanner.xcodeproj
```

1. Select your Apple Developer team under **Signing & Capabilities**.
2. Adjust `PRODUCT_BUNDLE_IDENTIFIER` if `com.voxelz.VoxelScanner` is taken.
3. Plug in an iPhone with TrueDepth, pick it as the run destination, build & run.
4. Grant the camera permission prompt on first launch.
5. Aim at a small object at arm's length and tap the shutter button.

## Output

Each capture creates a timestamped folder at:

```
<App Documents>/captures/YYYYMMDD-HHmmss-SSS/
├── rgb.jpg                # color frame (JPEG, device resolution)
├── depth_float32.bin      # raw depth map, tightly packed Float32 little-endian,
│                          # width × height as listed in intrinsics.json
└── intrinsics.json        # camera calibration + image sizes
```

Pull captures off-device via Xcode → **Window ▸ Devices and Simulators** →
select device → select VoxelScanner → **Download Container**. Captures are
under `AppData/Documents/captures/`.

## What's next

Milestone 2 will turn each saved frame into a colored voxel point cloud in
world space using the intrinsics in `intrinsics.json`. The viewer at the
repo root (`index.html`) will later load a stitched JSON voxel file.
