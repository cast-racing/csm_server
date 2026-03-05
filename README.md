# csm_server

CSP online scripts for Assetto Corsa multiplayer.

## Setup

Copy all files to the server config directory:

```bash
AC_CFG=~/.steam/debian-installation/steamapps/common/assettocorsa/server/cfg
cp RaceFlags.lua SpeedLimiter.lua csp_extra_options.ini welcome.txt "$AC_CFG/"
```

Make sure `server_cfg.ini` has `WELCOME_PATH=cfg/welcome.txt`, then start the server via Content Manager.

## Updating the config

If you change `csp_extra_options.ini`, re-copy it and re-encode `welcome.txt`:

```bash
AC_CFG=~/.steam/debian-installation/steamapps/common/assettocorsa/server/cfg
cp csp_extra_options.ini "$AC_CFG/"
cd "$AC_CFG"
python3 -c "
import zlib, base64
with open('csp_extra_options.ini') as f: content = f.read()
b64 = base64.b64encode(zlib.compress(content.encode(), 6)).decode().rstrip('=')
with open('welcome.txt', 'w') as f: f.write('\t' * 32 + '\$CSP0:' + b64)
"
```

Restart the server after.

## Configuration

All settings in `csp_extra_options.ini`.

Set `GHOST_ENABLED = 1` for solo testing (replays your position after 3s). Set to `0` for races.
