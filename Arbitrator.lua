local state = {}

local extrasCfg = ac.INIConfig.onlineExtras()
local tweaksCfg = extrasCfg and extrasCfg:mapSection('EXTRA_TWEAKS', {
  TARGET_CAR_INDEX = -1,
  TIME_THRESHOLD = 5.0,
  COOLDOWN = 10.0,
}) or {
  TARGET_CAR_INDEX = -1,
  TIME_THRESHOLD = 5.0,
  COOLDOWN = 10.0,
}

-- First-lap speed limiter defaults (km/h)
local FIRST_LAP_SPEED_LIMIT = 120.0
local FIRST_LAP_BRAKE_FORCE = 0

local MIN_SPEED = 2.0 / 3.6   -- ~2 km/h
local TIME_THRESHOLD = tweaksCfg.TIME_THRESHOLD
local COOLDOWN = tweaksCfg.COOLDOWN
local TARGET_CAR_INDEX = tweaksCfg.TARGET_CAR_INDEX
local RESPAWN_SPAWN_SET = ac.SpawnSet.Pits

local PROTECTED_EXIT_EPSILON = 0.0005
local PROTECTED_ANCHOR_DELAY = 0.1
local PROGRESS_EPSILON = 0.0001
local PROGRESS_WINDOW = 0.5

local function splineDelta(a, b)
  local d = math.abs((a or 0) - (b or 0))
  if d > 0.5 then
    d = 1.0 - d
  end
  return d
end

local function showMessage(s, title, subtitle)
  local key = title .. '\n' .. subtitle
  if s.messageKey == key then return end

  ac.setMessage(title, subtitle)
  s.messageKey = key
end

local function respawnCar(carIndex)
  physics.teleportCarTo(carIndex, RESPAWN_SPAWN_SET)
end

local function isProgressing(car, s)
  s.clock = (s.clock or 0) + (s.lastDt or 0)

  local spline = car.splinePosition or 0
  local samples = s.progressSamples

  samples[#samples + 1] = { t = s.clock, spline = spline }

  local cutoff = s.clock - PROGRESS_WINDOW
  while #samples > 1 and samples[1].t < cutoff do
    table.remove(samples, 1)
  end

  if #samples < 2 then
    return true
  end

  local d = splineDelta(spline, samples[1].spline)

  return d >= PROGRESS_EPSILON
end

local function updateProtectedExit(car, s, dt)
  if not s.awaitingProtectedExit then
    return
  end

  if (s.protectedAnchorDelay or 0) > 0 then
    s.protectedAnchorDelay = math.max(0, s.protectedAnchorDelay - (dt or 0))
    return
  end

  local spline = car.splinePosition or 0

  if s.protectedSpline == nil then
    s.protectedSpline = spline
    return
  end

  local movedAwayFromProtectedSpot = splineDelta(spline, s.protectedSpline) >= PROTECTED_EXIT_EPSILON
  if movedAwayFromProtectedSpot then
    s.awaitingProtectedExit = false
    s.protectedSpline = nil
  end
end

local function getCrashReason(car, s)
  local slow = (car.speedMs or 0) < MIN_SPEED
  if slow and not s.isProgressing then
    return 'stalled'
  end

  return nil
end

local function resetState(s)
  s.remaining = TIME_THRESHOLD
  s.messageKey = nil
end

function script.update(dt)
  if sim.carsCount <= 0 then return end

  local i = TARGET_CAR_INDEX
  if i < 0 then i = carIndex or 0 end
  if i >= sim.carsCount then return end

  local car = ac.getCar(i)
  if not car or not car.isActive then return end

  state[i] = state[i] or {
    clock = 0,
    lastDt = 0,
    progressSamples = {},
    isProgressing = true,
    remaining = TIME_THRESHOLD,
    cooldown = 0,
    messageKey = nil,
    awaitingProtectedExit = true,
    protectedAnchorDelay = 0,
    protectedSpline = car.splinePosition or 0,
    firstLapDone = false,
    prevSpline = car.splinePosition or 0,
    startLapCount = car.lapCount,
  }

  local s = state[i]
  s.lastDt = dt
  s.isProgressing = isProgressing(car, s)
  updateProtectedExit(car, s, dt)

  -- detect first lap completion: prefer explicit `car.lapCount` if available,
  local spline = car.splinePosition or 0
  if not s.firstLapDone then
    if car.lapCount ~= nil then
      local lap = car.lapCount or 0
      if lap >= 1 then
        s.firstLapDone = true
        ac.debug('Arbitrator','first lap detected via lapCount for index '..tostring(i)..' lap='..tostring(lap))
      end
  end
  s.prevSpline = spline

  -- Cooldown (prevents restart spam loop)
  if s.cooldown > 0 then
    s.cooldown = s.cooldown - dt
    resetState(s)
    return
  end

  local reason = getCrashReason(car, s)
  if reason == 'stalled' and s.awaitingProtectedExit then
    resetState(s)
    return
  end

  -- First-lap speed limiter: apply only while first lap not yet completed
  -- and only when the car is not currently stalled/crashed.
  if not s.firstLapDone and reason == nil then
    local speedKmh = car.speedKmh or ((car.speedMs or 0) * 3.6)
    if speedKmh and speedKmh > FIRST_LAP_SPEED_LIMIT then
      physics.forceUserBrakesFor(0.1, FIRST_LAP_BRAKE_FORCE)
      physics.forceUserThrottleFor(0.1, 0)
      showMessage(s, 'Speed cap active', 'First lap limited to ' .. tostring(FIRST_LAP_SPEED_LIMIT) .. ' km/h')
    end
  end

  -- Car recovered: reset timer so the clock starts fresh on the next crash.
  if not reason then
    resetState(s)
    return
  end

  s.remaining = math.max(0, s.remaining - dt)

  if s.remaining <= 0 then
    respawnCar(i)
    s.cooldown = COOLDOWN
    s.awaitingProtectedExit = true
    s.protectedAnchorDelay = PROTECTED_ANCHOR_DELAY
    s.protectedSpline = nil
    s.clock = 0
    s.lastDt = 0
    s.progressSamples = {}
    s.isProgressing = true
    showMessage(s, 'Respawning car', 'Teleporting to pits')
    resetState(s)
  else
    local t = math.ceil(s.remaining)
    showMessage(s, 'Restart in ' .. t .. 's', 'Stalled')
  end
end
