local state = {}

local extrasCfg = ac.INIConfig.onlineExtras()
local ringCfg = extrasCfg and extrasCfg:mapSection('RESPAWN_RING', {
  ENABLED = 1,
  PATH = '/tmp/csm_respawn.ring',
  SLOTS = 128,
  SLOT_SIZE = 1024,
}) or {
  ENABLED = 1,
  PATH = '/tmp/csm_respawn.ring',
  SLOTS = 128,
  SLOT_SIZE = 1024,
}

local respawnRing = nil
if ringCfg.ENABLED == 1 then
  local ok, spsc = pcall(dofile, 'spsc.lua')
  if ok and spsc and spsc.open then
    respawnRing = spsc.open(ringCfg.PATH, ringCfg.SLOTS, ringCfg.SLOT_SIZE)
  end
end

local function emit_respawn_event(carIndex, reason)
  if not respawnRing then return end
  local sim = ac.getSim()
  local payload = string.format('%d|%d|%s|%.3f', os.time(), carIndex, reason or 'unknown', sim and sim.timestamp or 0)
  respawnRing.push(payload)
end

local MIN_SPEED = 1.0 / 3.6   -- 1 km/h
local TIME_THRESHOLD = 10.0
local COOLDOWN = 10.0

local SPLINE_EPSILON = 0.0005

local function hasValidSurface(car)
  local count = 0
  local wheels = car.wheels or {}

  for i = 0, 3 do
    local w = wheels[i]
    if w and w.surface == 0 then
      count = count + 1
    end
  end

  return count >= 2
end

local function isProgressing(car, s)
  local spline = car.splinePosition or 0

  if not s.lastSpline then
    s.lastSpline = spline
    return true
  end

  local d = math.abs(spline - s.lastSpline)

  if d > 0.5 then
    d = 1.0 - d
  end

  s.lastSpline = spline

  return d >= SPLINE_EPSILON
end

function script.update(dt)
  local count = sim.carsCount

  for i = 0, count - 1 do
    local car = ac.getCar(i)

    if car and car.isActive then
      state[i] = state[i] or {
        lastSpline = nil,
        progressT = 0,
        surfaceT = 0,
        cd = 0
      }

      local s = state[i]

      -- cooldown
      if s.cd > 0 then
        s.cd = s.cd - dt
        goto continue
      end

      local speed = car.speedMs or 0
      local slow = speed < MIN_SPEED

      local progressing = isProgressing(car, s)
      local validSurface = hasValidSurface(car)


      if slow then
        if not progressing then
          s.progressT = s.progressT + dt
        else
          s.progressT = 0
        end

        s.surfaceT = 0 

      else
        if not validSurface then
          s.surfaceT = s.surfaceT + dt
        else
          s.surfaceT = 0
        end

        s.progressT = 0
      end

      local shouldRespawn =
        (s.progressT >= TIME_THRESHOLD) or
        (s.surfaceT >= TIME_THRESHOLD)

      if shouldRespawn then
        ac.resetCar(i)
        local reason = (s.progressT >= TIME_THRESHOLD) and 'stalled' or 'off_surface'
        emit_respawn_event(i, reason)
        s.progressT = 0
        s.surfaceT = 0
        s.cd = COOLDOWN
      end

      ::continue::
    end
  end
end