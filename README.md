# Caltech Simulation Mod (Server)

`csp_extra_options.ini` now loads both the speed limiter and `Arbitrator.lua`.

`Arbitrator.lua` shows a respawn countdown when the tracked car is not progressing or is off a valid surface, resets that countdown if the car recovers, and then calls `physics.resetCarState(...)` after `TIME_THRESHOLD` seconds of continuous failure. Its settings live in `[EXTRA_TWEAKS]` alongside the speed limiter values:

- `TARGET_CAR_INDEX`
- `TIME_THRESHOLD`
- `COOLDOWN`
