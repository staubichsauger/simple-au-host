# Features

This is the concise feature inventory for SimpleAUHost. See the [complete user guide](docs/user-guide.md) for behavior and workflows.

## App Mode

### Multi-Track Mode

Multi-track mode is the larger live rack workflow:

- multiple mono or stereo tracks
- per-track input and output routing
- per-track insert chains
- per-track latency class selection
- exclusive output-channel routing through one shared hardware I/O device
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

## Tune / Companion Control

Multi-track mode includes a centralized live-tuning workflow and local control surface intended for Bitfocus Companion and similar same-machine control workflows.

- local HTTP API on `127.0.0.1:52719`
- connection/status feedback in the app
- ordered show setlist with song titles, notes, and keys
- direct song selection and next/previous stepping
- per-track Fast, Standard, Slow, and Custom tune strength
- direct integration with Waves Tune Real-Time
- development integration with Simple Live Tune
- Tune staged key editing
- apply staged key
- panic action
- next/previous song stepping
- enable/disable control state
- Companion actions, feedbacks, and variables

The Companion module lives in `companion/simple-au-host/`. Installation and use are covered in [docs/companion.md](docs/companion.md).

## Operational Constraints

- macOS only
- microphone permission required before starting audio
- input and output channels must come from the same selected hardware I/O device
- no built-in sample-rate conversion path

## Project State

- `SimpleAUHostTests` covers session storage and compatibility, routing validation, tuner mapping, and Companion request parsing
- SwiftLint is configured in `.swiftlint.yml`
- validation includes lint, a debug build, and unit tests
