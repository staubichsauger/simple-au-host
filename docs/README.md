# SimpleAUHost Documentation

SimpleAUHost is a macOS Audio Unit host for recurring live events. It lets an audio expert prepare routing, plugin chains, latency, tuning, and startup behavior once, while an operator can run the event from a focused setlist and tuning workflow.

## Start here

- [Getting Started](getting-started.md) — install the app, grant permission, and build a safe first show.
- [Complete User Guide](user-guide.md) — every app tab, control, and workflow.
- [Bitfocus Companion and Stream Deck](companion.md) — install the supplied module and build a control surface.
- [Troubleshooting](troubleshooting.md) — startup, device, routing, plugin, audio, and Companion problems.

Developers and contributors should use [DEVELOP.md](../DEVELOP.md). The concise feature inventory is in [FEATURES.md](../FEATURES.md).

## The four workspaces

| Workspace | Use it for |
| --- | --- |
| **Perform** | Run a prepared show, control tuning strength, edit or step through the setlist, and quickly save or load shows. |
| **Rack** | Create mono/stereo tracks, route channels, choose latency classes, build plugin chains, and open plugin editors. |
| **Show** | Manage show files, review warnings and status, and monitor engine diagnostics. |
| **Setup** | Select the audio interface and buffer sizes, configure startup behavior, and check Companion API status. |

The engine control remains visible in the top-right corner on every workspace. Most structural controls are intentionally locked while the engine is running.

## Suggested roles

SimpleAUHost works especially well when responsibilities are split:

- An **audio administrator** selects devices and buffers, builds and tests the rack, prepares tuning inserts, saves a trusted show, and optionally prepares a Companion layout.
- A **show operator** loads that show or a protected template, updates the setlist and song keys, starts the engine, and operates from Perform or Stream Deck.

A single person can of course use both workflows.

## Important safety note

Live audio routes can create very loud feedback. Before starting a new or changed show, lower the monitoring level, verify every input and output channel, and test one track at a time.
