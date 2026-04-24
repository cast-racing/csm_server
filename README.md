# Caltech Simulation Mod (Server)

`csp_extra_options.ini` loads `Arbitrator.lua` from the local server files.

`Arbitrator.lua` shows a respawn countdown when the tracked car is not progressing or is off a valid track surface, resets that countdown if the car recovers, and then teleports the car to pits after `TIME_THRESHOLD` seconds of continuous failure. Its settings live in `[EXTRA_TWEAKS]`:

- `TARGET_CAR_INDEX`
- `TIME_THRESHOLD`
- `COOLDOWN`
- `FIRST_LAP_SPEED_LIMIT`
- `FIRST_LAP_BRAKE_FORCE`
