# AGENTS.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Commands
- `make build` — builds the app into `build/DerivedData/Build/Products/Release/SimpleAUHost.app`.
- `make run` — builds and launches the app bundle.
- `make bundle` — stages the built `.app` into `dist/SimpleAUHost.app`.
- `make package` — zips the staged app into `dist/SimpleAUHost-Release.zip`.
- `make clean` — removes `build/` and `dist/`.
- `xcodebuild -project SimpleAUHost.xcodeproj -scheme SimpleAUHost -configuration Debug build` — local debug build without using the Makefile.
- `xcodebuild -project SimpleAUHost.xcodeproj -scheme SimpleAUHost -configuration Release build` — release build equivalent to `make build`.
- `xcodebuild -list -project SimpleAUHost.xcodeproj` — shows the single app target/scheme and available configurations.

## Tests and linting
- There is currently **no test target** in `SimpleAUHost.xcodeproj`; `xcodebuild -list` shows only the `SimpleAUHost` app target and scheme.
- There is currently **no dedicated lint command** or SwiftLint configuration in the repository.
- For validation today, use a clean debug or release build and treat compiler warnings as the primary signal:
  - `xcodebuild -project SimpleAUHost.xcodeproj -scheme SimpleAUHost -configuration Debug build`
- If a test target is added later, the standard Xcode commands to document are:
  - all tests: `xcodebuild test -project SimpleAUHost.xcodeproj -scheme <TestScheme> -destination 'platform=macOS'`
  - single test: `xcodebuild test -project SimpleAUHost.xcodeproj -scheme <TestScheme> -destination 'platform=macOS' -only-testing:<Target>/<TestClass>/<testMethod>`

## Project structure
- `SimpleAUHostApp.swift` starts the SwiftUI app and opens `HostModeRootView`.
- `HostModeRootView.swift` is the top-level mode switch and mode picker. The app has two user-facing paths:
  - **Simple mode**: single input channel -> optional single inserted Audio Unit -> single output channel.
  - **Multi track mode**: multiple mono/stereo tracks, each with its own routing, plugin chain, session state, and latency class.
- The UI/view-model split is strict:
  - `ContentView.swift` + `HostViewModel.swift` drive simple mode.
  - `MultiTrackView.swift` + `MultiTrackViewModel.swift` drive multi-track mode.
- `AppCloseCoordinator.swift` owns the macOS window/app close confirmation flow for unsaved multi-track sessions.
- `ManagedSessionStore.swift` manages the app-owned storage directories under the user Music folder:
  - `~/Music/SAH/Sessions`
  - `~/Music/SAH/Chain Presets`
  - `~/Music/SAH/Parameter Presets`
- `CompanionControl.swift` implements the local HTTP control server used by the multi-track Waves Tune workflow.
- The realtime engine lives under `SimpleAUHost/Audio/`:
  - `AudioHostController.swift` implements the simple host engine.
  - `MultiTrackAudioHostController.swift` implements the multi-track engine.
- `MultiTrackModels.swift` defines the persistent/configuration model for tracks, layouts, and latency classes.
- `SimpleAUHost/Support/FloatRingBuffer.{h,c}` provides the lock-free C ring buffer and atomic counters used by both audio engines; the Swift code accesses it via `SimpleAUHost/Support/SimpleAUHost-Bridging-Header.h`.

## Architecture notes
- This app hosts Core Audio devices directly through **AUHAL** input/output units, not through `AVAudioEngine`.
- Both engines enumerate devices and installed Audio Unit effects through `AudioHostController` helpers, then apply routing and buffer size changes at the Core Audio device level before starting I/O.
- A hard requirement in both modes is that the selected input and output devices already share the same nominal sample rate. There is no sample-rate conversion path.
- Microphone permission gating happens in the view models before either controller is started.
- The project links `Network.framework`; the local Companion control surface is an in-process HTTP server, not a separate helper app or daemon.

## Simple mode architecture
- `HostViewModel` owns UI state, persists the user’s last selections in `UserDefaults`, validates buffer/threaded-processing settings, and translates the UI into an `AudioHostConfiguration`.
- `AudioHostController` owns the realtime graph:
  - one AUHAL input unit captures a single mapped hardware input channel,
  - one AUHAL output unit renders a single mapped hardware output channel,
  - an optional effect Audio Unit sits between them,
  - a dry ring buffer bridges input and output callbacks.
- When threaded processing is enabled and a plugin is selected, the controller switches to a worker-thread model:
  - input callback writes dry audio into a ring buffer,
  - a dedicated worker thread renders the effect in larger blocks,
  - output callback drains a second ring buffer after a preroll/priming threshold,
  - dropout counters track underruns/overruns and missing callback sample time.
- Effect rendering is always callback-driven through `AudioUnitRender`; in stereo-capable plugin cases, the controller mixes the two effect output channels back down to mono for the hardware output path.

## Multi-track mode architecture
- `MultiTrackViewModel` builds a `MultiTrackHostConfiguration` from global device settings plus a dynamic list of enabled tracks. It is responsible for track sanitization, per-track routing validation, validation of the buffered/broadcast internal buffer sizes, and managed session/preset persistence.
- `MultiTrackAudioHostController` runs one shared hardware input/output pair and fans audio out to per-track runtimes.
- Each enabled track becomes a private `TrackRuntime` instance that owns:
  - its own plugin chain instances,
  - per-channel input and output ring buffers,
  - scratch buffers,
  - its own dropout counters,
  - optionally its own worker thread for non-realtime latency classes.
- Track latency class changes execution strategy:
  - `realtime`: process directly on the hardware callback cadence.
  - `buffered` / `broadcast`: process on a background worker using larger internal blocks and output preroll.
- The multi-track input callback captures **all** hardware input channels into per-channel buffers, then each track runtime reads only the configured channel span.
- The multi-track output callback asks every track runtime to mix into the shared hardware output buffers, so track outputs are summed together at the final render stage.
- Stereo support in multi-track mode is per-track. Plugin compatibility for mono vs stereo tracks is checked when each track runtime creates its Audio Unit instance.
- Multi-track sessions can be saved, loaded, and tracked for unsaved changes; closing the main window or quitting the app routes through `AppCloseCoordinator` so the user can save or discard changes.
- The multi-track flow also exposes a local Companion control API at `http://127.0.0.1:52719` for Waves Tune key staging/apply actions.

## Working on the project
- Prefer changing the view models when adjusting validation, persistence, session state, Companion control behavior, or UI-derived configuration; prefer changing the controllers only for realtime audio behavior, device routing, or Audio Unit hosting.
- Be careful with allocations, locks, and blocking work inside Core Audio callbacks. The existing design pushes buffered/non-realtime work onto worker threads and uses the C ring buffer to cross thread boundaries.
- For session and preset persistence work, prefer `ManagedSessionStore.swift` and the related `MultiTrackViewModel` entry points rather than adding ad hoc filesystem access in views.
- If you need to modify Xcode project structure or build settings, inspect both `project.yml` and `SimpleAUHost.xcodeproj/project.pbxproj`. The presence of `project.yml` suggests the Xcode project may be generated rather than hand-maintained.
