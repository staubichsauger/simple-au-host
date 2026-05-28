# SimpleAUHost Review Findings

I reviewed the app end to end without editing source. I also ran validation:

`xcodebuild -project SimpleAUHost.xcodeproj -scheme SimpleAUHost -configuration Debug -derivedDataPath build/ReviewDerivedData build` succeeded.

`npm run build` in `companion/simple-au-host` succeeded.

## Highest-Risk Findings

1. **Companion HTTP parser can be crashed by malformed `Content-Length`.**  
   [CompanionControl.swift](SimpleAUHost/CompanionControl.swift:331) parses `content-length` as any `Int`; a negative value makes `bodyOffset..<totalLength` invalid at line 337. Also no max header/body size or connection timeout, so a client can grow memory indefinitely.

   **Comments:** fix this, make it stable and predictable

   **Status:** Implemented in checkpoint `point-1-companion-parser-hardening`.


2. **Companion server is advertised as localhost-only but likely listens on all interfaces.**  
   [CompanionControl.swift](SimpleAUHost/CompanionControl.swift:152) uses `NWListener(using:on:)` with generic TCP parameters, while the UI/docs say `127.0.0.1`. If bound publicly, anyone on the network could trigger Waves Tune actions.

   **Comments:** make it localhost only

   **Status:** Implemented in checkpoint `point-2-localhost-companion-listener`.


3. **"New Show" discards unsaved work with no confirmation.**  
   Loading and closing prompt, but [MultiTrackView.swift](SimpleAUHost/MultiTrackView.swift:1308) calls `createNewSession()` directly. This is the clearest user-facing data-loss path.

   **Comments:** add a confirmation prompt

   **Status:** Implemented in checkpoint `point-3-new-show-confirmation`.


4. **Plugin state reads/writes happen while live audio may still be rendering.**  
   Saving, stopping, copying FX, and parameter preset loading call `serializedPluginStates()` / `applyPluginStates()` against live Audio Units, e.g. [MultiTrackViewModel.swift](SimpleAUHost/MultiTrackViewModel.swift:1480) and [MultiTrackAudioHostController.swift](SimpleAUHost/Audio/MultiTrackAudioHostController.swift:1919). `kAudioUnitProperty_ClassInfo` is not something I'd trust concurrently with render callbacks.

   **Comments:** leave it for, we will discuss later


5. **Plugin editor request block lifetime looks unsafe.**  
   [MultiTrackAudioHostController.swift](SimpleAUHost/Audio/MultiTrackAudioHostController.swift:1082) passes an unretained callback object and only keeps it alive for the synchronous `AudioUnitSetProperty` call. If a plugin calls back asynchronously, this can hang or crash. Add a timeout and retain the callback until completion.

   **Comments:** leave it for, we will discuss later


6. **Capture buffer capacity can diverge from the runtime callback safety limit.**  
   Capture buffers are allocated using the pre-init suggested max at [MultiTrackAudioHostController.swift](SimpleAUHost/Audio/MultiTrackAudioHostController.swift:2105), but `callbackFrameCapacity` is later recalculated from actual AU values at line 1816. If actual max is larger than the earlier allocation, callbacks could write past capture buffers.

   **Comments:** fix this

   **Status:** Implemented in checkpoint `point-6-capture-buffer-capacity`.


## Audio/Realtime Concerns

- Separate input/output devices with the same nominal sample rate can still drift. The app checks nominal sample rate, but not clock sync. Long-running live routing across two independent interfaces can underrun/overrun over time.

  **Comments:** switch to selecting only a single device for input and output

  **Status:** Implemented in checkpoint `audio-single-duplex-interface`.


- Hardware buffer size is changed at [MultiTrackAudioHostController.swift](SimpleAUHost/Audio/MultiTrackAudioHostController.swift:1769) but never restored on stop/failure.

  **Comments:** leave it for, we will discuss later


- Worker shards spin with `sched_yield()` when output rings are full at [MultiTrackAudioHostController.swift](SimpleAUHost/Audio/MultiTrackAudioHostController.swift:1598), which can waste CPU under backpressure.

  **Comments:** leave it for, we will discuss later


- Plugin catalog is cached forever at [AudioHostController.swift](SimpleAUHost/Audio/AudioHostController.swift:142), so installed/removed plugins are not reflected until app restart.

  **Comments:** thats fine


- One bad Core Audio device can make `availableDevices()` fail for all devices because enumeration throws inside the compact map at [AudioHostController.swift](SimpleAUHost/Audio/AudioHostController.swift:94).

  **Comments:** fix this

  **Status:** Implemented in checkpoint `audio-skip-bad-core-audio-devices`.


## UX/Product Gaps

- Rack insert management is incomplete: the view model has remove/reorder methods, but the UI only exposes add/select at [MultiTrackView.swift](SimpleAUHost/MultiTrackView.swift:1022). Users can't cleanly remove or reorder inserts.

  **Comments:** add the missing UI

  **Status:** Implemented in checkpoint `ux-rack-insert-management-ui`.


- Managed session listing accepts every regular file in the Sessions folder, not just `.sahsession`, at [ManagedSessionStore.swift](SimpleAUHost/ManagedSessionStore.swift:58).

  **Comments:** fix this

  **Status:** Implemented in checkpoint `ux-filter-managed-session-files`.


- Startup/open/save work is mostly synchronous on the main actor, including plugin discovery and file reads/writes. This can freeze the UI with many plugins or large session state.

  **Comments:** adjust this

  **Status:** Implemented in checkpoint `ux-async-session-and-startup-io`.


- `formatVersion` exists, but there is no migration/compatibility layer; older session files can fail hard if required fields are missing.

  **Comments:** thats fine


## Feature Ideas

- Add track gain, mute/solo, pan, meters, and output bus/summing mode.

  **Comments:** not for now


- Add per-track latency readout and automatic latency compensation.

  **Comments:** readout would be nice, but no need for compensation

  **Status:** Implemented in checkpoint `feature-track-latency-readout`.


- Add MIDI/OSC/keyboard mapping in addition to Companion.

  **Comments:** not for now


- Add setlist import/export, song reorder, duplicate song, and per-song notes.

  **Comments:** add reorder, duplicate and notes

  **Status:** Implemented in checkpoint `feature-setlist-reorder-duplicate-notes`.


- Add plugin search tags/favorites and chain templates.

  **Comments:** templates should exist, but i think they are not visible in the ui right now

  **Status:** Verified in checkpoint `feature-chain-template-ui-visible`; chain and parameter preset save/load controls are already exposed in the rack footer.


- Add an "audio health" panel: clock drift warning, ring pressure trend, CPU per worker, last dropout reason.

  **Comments:** do it but without adding to performance pressure - we moved it away since collections are expensive

  **Status:** Verified in checkpoint `feature-audio-health-diagnostics-visible`; the Diagnostics panel already uses aggregate counters/summaries without collection-heavy history.


- Add a test target focused on filename/session migration, routing validation, Companion parsing, and the C ring buffer.

  **Comments:** add unit tests where you see fit

  **Status:** Implemented in checkpoint `tests-add-session-store-and-migration-coverage`.


Overall: the app has a solid shape and an ambitious low-latency architecture, but I'd prioritize hardening the Companion HTTP server, unsaved-session handling, live Audio Unit synchronization, and plugin editor lifetime before adding bigger features.

**Comments:** thanks!
