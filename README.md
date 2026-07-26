# SimpleAUHost

SimpleAUHost is a macOS Audio Unit host for live tuning and parallel broadcast processing.

It is designed for recurring live events that are prepared by someone with audio expertise and then operated by volunteers who should not have to learn a DAW or manage a professional live-plugin host. An expert can configure the devices, routing, tuning plugins, latency classes, processing chains, and Stream Deck layout in advance.

Operators can then handle the parts that change for each event, such as building the song list, ordering songs, and assigning their keys. These tasks use a focused workflow that does not require changing the underlying audio setup or opening individual plugin interfaces.

SimpleAUHost can automatically load a prepared show, open directly on the Perform tab, and start the audio engine when it launches. A startup show can also be used as a template, preserving the expert's original configuration while the operator saves event-specific copies.

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
- Assigns realtime, buffered, or broadcast/post processing independently per track
- Runs a low-latency tuning path alongside a heavier livestream mastering path
- Saves and loads sessions
- Saves an ordered tuning setlist with each show
- Steps through prepared songs and applies their keys directly
- Saves chain presets and parameter presets
- Protects unsaved session changes when closing the app
- Automatically loads the last saved show or a selected show at startup
- Can open directly in Perform mode and start the engine automatically
- Loads a startup show as a protected template for event-specific copies
- Provides dedicated Bitfocus Companion integration for Stream Deck control

Managed files are stored in your Music folder:

- `~/Music/SAH/Sessions`
- `~/Music/SAH/Chain Presets`
- `~/Music/SAH/Parameter Presets`

## Why Latency Classes Exist

A live tuning path needs the lowest practical latency, while a livestream mastering chain may contain heavier plugins but is less latency-sensitive. Making both paths share one processing buffer creates a compromise: a larger buffer adds unnecessary tuning latency, while a smaller buffer can make the mastering chain prone to dropouts.

SimpleAUHost assigns a latency class to each track:

- **Realtime** runs latency-sensitive processing on the hardware callback cadence.
- **Buffered** runs more demanding processing in larger internal blocks.
- **Broadcast/Post** provides larger blocks and safety preroll for heavy, non-critical broadcast or mastering paths.

This allows a low-latency tuning chain and a heavy livestream mastering chain to run alongside each other without raising the hardware buffer for the entire show.

## Sessions and Presets

Use sessions when you want to save the whole setup: device choice, tracks, routes, latency choices, and plugin chains.

Use chain presets when you want to reuse a complete plugin chain on another track.

Use parameter presets when you want to reuse settings for a compatible chain without replacing the whole session.

## Prepared Shows and Startup

A saved show contains the device configuration, tracks, channel routing, latency classes, plugin chains, and tuning song list needed for an event.

SimpleAUHost can be configured to:

- Load the last saved show at launch
- Load a specific show at launch
- Open directly on the Perform tab
- Start the audio engine automatically
- Load a specific startup show as a template

Template mode protects the prepared source show. An expert can maintain one trusted technical configuration, while an operator loads it as a template, builds the setlist for the current event, and saves a separate dated copy. This is useful for churches and other organizations with changing weekly setlists and rotating volunteer operators.

## Centralized Tuning and Supported Plugins

SimpleAUHost provides a centralized tuning workflow in the Perform view. Operators can manage the current song, tuning on/off, musical key and scale, tuning strength, and the ordered setlist without opening the individual plugin interfaces.

The Perform controls currently provide dedicated parameter-level integration with [Waves Tune Real-Time](https://www.waves.com/plugins/waves-tune-real-time). Waves Tune Real-Time is a separate commercial Audio Unit and must be installed and licensed independently.

For recognized Waves Tune Real-Time instances, SimpleAUHost controls:

- Tune bypass
- Scale Root and Scale Type
- Tune Speed
- Note Transition

Selecting a song, applying a staged key, or changing a tuning-strength preset updates the relevant plugin parameters directly. The workflow does not depend on scenes or serialized plugin snapshots.

SimpleAUHost also contains equivalent integration for [Simple Live Tune](https://github.com/staubichsauger/simple-live-tune), including bypass, key, scale, retune-speed, and note-transition control. Simple Live Tune is still in development and has not been released yet. Its integration is present for development and testing, but the plugin is not currently available as an end-user download.

Waves and Waves Tune Real-Time are trademarks of Waves Audio Ltd. SimpleAUHost is an independent project and is not affiliated with, sponsored by, or endorsed by Waves Audio Ltd.

## Tune, Setlist, Stream Deck, and Companion

Each saved show can contain an ordered tuning setlist with a name, notes, and musical key for every song. Operators can easily add, duplicate, remove, and reorder songs as the setlist changes from week to week. During the event, selecting the next or previous song applies its key to the supported tuning plugins.

This provides a simple alternative to creating a separate scene or snapshot for every song or key. The operator manages the setlist directly, while the expert-prepared routing, plugin chains, and latency configuration remain unchanged.

The centralized Perform workflow is also exposed through SimpleAUHost's local control API and dedicated Bitfocus Companion module. Companion and Stream Deck act as additional control surfaces for the same tuning state and setlist shown inside the app; they are not required to use the centralized tuning controls. The local API is available at:

`http://127.0.0.1:52719`

It supports tune on/off and toggle, staged key editing, applying the staged key, panic, and next/previous song actions. Feedbacks and variables expose the active key, staged key, engine state, tuning state, selected song, adjacent song keys, and setlist position on the Stream Deck.

The module lives in `companion/simple-au-host/` and can be downloaded from the [GitHub releases page](https://github.com/staubichsauger/simple-au-host/releases).

An expert can prepare the audio system, plugin configuration, and Companion layout in advance. Operators can build the setlist for each event and run the show from SimpleAUHost or Stream Deck without opening plugin interfaces or managing a scene-based workaround.

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
