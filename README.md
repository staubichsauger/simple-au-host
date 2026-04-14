# SimpleAUHost

SimpleAUHost is a macOS app for hosting Audio Unit effects on live input signals without building a full DAW-style environment.

It is aimed at direct live-routing workflows:

- multi-track input/output routing with per-track processing
- local Bitfocus Companion control for Waves Tune show operations

## What is in this repo

- `SimpleAUHost/` — the macOS SwiftUI app and audio engine
- `companion/simple-au-host/` — Bitfocus Companion module scaffold for the local control API
- `project.yml` — XcodeGen project definition
- `Makefile` — build, bundle, package, and run helpers
- `AGENTS.md` — repository-specific guidance for coding agents

## Current feature set

- **Multi-track mode** for mono/stereo tracks with routing, insert chains, and latency classes
- Managed session and preset storage under `~/Music/SAH`
- Unsaved-session protection on close in multi-track workflows
- Local Companion control API on `127.0.0.1:52719`

For a more detailed feature breakdown, see `FEATURES.md`.

## Requirements

- macOS 14 or newer
- Xcode with the macOS SDK
- microphone permission granted at runtime

## Build

Preferred commands:

- `make build` — build the release app
- `make run` — build and launch the app
- `make bundle` — copy the built app into `dist/SimpleAUHost.app`
- `make package` — create `dist/SimpleAUHost-Release.zip`
- `make clean` — remove build and distribution artifacts

Direct Xcode build:

```bash
xcodebuild -project SimpleAUHost.xcodeproj -scheme SimpleAUHost -configuration Debug build
```

## Validation

There is currently no Xcode test target and no dedicated lint setup.

The main validation path is a clean debug build:

```bash
xcodebuild -project SimpleAUHost.xcodeproj -scheme SimpleAUHost -configuration Debug build
```

To validate the Companion module scaffold:

```bash
cd companion/simple-au-host
npm install
npm run build
```

## Notes

- The app hosts Core Audio devices directly through AUHAL rather than `AVAudioEngine`.
- Input and output devices must already share the same nominal sample rate.
- The Companion API is local-only and intended for use on the same Mac as the app.

## Development

If you are changing project structure or build settings, check both:

- `project.yml`
- `SimpleAUHost.xcodeproj/project.pbxproj`
