# Features

This file describes the current user-facing feature set of SimpleAUHost.

## App Modes

### Simple Mode

Simple mode is the fast path for a single live signal chain:

- select one hardware input device and channel
- select one hardware output device and channel
- optionally insert one Audio Unit effect
- run the effect directly on the callback path or on a worker thread
- monitor status, dropout counts, and callback/ring-buffer telemetry

### Multi-Track Mode

Multi-track mode is the larger live rack workflow:

- multiple mono or stereo tracks
- per-track input and output routing
- per-track insert chains
- per-track latency class selection
- summed output through one shared hardware output device
- embedded plugin editor support
- diagnostics for dropouts, callback timing, ring usage, and worker utilization

## Audio Routing and Processing

- Core Audio device hosting through AUHAL
- Audio Unit effect discovery from the installed system/plugin inventory
- hardware buffer size selection within the shared device-supported range
- per-track execution modes:
  - `realtime`
  - `buffered`
  - `broadcast`
- worker-thread processing for non-realtime paths

## Sessions and Presets

Managed files are stored under `~/Music/SAH`:

- `Sessions`
- `Chain Presets`
- `Parameter Presets`

Current workflow support:

- save multi-track sessions
- save multi-track sessions as new files
- load managed sessions from the app-owned sessions folder
- detect unsaved changes
- prompt before discarding or closing unsaved multi-track work
- save and load full track chain presets
- save and load parameter-only presets for compatible chains

## Waves Tune / Companion Control

Multi-track mode includes a local control surface intended for Bitfocus Companion and similar same-machine control workflows.

- local HTTP API on `127.0.0.1:52719`
- connection/status feedback in the app
- Waves Tune staged key editing
- apply staged key
- panic action
- next/previous song stepping
- enable/disable control state

The Companion module scaffold for this API lives in `companion/simple-au-host/`.

## Operational Constraints

- macOS only
- microphone permission required before starting audio
- selected input and output devices must already share the same nominal sample rate
- no built-in sample-rate conversion path

## Project State

- no Xcode test target yet
- no dedicated lint setup yet
- build validation currently relies on successful debug/release builds
