# Develop

This document is for people building or modifying SimpleAUHost. If you only want to use the app, start with `README.md`.

## Repository Layout

- `SimpleAUHost/` - the macOS SwiftUI app and audio engine
- `SimpleAUHostTests/` - unit tests
- `companion/simple-au-host/` - Bitfocus Companion module scaffold for the local control API
- `project.yml` - XcodeGen project definition
- `SimpleAUHost.xcodeproj/` - Xcode project
- `Makefile` - build, bundle, package, and run helpers
- `AGENTS.md` - repository-specific guidance for coding agents

## Requirements

- macOS 14 or newer
- Xcode with the macOS SDK
- Microphone permission granted at runtime for live audio testing

## Build

Preferred commands:

- `make build` - build the release app into `build/DerivedData/Build/Products/Release/SimpleAUHost.app`
- `make run` - build and launch the app bundle
- `make bundle` - stage the built app into `dist/SimpleAUHost.app`
- `make package` - create `dist/SimpleAUHost-Release.zip`
- `make clean` - remove build and distribution artifacts

Direct Xcode builds:

```bash
xcodebuild -project SimpleAUHost.xcodeproj -scheme SimpleAUHost -configuration Debug build
xcodebuild -project SimpleAUHost.xcodeproj -scheme SimpleAUHost -configuration Release build
```

To inspect project schemes and configurations:

```bash
xcodebuild -list -project SimpleAUHost.xcodeproj
```

## Validation

There is currently no dedicated lint command or SwiftLint configuration.

Run a debug build and the unit tests:

```bash
xcodebuild -project SimpleAUHost.xcodeproj -scheme SimpleAUHost -configuration Debug build
xcodebuild test -project SimpleAUHost.xcodeproj -scheme SimpleAUHost -destination 'platform=macOS'
```

To keep build outputs local to the repo during review work:

```bash
xcodebuild -project SimpleAUHost.xcodeproj -scheme SimpleAUHost -configuration Debug -derivedDataPath build/ReviewDerivedData build
xcodebuild test -project SimpleAUHost.xcodeproj -scheme SimpleAUHost -destination 'platform=macOS' -derivedDataPath build/ReviewDerivedData
```

Single test example:

```bash
xcodebuild test -project SimpleAUHost.xcodeproj -scheme SimpleAUHost -destination 'platform=macOS' -only-testing:SimpleAUHostTests/SessionStoreTests/testManagedSessionsOnlyListsSessionFiles
```

To validate the Companion module scaffold:

```bash
cd companion/simple-au-host
npm install
npm run build
```

## Architecture

`SimpleAUHostApp.swift` starts the SwiftUI app and opens `MultiTrackView`.

The main UI/view-model split is centered on multi-track mode:

- `MultiTrackView.swift` and `MultiTrackViewModel.swift` drive the app UI and session workflow.
- `AppCloseCoordinator.swift` owns the macOS window and app close confirmation flow for unsaved multi-track sessions.
- `ManagedSessionStore.swift` manages app-owned storage directories under `~/Music/SAH`.
- `CompanionControl.swift` implements the local HTTP control server used by the multi-track Waves Tune workflow.

The realtime engine lives under `SimpleAUHost/Audio/`:

- `AudioHostController.swift` provides shared device and Audio Unit catalog helpers used by the app.
- `MultiTrackAudioHostController.swift` implements the multi-track engine.

`MultiTrackModels.swift` defines the persistent/configuration model for tracks, layouts, latency classes, and Waves Tune state.

`SimpleAUHost/Support/FloatRingBuffer.{h,c}` provides the lock-free C ring buffer and atomic counters used by the audio engine. Swift accesses it through `SimpleAUHost/Support/SimpleAUHost-Bridging-Header.h`.

## Audio Design Notes

SimpleAUHost hosts one Core Audio I/O device directly through AUHAL input/output units, not through `AVAudioEngine`.

The engine enumerates devices and installed Audio Unit effects through `AudioHostController` helpers, then applies routing and buffer size changes to the selected Core Audio device before starting I/O.

The app uses one selected device for both input and output. There is no aggregate-device management or sample-rate conversion path.

Microphone permission gating happens in the view model before the controller is started.

The project links `Network.framework`; the local Companion control surface is an in-process HTTP server, not a separate helper app or daemon.

## Multi-Track Mode

`MultiTrackViewModel` builds a `MultiTrackHostConfiguration` from global device settings plus a dynamic list of enabled tracks. It is responsible for track sanitization, per-track routing validation, validation of buffered/broadcast internal buffer sizes, and managed session/preset persistence.

`MultiTrackAudioHostController` runs one shared hardware input/output pair and fans audio out to per-track runtimes.

Each enabled track becomes a private `TrackRuntime` instance that owns:

- Its own plugin chain instances
- Per-channel input and output ring buffers
- Scratch buffers
- Dropout counters
- Optionally, its own worker thread for non-realtime latency classes

Track latency class changes execution strategy:

- `realtime` processes directly on the hardware callback cadence.
- `buffered` and `broadcast` process on a background worker using larger internal blocks and output preroll.

The multi-track input callback captures all hardware input channels into per-channel buffers, then each track runtime reads only the configured channel span.

Enabled tracks must use exclusive output channels. The view model validates output routing before the engine starts, so each track writes only to its configured hardware output span and no final-stage track summing is expected.

Stereo support in multi-track mode is per-track. Plugin compatibility for mono versus stereo tracks is checked when each track runtime creates its Audio Unit instance.

Multi-track sessions can be saved, loaded, and tracked for unsaved changes. Closing the main window or quitting the app routes through `AppCloseCoordinator` so the user can save or discard changes.

The multi-track flow also exposes a local Companion control API at `http://127.0.0.1:52719` for Waves Tune key staging and apply actions.

## Working on the Project

Prefer changing view models when adjusting validation, persistence, session state, Companion control behavior, or UI-derived configuration.

Prefer changing controllers only for realtime audio behavior, device routing, or Audio Unit hosting.

Be careful with allocations, locks, and blocking work inside Core Audio callbacks. The existing design pushes buffered/non-realtime work onto worker threads and uses the C ring buffer to cross thread boundaries.

For session and preset persistence work, prefer `ManagedSessionStore.swift` and the related `MultiTrackViewModel` entry points rather than adding ad hoc filesystem access in views.

The Xcode project is generated from `project.yml`. If you need to modify project structure or build settings, update `project.yml` first and regenerate `SimpleAUHost.xcodeproj`.
