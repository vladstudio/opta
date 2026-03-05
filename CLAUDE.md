# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is this

Opta — a macOS SwiftUI app that optimizes images. Accepts PNG, JPEG, TIFF, GIF, BMP, HEIC, and WebP as input; outputs optimized PNG, JPG, or WebP. Non-PNG inputs are converted to PNG via macOS built-in `sips` before processing. It shells out to CLI tools (`pngquant`, `oxipng`, `cwebp`) installed via Homebrew. No third-party Swift dependencies.

## Build & Run

```bash
swift build                  # debug build
swift build -c release       # release build
```

No tests exist. No linter configured.

The app requires `pngquant`, `oxipng`, and `cwebp` (from `brew install pngquant oxipng webp`) at runtime. It looks for them in `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`.

## Release

`./release.sh` — bumps version from latest git tag, builds release, assembles `.app` bundle from `Info.plist` + binary + resources, commits, tags, pushes, creates GitHub release with zipped `.app`.

## Architecture

Single-target Swift Package (`Package.swift`, swift-tools-version 5.9, macOS 13+). All source in `Sources/`:

- **OptaApp.swift** — `@main` entry point, single `WindowGroup`
- **ContentView.swift** — entire UI: file list with drag-and-drop, controls (format picker, color slider, quality/optimization sliders, metadata toggle), and `FileRowView` for per-file status display
- **Models.swift** — `OutputFormat` enum (PNG/JPG/WebP), `FileStatus` enum, `FileItem` observable model, `colorSteps` array for quantization levels
- **ProcessingEngine.swift** — `ObservableObject` that runs the optimization pipeline on a background `DispatchQueue`: convert non-PNG to PNG via sips → quantize via pngquant → optimize via oxipng (PNG), convert via sips (JPG), or convert via cwebp (WebP). Uses `Process` to shell out to CLI tools. Supports cancellation via lock-protected flag.

The app is packaged as a `.app` bundle. `Info.plist` lives at repo root (not in Sources). `release.sh` assembles the bundle manually (no Xcode project).
