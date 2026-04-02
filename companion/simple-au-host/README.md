# SimpleAUHost Companion Module

This Bitfocus Companion module targets the built-in local HTTP control API exposed by SimpleAUHost in Multi Track mode.

## Supported actions

- Waves Tune on/off
- Waves Tune toggle
- set note letter
- set accidental
- set scale mode
- stage key root + scale
- apply staged key
- key panic
- next song
- previous song

## Supported feedbacks

- Waves Tune enabled
- engine running
- staged key differs from applied key

## Variables

- `$(simpleauhost:session_name)`
- `$(simpleauhost:status_message)`
- `$(simpleauhost:engine_running)`
- `$(simpleauhost:waves_tune_enabled)`
- `$(simpleauhost:staged_key_title)`
- `$(simpleauhost:applied_key_title)`
- `$(simpleauhost:selected_song_title)`
- `$(simpleauhost:song_position)`
- `$(simpleauhost:song_count)`

## Local development

```bash
cd companion/simple-au-host
npm install
npm run build
```
