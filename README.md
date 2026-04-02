# SimpleAUHost

SimpleAUHost is a macOS SwiftUI app for routing live audio from a selected input device through optional Audio Unit effects and back out to a selected output device.

The app has two operating modes:

- **Simple mode**: one input channel, one optional inserted Audio Unit, one output channel.
- **Multi track mode**: multiple mono or stereo tracks with per-track routing, plugin selection, and latency class selection.

## Requirements

- macOS 14 or newer
- Xcode with the macOS SDK
- microphone permission granted at runtime

## Build and run

### Make targets

- `make build` — builds the release app into `build/DerivedData/Build/Products/Release/SimpleAUHost.app`
- `make run` — builds and launches the app
- `make bundle` — copies the built app into `dist/SimpleAUHost.app`
- `make package` — creates `dist/SimpleAUHost-Release.zip`
- `make clean` — removes build and distribution artifacts

### Direct Xcode builds

- `xcodebuild -project SimpleAUHost.xcodeproj -scheme SimpleAUHost -configuration Debug build`
- `xcodebuild -project SimpleAUHost.xcodeproj -scheme SimpleAUHost -configuration Release build`
- `xcodebuild -list -project SimpleAUHost.xcodeproj`

## Validation

There is currently no test target in `SimpleAUHost.xcodeproj` and no dedicated lint configuration in the repository.

For now, the main validation path is a clean build:

- `xcodebuild -project SimpleAUHost.xcodeproj -scheme SimpleAUHost -configuration Debug build`

The Bitfocus Companion module scaffold under `companion/simple-au-host/` can be validated with:

- `cd companion/simple-au-host && npm install`
- `cd companion/simple-au-host && npm run build`

## How it works

This project hosts Core Audio devices directly through AUHAL input and output units rather than `AVAudioEngine`.

At startup, the app shows a mode selector:

- `ContentView.swift` + `HostViewModel.swift` implement simple mode
- `MultiTrackView.swift` + `MultiTrackViewModel.swift` implement multi-track mode
- `HostModeRootView.swift` switches between the two

The realtime audio engines live in `SimpleAUHost/Audio/`:

- `AudioHostController.swift` handles the single-path host
- `MultiTrackAudioHostController.swift` handles the shared-device multi-track host

Both engines rely on the lock-free C ring buffer in `SimpleAUHost/Support/FloatRingBuffer.{h,c}` for moving audio between realtime callbacks and worker threads.

## Architecture notes

- Input and output devices must already use the same nominal sample rate. The app does not perform sample-rate conversion.
- Device enumeration and Audio Unit discovery are done through Core Audio and AudioToolbox APIs in `AudioHostController.swift`.
- Buffer size changes are applied at the Core Audio device level before the host starts.
- Microphone permission is requested by the view models before audio starts.

### Simple mode

Simple mode is a single audio path:

1. capture one selected hardware input channel
2. optionally process it with one Audio Unit effect
3. render the result to one selected hardware output channel

When threaded processing is enabled for a plugin, the controller moves effect rendering onto a dedicated worker thread and bridges between callbacks with ring buffers. This increases latency but reduces the amount of plugin work done directly on the hardware callback.

### Multi-track mode

Multi-track mode runs one shared hardware input/output pair and creates a runtime per enabled track.

Each track can be:

- mono or stereo
- routed from its own input channel span to its own output channel span
- bypassed or assigned its own plugin
- assigned a latency class: `realtime`, `buffered`, or `broadcast`

Non-realtime latency classes use larger internal processing blocks and worker threads. Track outputs are summed together in the final output callback.

## Companion Integration

Multi Track mode now exposes a local control API for Bitfocus Companion on `http://127.0.0.1:52719`.

- The in-app status for this listener is shown in the Setup tab under `Companion Control`.
- The advertised endpoint is `127.0.0.1`, and that is the intended address when Companion runs on the same Mac.
- The API is focused on Waves Tune show control: on/off, panic, staged key selection, apply, and next/previous song stepping.

### API routes

- `GET /api/v1/health`
- `GET /api/v1/state`
- `POST /api/v1/actions/waves-tune/enabled` with `{"enabled":true|false}`
- `POST /api/v1/actions/waves-tune/toggle-enabled`
- `POST /api/v1/actions/waves-tune/staged-key` with `{"root":"g#","scaleMode":"major"}`
- `POST /api/v1/actions/waves-tune/note-letter` with `{"noteLetter":"g"}`
- `POST /api/v1/actions/waves-tune/accidental` with `{"accidental":"sharp"}`
- `POST /api/v1/actions/waves-tune/scale-mode` with `{"scaleMode":"major"}`
- `POST /api/v1/actions/waves-tune/apply`
- `POST /api/v1/actions/waves-tune/panic`
- `POST /api/v1/actions/waves-tune/step-song` with `{"direction":1}` or `{"direction":-1}`

The Companion module scaffold that targets this API lives in `companion/simple-au-host/`.

## Project files

- `project.yml` defines the Xcode project structure and base build settings
- `SimpleAUHost.xcodeproj/project.pbxproj` contains the generated Xcode project

If you change build settings or project structure, update both when necessary.
