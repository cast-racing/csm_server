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

## Respawn Ring Buffer

`Respawn.lua` publishes respawn events to an SPSC ring buffer so an external process can react (for example, restart your stack).

- Ring settings are in `[RESPAWN_RING]` inside `csp_extra_options.ini`.
- Default ring path is `/tmp/csm_respawn.ring`.
- Event format is `unix_ts|car_index|reason|sim_timestamp`.

Run the Python watcher:

```bash
python3 respawn_ring_watcher.py --verbose
```

Or with custom restart command:

```bash
export RESPAWN_RESTART_CMD="bash ~/ros2_ws/src/robot_bringup/scripts/start_robot.sh"
python3 respawn_ring_watcher.py --verbose
```

## Testing & Verification

### Check if the ring-buffer code is running:

1. **Start the Python watcher with verbose output** to see all events and debug info:
   ```bash
   python3 respawn_ring_watcher.py --verbose
   ```
   This will print the ring path, config, and each respawn event as it arrives.

2. **Monitor the ring file directly**:
   ```bash
   ls -la /tmp/csm_respawn.ring
   stat /tmp/csm_respawn.ring
   ```
   The file should exist and change after respawn events.

3. **Check Lua debug output** in the AC server console (in-game or server logs):
   - `Respawn ring initialized: /tmp/csm_respawn.ring` — Ring loaded on Lua side.
   - `Respawn event emitted: <reason> car=<index>` — Event was pushed to the ring.

4. **Verify the restart command runs**:
   Run the watcher and intentionally trigger a respawn in-game. The verbose output will show:
   ```
   Respawn event: car=0 reason=stalled sim_ts=12.345
     Running: bash ~/ros2_ws/src/robot_bringup/scripts/start_robot.sh
     Restart command succeeded
   ```

### Debug tips:

- If the ring file doesn't exist after a respawn, check that Lua code loaded (look for "Respawn ring initialized" in AC logs).
- If events are queued but not triggering, ensure the watcher didn't drop them with `--drain-on-start`. Use `--no-drain-on-start` to process old events.
- For repeated test runs with the same respawn cause, remember the 2-second dedupe window skips duplicate IDs. Wait 2+ seconds between re-triggering or use `--dedupe-window=0.1` for faster testing.
