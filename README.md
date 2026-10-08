# Werter

A native macOS menu bar app that converts photos and videos with a radial wheel.

Hold **⌥ Option** while dragging files anywhere on your Mac. A wheel appears under the cursor; drop on a wedge and the converted copy is saved next to the original. Hold **⇧⌥** for a second wheel of actions such as smart crops and background removal.

## Features

**Convert (⌥-drag)**

| Photos | Videos |
|---|---|
| JPG, PNG, WebP, HEIC, AVIF, TIFF, GIF, BMP, PDF | MP4 (H.264), HEVC, MOV, ProRes, M4A (audio only), GIF |

Photo input also accepts RAW (CR2/CR3, NEF, ARW, RAF, DNG and more), JPEG XL, PSD and anything else macOS can decode. Video input is MOV, MP4, M4V, AVI, 3GP, MTS and MPEG (MKV, WebM, FLV and WMV aren't supported by macOS).

**Actions (⇧⌥-drag)**

- **Photos:** smart crops (1:1, 4:5, 9:16, 16:9), background cutout, 50% / 2048 px resize, strip metadata
- **Videos:** smart crops, mute, shrink to 1080p / 720p, grab the middle frame

Crops use Apple's Vision saliency to keep the subject in frame. Action results are named `{action}-{name}.{ext}`, e.g. `cropped-beach.jpg`.

**Also:** batch conversion, progress in the wheel and then the menu bar with cancel, trackpad haptics and a soft tick per wedge, and a first-run setup screen for folder access. Files are never overwritten.

You can also use **Convert Files…** from the menu bar, or Finder's **Open With**. Press ⇧ with the wheel open to flip between formats and actions.

## Requirements

- macOS 15 or later
- Xcode 16+ (Swift 6 toolchain) to build

## Build

```bash
./scripts/build-app.sh
open "build/Werter.app"
```

Or open `Package.swift` in Xcode. Run the tests with `swift test`.

The build script signs with an Apple Development certificate when one is installed. Otherwise it signs ad-hoc with a fixed identifier so macOS keeps remembering folder permissions between rebuilds.

## License

[MIT](LICENSE). WebP encoding uses [libwebp](https://chromium.googlesource.com/webm/libwebp), © Google, under the BSD 3-Clause license.

## Notes

- Photo conversion uses ImageIO. WebP output uses Google's [libwebp](https://github.com/SDWebImage/libwebp-Xcode) because macOS has no WebP encoder.
- Animated GIFs convert their first frame only; video to GIF is capped at 60 seconds and 640 px.
- Photo metadata is kept when converting, except to WebP.
