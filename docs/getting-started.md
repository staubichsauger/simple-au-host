# Getting Started

This guide takes you from a downloaded release to a working one-track show. For explanations of every control, continue with the [Complete User Guide](user-guide.md).

## Requirements

- macOS 14 Sonoma or newer
- One Core Audio interface that exposes all required input and output channels
- Audio Unit effects installed on the Mac, if the show uses plugins
- Microphone permission for SimpleAUHost

SimpleAUHost uses the same selected interface for input and output. It does not combine separate devices and does not perform sample-rate conversion.

## Download and install

1. Open the [latest GitHub release](https://github.com/staubichsauger/simple-au-host/releases/latest).
2. Download `SimpleAUHost-macOS-App-<version>.zip`.
3. Unzip the download.
4. Move `SimpleAUHost.app` to Applications.

The app is not currently signed. Only bypass the macOS warning when you trust the copy you downloaded.

To allow the app through System Settings:

1. Try to open SimpleAUHost once.
2. Open **System Settings > Privacy & Security**.
3. Scroll to **Security** and choose **Open Anyway** for SimpleAUHost.
4. Confirm **Open**.

Alternatively, remove the quarantine attribute in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/SimpleAUHost.app
open /Applications/SimpleAUHost.app
```

Change the path if the app is not in Applications.

## Grant microphone permission

Allow microphone access when macOS asks. SimpleAUHost needs this permission for audio input even when the physical source is a line input or a virtual device.

If the prompt was previously denied, open **System Settings > Privacy & Security > Microphone** and enable SimpleAUHost. Restart the app after changing the permission.

## Build a safe first show

Keep speakers and headphones low while establishing the first route.

1. Open **Setup**.
2. Select the audio interface.
3. Choose a conservative hardware buffer such as 128 or 256 frames.
4. Open **Rack**.
5. Keep the default track or add a mono/stereo track.
6. Set its **Input**, **Output**, and **Mode**.
7. Leave the plugin chain empty for the first signal test.
8. Enable the track.
9. Check **Show** for routing warnings.
10. Start the engine with **Stopped** in the top-right corner.
11. Send a low test signal and confirm it reaches only the intended output.
12. Stop the engine before changing routing or adding plugins.

Stereo tracks use two consecutive channels. For example, input `3/4` consumes channels 3 and 4.

## Add a plugin

1. Stop the engine.
2. In **Rack**, choose **Add Plugin** on a track.
3. Click the new empty insert.
4. Search for and select an installed Audio Unit.
5. Use the arrow buttons to reorder inserts if needed.
6. Start the engine.
7. Select an insert to show its live editor in the right-hand panel.

The embedded editor represents the running Audio Unit instance, so it becomes available after the engine starts. Use the pop-out button if the plugin needs more room.

## Save the show

Choose **Save As** in Perform or Show. The default location is:

```text
~/Music/SAH/Sessions
```

Show files use the `.sahsession` extension. Once a file has been saved, **Save** updates it. An asterisk after the show name means there are unsaved changes.

## Optional: prepare live tuning

Load Waves Tune Real-Time on one or more tracks. Recognized tuner tracks appear automatically in **Perform**, where you can:

- enable or bypass tuning globally;
- choose Fast, Standard, Slow, or Custom strength per track;
- build an ordered song list;
- apply major, minor, or chromatic keys without opening plugin editors.

Simple Live Tune integration is also implemented, but that plugin is not currently released as an end-user download.

## Before the first real event

- Reopen the saved show and verify the correct interface is resolved.
- Confirm every enabled track owns unique output channels.
- Test the full plugin chain at realistic signal level.
- Watch **Show > Diagnostics** for dropouts.
- Save after editing the setlist.
- If volunteers operate the event, configure a startup template and Perform-at-launch behavior as described in the [User Guide](user-guide.md#startup-and-template-workflows).
