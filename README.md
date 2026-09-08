# Dual

An iPhone camera app that records one shot as **two videos at the same time**: a
9:16 portrait clip and a 16:9 landscape clip. Both are saved to Photos with
identical audio and duration. Live previews of both framings are shown stacked
on screen while you record.

## What it does

- Records 9:16 and 16:9 simultaneously from a single camera (other pairs
  available: 1:1 + 16:9, 4:5 + 16:9, 9:16 + 1:1).
- The landscape clip keeps the full sensor width and the portrait clip keeps
  the full sensor height, so the landscape video shows a wider view than the
  portrait one, as in the reference app.
- Live previews show exactly what is being recorded, including zoom and
  filter.
- Zoom chip (0.5x / 1x / 2x / 3x depending on the phone) plus pinch to zoom.
- Filters (Vivid, Warm, Chrome, Fade, Instant, Transfer, Mono, Noir).
- Torch, flip camera, tap to focus and expose, long-press for AE/AF lock,
  snapshot button that saves a still while recording.
- Recording timer driven by the frames actually written, discard
  confirmation, gallery thumbnail of the last take and an "Open Photos"
  shortcut.
- Settings: 1080p or 4K, 24/30/60 fps, HEVC (default) or H.264, layout swap,
  mirrored front camera.
- Camera Control button (iPhone 16 and later): press to start and stop, slide
  for zoom, and a Filter picker in the Camera Control overlay. The Action and
  volume buttons also start and stop recording while the camera is open.
- Liquid Glass controls on iOS 26 and later; translucent fills before that.
- Thermal guard: warns when the phone or camera gets hot and stops recording
  at the critical level. Movie fragments every 2 seconds keep a take
  readable if the app is killed mid-recording.

## Requirements

- Xcode 26 or newer on a Mac (the app uses the iOS 26 SDK's Liquid Glass and
  the iOS 18 SDK's Camera Control APIs; it still runs back to iOS 17).
- An iPhone running iOS 17 or newer (the Simulator has no camera). Tuned for
  the iPhone 17 Pro Max on iOS 26 and 27.
- A free Apple ID is enough to run on your own phone.

## Build and run (about 10 minutes the first time)

1. Clone this repository and open `Dual.xcodeproj` in Xcode.
2. Select the `Dual` target, open **Signing & Capabilities**, tick
   **Automatically manage signing** and pick your Team (your Apple ID).
3. Plug in your iPhone, choose it as the run destination, press **Run**.
4. On the phone, allow Camera, Microphone and Photos when asked. The first
   time, you may need to trust the developer certificate under
   Settings > General > VPN & Device Management.

If `Dual.xcodeproj` will not open in your Xcode version, regenerate it:

```bash
brew install xcodegen
xcodegen generate
```

## Tests

The geometry, format selection, zoom labelling and layout logic live in the
pure-Swift package `DualCore` and run anywhere Swift runs, including Linux:

```bash
cd DualCore
swift test
```

In Xcode, `Cmd+U` on the `Dual` scheme runs the same tests.

## How it works

```
AVCaptureSession (4:3 sensor format, 30 fps)
   |-- AVCaptureVideoDataOutput  -> raw frames
   |-- AVCaptureAudioDataOutput  -> audio samples
            |
   FrameProcessor (Core Image on the GPU)
     rotate upright -> filter -> crop 9:16 -> scale -> BGRA buffer
                              -> crop 16:9 -> scale -> BGRA buffer
            |                                  |
   AVSampleBufferDisplayLayer previews     two AVAssetWriters (one file each)
                                           same start time, same frames,
                                           same audio, same end time
            |
   PHPhotoLibrary (add-only) receives both .mov files
```

- **Format selection** (`DualCore/CaptureFormatSelector`): prefers a 4:3
  sensor format whose short side is at least 1920 px so neither output is
  upscaled at 1080p, then the smallest such format to keep the phone cool.
  Typically 2592x1944 at 30 fps on iPhone 12 to 16.
- **Cropping** (`DualCore/FramingGeometry`): centred crops snapped to even
  pixels. From a 1944x2592 upright frame: portrait 1458x2592, landscape
  1944x1092.
- **Orientation**: raw frames stay in the sensor's native orientation and are
  rotated on the GPU. The rotation comes from
  `AVCaptureDevice.RotationCoordinator`, so phones whose sensors are mounted
  differently still record upright video.
- **Sync**: both writers start their session at the timestamp of the first
  recorded frame, receive the same frames and audio buffers, and end at the
  same timestamp, so durations match to the frame.

## Project layout

```
Dual.xcodeproj/        Xcode 16 project (synchronised folder, no file lists)
Dual/                  iOS app
  Capture/             AVFoundation engine, frame processor, writers, Photos
  Model/               Observable view model and settings persistence
  Views/               SwiftUI screens and controls
DualCore/              Pure Swift package with unit tests
project.yml            XcodeGen fallback description of the project
```

## iPhone 17 Pro Max notes

- The zoom chip follows the system camera: 0.5x, 1x, 2x, 4x; pinch or the
  Camera Control slider reach 25x.
- The front Center Stage camera is a square sensor mounted in portrait and is
  exposed as an ultra-wide device. Discovery, the rotation coordinator and the
  format selector all handle that, so portrait clips from it are upright and
  both crops use the full sensor.
- Defaults are HEVC at 1080p30 (about 7.5 Mbps per clip). 4K30 HEVC runs at
  about 30 Mbps per clip; the A19 Pro handles two 4K encodes comfortably, but
  the 4:3 sensor formats top out at 3024 px on the short side, so 4K clips are
  upscaled 1.27x.
- Not yet adopted, pending a device test: 10-bit HDR (HLG / Dolby Vision)
  recording, and the iOS 26 dynamic aspect ratio API for the front camera.

## Known limits

- Portrait use only. The UI is locked to portrait and the framings assume the
  phone is held upright.
- Photo mode is not included; the snapshot button saves a still from the video
  stream instead.
- Finished clips are moved straight into Photos (no in-app player), so nothing
  is duplicated on disk.
- 4K output upscales the landscape clip slightly on most phones because 4:3
  sensor formats are 3024 px on the short side.
- Not yet compiled on a Mac: the Swift sources have been syntax-checked and the
  DualCore tests pass on Linux, but the first Xcode build may surface small
  fixes. Camera Control and Liquid Glass paths are the newest APIs used and
  the first places to look.
