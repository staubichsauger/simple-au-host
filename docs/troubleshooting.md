# Troubleshooting

Start with the latest status text and warnings on **Show**. When audio is unstable, enable **Show Diagnostics** and reproduce the issue with safe monitoring levels.

## The app will not open

SimpleAUHost is not currently signed. If macOS says the developer cannot be verified:

1. Try opening the app once.
2. Open **System Settings > Privacy & Security**.
3. Choose **Open Anyway** for SimpleAUHost.

Or, for a trusted copy:

```bash
xattr -dr com.apple.quarantine /Applications/SimpleAUHost.app
```

## The engine will not start

Check all of the following:

- SimpleAUHost is enabled in **System Settings > Privacy & Security > Microphone**.
- The selected interface is connected and available.
- At least one track is enabled.
- Every enabled input/output span exists on the selected interface.
- No two enabled tracks use the same output channel.
- Buffered/Broadcast sizes are whole multiples of the hardware buffer.
- Required Audio Units are installed and compatible with the track’s mono/stereo layout.

The start-failure dialog lists all detected validation failures, not just the first one.

## A saved show reports an unavailable audio device

Shows identify devices by Core Audio UID. Connect or power on the original interface, wait for macOS to enumerate it, and choose **Retry**.

If the original interface is no longer available:

1. Cancel the warning.
2. Select a replacement in Setup.
3. Review every channel route in Rack.
4. Save As to preserve the original show if needed.

## No interface or wrong channel count

- Use **Setup > Refresh Devices**.
- Check the interface in **Audio MIDI Setup**.
- Confirm its current input/output channel configuration and sample rate.
- Quit other software that may be reconfiguring or exclusively holding the interface.
- Reconnect or power-cycle the interface, then refresh again.

## No sound

Reduce the problem to a plain route:

1. Stop the engine.
2. Enable one track only.
3. Remove or set its inserts to Empty.
4. Confirm the input and output channel.
5. Start and test at a low level.

If the plain route works, restore plugins one at a time. Also check plugin bypass, tuner state, interface mixer routing, macOS device levels, cables, and downstream equipment.

## Feedback or unexpectedly loud audio

Stop the engine immediately and lower the physical output level. Check:

- speakers feeding open microphones;
- output channels patched back to selected inputs;
- interface direct monitoring combined with hosted monitoring;
- duplicated external routing;
- an unexpectedly high plugin output or makeup gain.

## A plugin is missing

- Confirm it is installed as an Audio Unit effect, not only VST/VST3/AAX.
- Validate or rescan it with the vendor’s installer or macOS Audio Unit tools.
- Restart SimpleAUHost after installing or removing plugins.
- Check architecture compatibility on Apple silicon.

## A plugin editor does not appear

The embedded editor uses the live Audio Unit instance:

- start the engine;
- select a non-empty insert;
- show the Rack inspector panel;
- select **Plugin** rather than Tuning.

Some Audio Units may provide no custom editor or may fail to create one. Try the insert’s pop-out editor button and check the app status.

## A chain preset will not load

The destination layout must match the preset:

- mono chain preset → mono track;
- stereo chain preset → stereo track.

Stop the engine before loading a chain preset because it replaces the insert chain.

## A parameter preset will not load

Parameter presets require the exact same non-empty plugin identities in the exact same order. Use a chain preset first if you need to recreate the chain, then load the parameter preset.

If loading while running reports a failed plugin, that Audio Unit rejected live state restoration. Stop the engine and try again.

## Central tuning controls show zero instances

The count includes recognized tuner inserts only on enabled tracks. Confirm:

- Waves Tune Real-Time or Simple Live Tune is selected in an insert;
- the track is enabled;
- the plugin appears in the installed Audio Unit inventory.

Other pitch-correction plugins can run in Rack but are not controlled by the centralized Tune interface.

## A staged key will not apply

Apply is disabled when Staged already equals Applied. Choose a different key or scale first.

If the app changes state but no live plugin changes, start the engine and confirm recognized tuner instances are running. Offline changes are saved and applied when the engine starts.

## Next or Previous song does nothing

The controls do not wrap:

- Previous is disabled on the first selected song.
- Next is disabled on the last selected song.
- If no song is selected, Next selects the first song.

## Audio dropouts

Use Show diagnostics during a realistic signal load:

1. Reset dropout stats.
2. Run the show long enough to reproduce the problem.
3. Note Dropouts, Dropped Frames, callback size, worker utilization, and realtime peak.

Then try, one change at a time:

- increase the hardware buffer;
- move non-monitoring tracks from Realtime to Buffered or Broadcast/Post;
- increase the relevant internal buffer;
- increase Broadcast safety preroll;
- bypass high-cost or look-ahead plugins;
- reduce enabled tracks or channel count;
- close other high-load applications.

Avoid placing a path used for live monitoring into Buffered or Broadcast/Post merely to hide overload; those classes intentionally add latency.

## Companion does not connect

Check **Setup > Companion Control**:

- It should listen on `http://127.0.0.1:52719`.
- Companion should use host `127.0.0.1` and port `52719`.
- Companion should run on the same Mac.

Test the API:

```bash
curl -s http://127.0.0.1:52719/api/v1/health
```

If the port is already occupied:

```bash
lsof -nP -iTCP:52719 -sTCP:LISTEN
```

Quit the conflicting process or app, then reopen SimpleAUHost.

## Unsaved changes or unexpected Save As

An asterisk after the show name means there are unsaved changes.

If **Save** opens a file dialog for a show that was loaded at startup, it was probably opened as a protected template. This is intentional: save an event-specific copy, or disable **Open selected show as template** in Setup if overwriting the source should be allowed.

## Collecting useful information for a bug report

Include:

- macOS and SimpleAUHost versions;
- Mac model/processor;
- audio interface, driver, sample rate, and hardware buffer;
- track layouts, latency classes, and internal buffer values;
- Audio Unit names and versions;
- exact steps and the latest Show status/warning;
- a screenshot of Show diagnostics after reproducing the issue;
- whether the issue still occurs with one empty-plugin track.
