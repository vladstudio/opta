# Opta

<img src="icon.png" width="128" alt="Opta icon">

A simple macOS app to optimize images, video, and audio.

![Screenshot](opta-screenshot.png)

## Features

### Images
- Drag & drop or select image files (PNG, JPEG, TIFF, GIF, BMP, HEIC, WebP)
- Output as optimized PNG, JPG, or WebP
- Reduce colors: All, 256, 128, 64, 32, 16, 4, 2
- Configurable quality (JPG, WebP)
- Strip metadata

### Video
- Drag & drop or select video files (MP4, MOV, AVI, MKV, WebM, M4V, FLV, WMV, TS, MTS)
- Output as MP4 (H.264), MP4 (H.265), WebM (VP9), MOV, or GIF
- Configurable CRF quality and dimension presets (1080p, 720p, 480p, 360p)
- Strip metadata

### Audio
- Drag & drop or select audio files (MP3, AAC, M4A, FLAC, WAV, OGG, Opus, WMA, AIFF, ALAC)
- Output as MP3, AAC, M4A, OGG Vorbis, Opus, FLAC, or WAV
- Configurable bitrate for lossy formats
- Strip metadata

### General
- Before/after size comparison

## Install

Requires macOS 13+, Homebrew, and Xcode Command Line Tools.

```bash
git clone https://github.com/vladstudio/opta.git
cd opta
./install.sh
```

This will install CLI dependencies (`pngquant`, `oxipng`, `webp`, `ffmpeg`), build a release binary, and copy it to `/usr/local/bin`.

## Usage

```bash
opta
```

## How it works

### Images
1. **Input conversion** (non-PNG only) — `sips` (built into macOS) converts to PNG
2. **Color reduction** (if not "All") — [pngquant](https://pngquant.org/)
3. **PNG optimization** — [oxipng](https://github.com/shssoichern/oxipng) (lossless, configurable level 0–6)
4. **JPG conversion** — `sips` (built into macOS, configurable quality)
5. **WebP conversion** — [cwebp](https://developers.google.com/speed/webp/docs/cwebp)

### Video & Audio
Processed via [ffmpeg](https://ffmpeg.org/). Video supports CRF-based quality control, two-pass VP9 encoding, and palette-optimized GIF conversion. Audio supports lossy (MP3, AAC, Vorbis, Opus) and lossless (FLAC, WAV) formats with configurable bitrate.

Output is saved as `{filename}{suffix}.{ext}` in the same directory as the original. Metadata stripping via tool flags.

## License

MIT
