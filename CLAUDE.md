# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is this

Opta — a macOS SwiftUI app that optimizes images, video, and audio. Three tabs: Images, Video, Audio. Images accepts PNG, JPEG, TIFF, GIF, BMP, HEIC, WebP as input and outputs optimized PNG, JPG, or WebP. Video and Audio processing uses ffmpeg. No third-party Swift dependencies.

## Build & Run

```bash
swift build                  # debug build
swift build -c release       # release build
```

No tests exist. No linter configured.

The app requires `pngquant`, `oxipng`, `cwebp`, and `ffmpeg` (from `brew install pngquant oxipng webp ffmpeg`) at runtime. It looks for them in `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`.

## Release

`./release.sh` — bumps version from latest git tag, builds release, assembles `.app` bundle from `Info.plist` + binary + resources, commits, tags, pushes, creates GitHub release with zipped `.app`.

## Architecture

Single-target Swift Package (`Package.swift`, swift-tools-version 5.9, macOS 13+). All source in `Sources/`:

- **OptaApp.swift** — `@main` entry point, single `Window`, `AppDelegate` handles file-open events via `AppState`
- **ContentView.swift** — entire UI: tabbed interface (Images/Video/Audio), per-tab file lists with drag-and-drop, per-tab controls (format picker, quality/bitrate/CRF sliders, metadata toggle, dimension presets), and `FileRowView` for per-file status display
- **Models.swift** — `MediaTab` enum, format enums (`ImageOutputFormat`, `VideoOutputFormat`, `AudioOutputFormat`), `DimensionPreset`, `FileStatus` enum, `FileItem` observable model, accepted file type/extension constants, `classifyFile()` helper
- **ProcessingEngine.swift** — `ObservableObject` that runs optimization pipelines on a background `DispatchQueue`. Images: sips → pngquant → oxipng/sips/cwebp. Video/Audio: ffmpeg with format-specific encoding args. Uses `Process` to shell out to CLI tools. Supports cancellation via lock-protected flag.

The app is packaged as a `.app` bundle. `Info.plist` lives at repo root (not in Sources). `release.sh` assembles the bundle manually (no Xcode project).
