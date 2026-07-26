# SimpleAUHost Companion Module

This module provides first-class Stream Deck control for the live tuning and setlist workflow built into SimpleAUHost.

It is intended for recurring events in which an expert prepares the audio and tuning system while volunteer operators handle the changing weekly setlist and run the show.

Operators can build the song list directly in SimpleAUHost without editing the underlying audio configuration. Each song carries its musical key, and Companion can step through the list while displaying the current song, adjacent keys, and song position. This provides a simpler alternative to representing every song or key as a separate scene or snapshot.

The module connects to the local HTTP control API exposed by SimpleAUHost and provides actions, feedbacks, and variables for the app's actual tuning and setlist state.

## Supported actions

- Tune on/off
- Tune toggle
- set note letter
- set accidental
- set scale mode
- stage key root + scale
- apply staged key
- key panic
- next song
- previous song

## Supported feedbacks

- Tune enabled
- engine running
- staged key differs from applied key
- staged note letter is
- staged accidental is
- staged scale mode is
- active key is
- previous song key is
- next song key is

## Variables

- `$(simpleauhost:session_name)`
- `$(simpleauhost:status_message)`
- `$(simpleauhost:engine_running)`
- `$(simpleauhost:tune_enabled)`
- `$(simpleauhost:active_key_title)`
- `$(simpleauhost:staged_key_title)`
- `$(simpleauhost:applied_key_title)`
- `$(simpleauhost:staged_note_letter)`
- `$(simpleauhost:staged_scale_mode)`
- `$(simpleauhost:staged_accidental)`
- `$(simpleauhost:selected_song_title)`
- `$(simpleauhost:previous_song_key_title)`
- `$(simpleauhost:next_song_key_title)`
- `$(simpleauhost:song_position)`
- `$(simpleauhost:song_count)`

## Local development

```bash
cd companion/simple-au-host
npm install
npm run build
```
