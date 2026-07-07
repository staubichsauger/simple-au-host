# SimpleAUHost Companion Module

This Bitfocus Companion module targets the built-in local HTTP control API exposed by SimpleAUHost in Multi Track mode.

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
