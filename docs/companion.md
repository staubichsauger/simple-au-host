# Bitfocus Companion and Stream Deck

SimpleAUHost includes a dedicated Bitfocus Companion module. It controls the same tune state and setlist shown in the app; it does not talk directly to Audio Units.

## Requirements

- SimpleAUHost running on the same Mac as Companion
- Bitfocus Companion 4.x with support for importing a module package
- The version-matched `SimpleAUHost-Bitfocus-Companion-Module-<version>.tgz` release attachment
- At least one recognized tuner insert for actions to affect live plugins

The app and module should use the same release version.

## Install the module

1. Download `SimpleAUHost-Bitfocus-Companion-Module-<version>.tgz` from the [SimpleAUHost release](https://github.com/staubichsauger/simple-au-host/releases/latest).
2. Open Companion’s **Modules** page.
3. Choose **Import module package** and select the `.tgz` file. Do not extract it.
4. Add a connection using the imported SimpleAUHost module.
5. Set **Host** to `127.0.0.1`.
6. Set **Port** to `52719`.
7. Start SimpleAUHost and confirm the connection becomes OK.

Companion 4’s module manager accepts a `.tgz` through **Import module package**; see the [official Companion module guide](https://companion.free/user-guide/v4.2/config/modules/) if the control has moved in your installed version.

In SimpleAUHost, **Setup > Companion Control** should say:

```text
Listening on http://127.0.0.1:52719
```

## Recommended button layout

A compact operator page can use:

| Button | Press action | Useful display/feedback |
| --- | --- | --- |
| Tune | Toggle Tune On/Off | `tune_enabled` feedback |
| Previous | Previous Song | previous-song key variable |
| Current | No action or Apply Staged Key | selected title, active key, and position variables |
| Next | Next Song | next-song key variable |
| Panic | Key Panic | fixed red styling |
| Apply | Apply Staged Key | staged-differs feedback |

For direct key entry, add buttons that set note letter, accidental, and scale, then a separate Apply button. This prevents an incomplete staged key from becoming live.

## Actions

| Companion action | Result |
| --- | --- |
| **Set Tune On/Off** | Enables or bypasses all recognized tuner instances. |
| **Toggle Tune On/Off** | Flips the current tune enabled state. |
| **Set Staged Key** | Stages a complete root and scale without applying it. |
| **Set Note Letter** | Changes only the staged note letter. |
| **Set Accidental** | Changes only the staged accidental when valid for that note. |
| **Set Scale Mode** | Changes only the staged Chromatic/Major/Minor mode. |
| **Apply Staged Key** | Applies the staged key. |
| **Key Panic** | Applies Chromatic immediately. |
| **Next Song** | Selects the next setlist entry and applies its saved key. |
| **Previous Song** | Selects the previous entry and applies its saved key. |

Next and Previous do not wrap at the ends of the setlist.

## Feedbacks

The module supplies feedbacks for:

- Tune enabled
- Engine running
- Staged key differs from applied key
- Staged note letter
- Staged accidental
- Staged scale mode
- Active key
- Previous song key
- Next song key

Use these to color buttons from actual application state rather than assuming an action succeeded.

## Variables

| Variable | Meaning |
| --- | --- |
| `$(simpleauhost:session_name)` | Current show name, including the unsaved marker |
| `$(simpleauhost:status_message)` | Latest app status |
| `$(simpleauhost:engine_running)` | Engine state |
| `$(simpleauhost:tune_enabled)` | Global tune state |
| `$(simpleauhost:active_key_title)` | Currently active key |
| `$(simpleauhost:staged_key_title)` | Prepared key |
| `$(simpleauhost:applied_key_title)` | Applied key |
| `$(simpleauhost:staged_note_letter)` | Staged note letter |
| `$(simpleauhost:staged_scale_mode)` | Staged scale |
| `$(simpleauhost:staged_accidental)` | Staged accidental |
| `$(simpleauhost:selected_song_title)` | Current setlist song |
| `$(simpleauhost:previous_song_key_title)` | Previous song’s key |
| `$(simpleauhost:next_song_key_title)` | Next song’s key |
| `$(simpleauhost:song_position)` | One-based current position |
| `$(simpleauhost:song_count)` | Number of songs |

## Operating workflow

1. Prepare and save the show in SimpleAUHost.
2. Build or edit its setlist in Perform.
3. Start the audio engine.
4. Confirm Companion displays the correct session, selected song, position, active key, and engine state.
5. Step to the first song.
6. Use Next/Previous during the event.
7. Use Tune or Panic only when needed.

Companion actions that change tuning or song selection update the in-app state. Save the show in SimpleAUHost if those state changes should be retained.

## Local HTTP API

Advanced control surfaces can use the API directly:

```text
http://127.0.0.1:52719
```

Read endpoints:

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/health` | Basic health response |
| `GET` | `/api/v1/health` | Versioned health response |
| `GET` | `/api/v1/state` | Full engine, tune, and setlist state |

Action endpoints:

| Method | Path | JSON body |
| --- | --- | --- |
| `POST` | `/api/v1/actions/tune/enabled` | `{"enabled":true}` |
| `POST` | `/api/v1/actions/tune/toggle-enabled` | `{}` |
| `POST` | `/api/v1/actions/tune/staged-key` | `{"root":"c#","scaleMode":"major"}` |
| `POST` | `/api/v1/actions/tune/scale-mode` | `{"scaleMode":"minor"}` |
| `POST` | `/api/v1/actions/tune/note-letter` | `{"noteLetter":"d"}` |
| `POST` | `/api/v1/actions/tune/accidental` | `{"accidental":"flat"}` |
| `POST` | `/api/v1/actions/tune/apply` | `{}` |
| `POST` | `/api/v1/actions/tune/panic` | `{}` |
| `POST` | `/api/v1/actions/tune/step-song` | `{"direction":1}` or `{"direction":-1}` |

POST requests require `Content-Type: application/json`, including actions with no options. Accepted roots are `c`, `c#`, `db`, `d`, `d#`, `eb`, `e`, `f`, `f#`, `gb`, `g`, `g#`, `ab`, `a`, `a#`, `bb`, and `b`. Scale modes are `chromatic`, `major`, and `minor`.

Example:

```bash
curl -s http://127.0.0.1:52719/api/v1/state

curl -s \
  -H 'Content-Type: application/json' \
  -d '{"direction":1}' \
  http://127.0.0.1:52719/api/v1/actions/tune/step-song
```

The server accepts loopback Host headers and is designed for same-machine use. It is not a network authentication boundary and should not be exposed as a public service.

## Troubleshooting Companion

- **Connection refused:** Start SimpleAUHost and check Setup for `Listening`.
- **Port already in use:** Quit the process using port 52719, then reopen SimpleAUHost.
- **Connection is OK but no plugin changes:** Enable the target track, load a recognized tuner insert, and start the audio engine.
- **Wrong song/key displayed:** Poll state again, confirm the intended show is loaded, and select a song in Perform.
- **Imported module is missing:** Confirm you imported the `.tgz` itself and that the module version is supported by your Companion release.
- **Companion is on another machine:** The app binds to `127.0.0.1`; the supported default workflow is Companion on the same Mac.
