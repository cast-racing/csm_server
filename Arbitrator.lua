local state = {}

local extrasCfg = ac.INIConfig.onlineExtras()
local tweaksCfg = extrasCfg and extrasCfg:mapSection('EXTRA_TWEAKS', {
  TARGET_CAR_INDEX = -1,
  TIME_THRESHOLD = 10.0,
  COOLDOWN = 10.0,
}) or {
  TARGET_CAR_INDEX = -1,
  TIME_THRESHOLD = 10.0,
  COOLDOWN = 10.0,
}

local MIN_SPEED = 1.0 / 3.6   -- 1 km/h
local TIME_THRESHOLD = tweaksCfg.TIME_THRESHOLD
local COOLDOWN = tweaksCfg.COOLDOWN
local TARGET_CAR_INDEX = tweaksCfg.TARGET_CAR_INDEX

local SPLINE_EPSILON = 0.0005

local function respawnReasonText(reason)
  if reason == 'off_surface' then
    return 'Invalid surface'
  end

  return 'Not progressing'
end

local function showRespawnMessage(s, title, subtitle)
  local key = title .. '\n' .. subtitle
  if s.messageKey == key then return end

  ac.setMessage(title, subtitle)
  s.messageKey = key
end

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

local function getRespawnReason(car, s)
  local slow = (car.speedMs or 0) < MIN_SPEED
  local progressing = isProgressing(car, s)

  if slow and not progressing then
    return 'stalled'
  end

  if not slow and not hasValidSurface(car) then
    return 'off_surface'
  end

  return nil
end

function script.update(dt)
  local count = sim.carsCount
  if count <= 0 then return end

  local i = TARGET_CAR_INDEX
  if i < 0 then i = carIndex or 0 end
  if i >= count then return end

  local car = ac.getCar(i)
  if not car or not car.isActive then return end

  state[i] = state[i] or {
    lastSpline = nil,
    reason = nil,
    timer = 0,
    cd = 0,
    messageKey = nil
  }

  local s = state[i]

  if s.cd > 0 then
    s.cd = s.cd - dt
    return
  end

  local reason = getRespawnReason(car, s)
  if not reason then
    s.reason = nil
    s.timer = 0
    s.messageKey = nil
    return
  end

  if s.reason == reason then
    s.timer = s.timer + dt
  else
    s.reason = reason
    s.timer = dt
  end

  if s.timer >= TIME_THRESHOLD then
    ac.resetCar()
    showRespawnMessage(s, 'Respawning car', respawnReasonText(reason))
    s.reason = nil
    s.timer = 0
    s.cd = COOLDOWN
  else
    local secondsLeft = math.max(0, math.ceil(TIME_THRESHOLD - s.timer))
    showRespawnMessage(s, 'Respawn in ' .. secondsLeft .. 's', respawnReasonText(reason))
  end
end
