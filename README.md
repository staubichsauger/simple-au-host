# SimpleAUHost

SimpleAUHost is a macOS app for running Audio Unit effects on live audio without opening a full DAW.

Use it when you want a simple live rack: choose one audio I/O device, create one or more tracks, add Audio Unit effects, and route the processed sound back out.

## Download

Download the latest app from:

https://github.com/staubichsauger/simple-au-host/releases/latest

On the release page, download the `SimpleAUHost-Release.zip` file, unzip it, and move `SimpleAUHost.app` to your Applications folder.

SimpleAUHost is not signed yet, so macOS may block it the first time you open it. Only bypass this warning if you trust the downloaded copy.

To allow it from System Settings:

1. Try opening `SimpleAUHost.app`.
2. When macOS blocks it, open **System Settings > Privacy & Security**.
3. Scroll to the Security section.
4. Click **Open Anyway** for SimpleAUHost.
5. Confirm by clicking **Open**.

You can also allow the app from Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/SimpleAUHost.app
open /Applications/SimpleAUHost.app
```

If you keep the app somewhere other than Applications, replace `/Applications/SimpleAUHost.app` with the actual app path.

## Requirements

- macOS 14 Sonoma or newer
- An audio device with the input and output channels you want to use
- Audio Unit effects installed on your Mac, if you want to use plugins
- Microphone permission for SimpleAUHost

SimpleAUHost uses one device for both input and output. Choose an interface that exposes the inputs and outputs you need.

## First Run

1. Open `SimpleAUHost.app`.
2. Allow microphone access when macOS asks.
3. Choose your audio I/O device.
4. Confirm the device exposes the input and output channels you want to use.
5. Add or enable a track.
6. Choose the track input channels and output channels.
7. Add Audio Unit effects to the track.
8. Start the engine.

Keep your volume low the first time you test a route. Live audio routing can create loud feedback if an output is physically feeding back into an input.

## What It Does

- Runs mono or stereo live tracks
- Routes each track from chosen input channels to chosen output channels
- Keeps enabled track output channels exclusive; two tracks cannot target the same output channel at the same time
- Hosts Audio Unit effects as insert chains
- Saves and loads sessions
- Saves chain presets and parameter presets
- Protects unsaved session changes when closing the app
- Provides local Bitfocus Companion control for tune show workflows

Managed files are stored in your Music folder:

- `~/Music/SAH/Sessions`
- `~/Music/SAH/Chain Presets`
- `~/Music/SAH/Parameter Presets`

## Sessions and Presets

Use sessions when you want to save the whole setup: device choice, tracks, routes, latency choices, and plugin chains.

Use chain presets when you want to reuse a complete plugin chain on another track.

Use parameter presets when you want to reuse settings for a compatible chain without replacing the whole session.

## Tune and Companion

SimpleAUHost includes a local control API for Bitfocus Companion and similar control tools. It is intended for the same Mac as the app and defaults to:

`http://127.0.0.1:52719`

The included Companion module scaffold lives in `companion/simple-au-host/`. It supports tune on/off control, staged key changes, applying staged keys, panic, and next/previous song actions.

Download the installable Companion module from the [GitHub releases page](https://github.com/staubichsauger/simple-au-host/releases).

You only need this if you use Companion or tuner plugins in a show control setup.

## Troubleshooting

**The engine will not start**

Check that macOS microphone permission is enabled for SimpleAUHost in **System Settings > Privacy & Security > Microphone**.

**Device or channel error**

Open **Audio MIDI Setup** and confirm your selected device is available and has the input and output channels you are trying to use.

**I do not see a plugin**

Confirm the plugin is installed as an Audio Unit and restart SimpleAUHost after installing or removing plugins.

**No sound**

Check the selected input channels, output channels, plugin bypass states, and your macOS device levels. Start with one enabled track and no plugins to confirm the route.

**Feedback or very loud sound**

Stop the engine, lower your output volume, and check that speakers are not feeding into live microphones.

## More Information

- See `FEATURES.md` for a fuller feature list.
- See `DEVELOP.md` for build, test, and architecture notes.

## License

Copyright (C) 2026 Tim Schweikert

SimpleAUHost, including the Companion module in this repository, is free
software: you can redistribute it and/or modify it under the terms of the GNU
General Public License as published by the Free Software Foundation, either
version 3 of the License, or (at your option) any later version.

Commercial use is permitted. If you distribute the software or a modified
version, the GPL requires you to make the corresponding source available under
the same license terms.

This software is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. See the [GNU General Public License](LICENSE) for
details.

## Development

SwiftLint is configured with `.swiftlint.yml`. If you are modifying Swift sources, install SwiftLint and run:

```bash
make lint
```
