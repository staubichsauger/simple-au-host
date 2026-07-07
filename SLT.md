# Simple Live Tune (SLT) Integration Plan

Integrate the Simple Live Tune plugin (`~/projects/simple-live-tune`) into
SimpleAUHost with the same level of control as Waves Tune Real-Time: direct UI
control (key/scale, strength, bypass) and Stream Deck via the existing
Companion module / HTTP API.

## Plugin identity & control surface

- AU component: type `aufx`, subtype `Sltn`, manufacturer `Stau`,
  name **"Simple Live Tune"**. Match on the component codes (more robust than
  the name matching used for Waves).
- All controls are plain global-scope AU parameters taking **raw values in
  real units** — no `kAudioUnitProperty_ParameterValueFromString` gymnastics
  and no name-token scanning needed. The full table lives in
  `simple-live-tune/README.md` ("Host integration"); the IDs are stable.

Parameters relevant for the host:

| AU Param ID | Name | Values |
|---|---|---|
| 106079 | Key | 0–11 = C..B (semitones from C) |
| 109250890 | Scale | 0 = Chromatic, 1 = Major, 2 = Minor |
| 1213086891 | Retune Speed | ms (0–400) |
| 423325013 | Note Transition | ms (0–200) |
| 773352680 | Bypass | 0/1 |
| 1033072653 | Tune Tolerance | cents (0–50) — SLT-only, optional |
| 451310969 | Vibrato | 0–1 — SLT-only, optional |
| 3165387 | Gate | dBFS (−80..−20) — SLT-only, optional |

Key differences vs. the Waves adapter:
- Scale enum is **0/1/2** (Waves: 1/2/3 via `WavesTuneScaleMode.pluginValue`).
- Root is a plain semitone index **0–11**; enharmonics collapse
  (Db = C# = 1). No 17-entry root table needed:
  `rootIndex = (letterSemitone + accidentalOffset + 12) % 12` with
  C=0 D=2 E=4 F=5 G=7 A=9 B=11 and flat/natural/sharp = −1/0/+1.
- Speed/transition are raw milliseconds (Waves needed ×10 display scaling and
  string round-trips).
- Prefer the `Bypass` **parameter** over `kAudioUnitProperty_BypassEffect`:
  SLT keeps its engine warm, so toggling is click-free. (The property also
  works as a fallback and keeps parity with the Waves code path.)

## Design approach

Keep the existing staged-key / songs / strength workflow and state models
untouched; add SLT as a second tuner backend behind the same actions, so the
Perform tab and every existing Companion button works whether a track has
Waves Tune, SLT, or both.

## Implementation steps

### 1. `Audio/SimpleLiveTuneAdapter.swift` (new)
Mirror `WavesTuneRealtimeAdapter.swift`, but simpler:
- `SimpleLiveTuneParameterMap` with hardcoded parameter ID constants from the
  table above.
- `matches(_ plugin:)` via component subtype/manufacturer (`Sltn`/`Stau`),
  falling back to name `"Simple Live Tune"` if the plugin info model only
  carries names.
- Value mapping helpers:
  - `scaleValue(for: WavesTuneScaleMode) -> Float` → 0/1/2.
  - `keyValue(for: WavesTuneKeySelection) -> Float` → semitone index 0–11
    (reuse the selection's letter/accidental; unlike Waves, every
    letter+accidental combination is representable, but keep the existing
    `normalize()` rules so both tuners stay in sync).
- `TrackRuntime` extension:
  - `setSimpleLiveTuneBypassed(_:)` → parameter 773352680.
  - `applySimpleLiveTuneKeySelection(_:)` → set Scale then Key.
  - `applySimpleLiveTuneStrength(_:)` → set Retune Speed + Note Transition
    with raw ms (see preset mapping below).
  - `currentSimpleLiveTuneStrengthPreset()` → read the two params via
    `AudioUnitGetParameter` (raw values; no display-string parsing).

### 2. Strength preset mapping
`WavesTuneStrengthPreset` values are Waves-tuned (speed 15/20/30,
transition 60/90/120). SLT's retune scale differs (hard snap at 0 ms,
default 20 ms). Add SLT-specific values on the same enum:
- fast: retune 10 ms, transition 30 ms
- standard: retune 20 ms, transition 60 ms (SLT factory default)
- slow: retune 40 ms, transition 100 ms
Match with a ±0.25 ms tolerance like the Waves preset detection. Tune these
by ear later; keep them in one place on the enum.

### 3. ViewModel wiring (`MultiTrackViewModel+WavesTune.swift`)
- `isWavesTuneRealtimePlugin` → generalize to `isTunerPlugin` =
  Waves match || SLT match (used by `configuredWavesTuneRealtimeInsertCount`,
  `performTracks`, `trackHasConfiguredWavesTuneRealtimeInsert`).
- `setWavesTuneEnabled` → also call `setSimpleLiveTuneBypassed`; sum affected
  instance counts for the status message.
- `setActiveWavesTuneKey` → also call `applySimpleLiveTuneKeySelection`.
- `setWavesTuneStrength` / `refreshWavesTuneStrengthSelectionFromRunningEngine`
  → apply/read SLT strength as well; if a track has both tuners with
  diverging values, report `.custom`.
- Consider renaming the extension/state to `…+Tuning` later; not required for
  functionality (session JSON keys stay stable either way).

### 4. HTTP API / Companion
No breaking changes required — all existing endpoints
(`/api/v1/actions/waves-tune/...`) now affect SLT instances too because they
funnel through the generalized ViewModel actions. Optional polish (later):
- Add `simpleLiveTuneInsertCount` to the state payload (apiVersion bump).
- Rename action paths/labels to `tuner/…` with backward-compatible aliases.
- New optional actions for SLT-only params (tolerance, vibrato, gate) if
  Stream Deck control for them turns out useful live.

### 5. UI
- `WavesTuneControls.swift` / Perform tab: works as-is once the ViewModel is
  generalized. Optionally retitle "Waves Tune" → "Tuner".
- Optional (phase 2): an SLT detail section with Tolerance / Vibrato / Gate
  sliders, applied via the adapter — decide after using it live.

### 6. Tests
- `SimpleLiveTuneMappingTests.swift` mirroring `WavesTuneMappingTests`:
  - scale mode → 0/1/2
  - key selection → semitone index for all 17 letter/accidental combos
    (incl. enharmonic pairs mapping to the same index and the normalize
    fallbacks for Cb/B#/E#/Fb)
  - strength preset → ms values and round-trip preset detection
- ViewModel test: track with both tuner types reports combined insert count
  and applies key to both.

## Verification checklist
1. `auval -v aufx Sltn Stau` passes (plugin side; already green).
2. Insert SLT on a track in Multi Track mode → shows up in Perform tab,
   insert count > 0.
3. Apply key from UI → SLT UI (or `auval`-read param) reflects Key/Scale;
   change mid-note and confirm glitch-free glide.
4. Toggle tune on/off from Stream Deck → SLT bypass parameter flips,
   no click on re-enable.
5. Song prev/next from Stream Deck applies the song key to SLT.
6. Mixed session (Waves + SLT on different tracks) → one button drives both.
