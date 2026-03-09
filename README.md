# csm_server

CSP online scripts for Assetto Corsa multiplayer.

## Setup

```bash
bash encode.sh
```

Make sure `WELCOME_PATH=cfg/welcome.txt` is in the `[DATA]` section of `~/.steam/debian-installation/steamapps/common/assettocorsa/server/presets/SERVER_00/server_cfg.ini`. Then start the server via Content Manager.

## Updating the config

Rerun `bash encode.sh` to copy all files and re-encode `welcome.txt`. Restart the server after.

## Configuration

All settings in `csp_extra_options.ini`.

Set `GHOST_ENABLED = 1` for solo testing (replays your position after 3s). Set to `0` for races.
