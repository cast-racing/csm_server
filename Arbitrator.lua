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

local MIN_SPEED = 2.0 / 3.6   -- ~2 km/h
local TIME_THRESHOLD = tweaksCfg.TIME_THRESHOLD
local COOLDOWN = tweaksCfg.COOLDOWN
local TARGET_CAR_INDEX = tweaksCfg.TARGET_CAR_INDEX
local RESPAWN_SPAWN_SET = ac.SpawnSet.Pits

local PROTECTED_EXIT_EPSILON = 0.0005
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

local function debugProgressText(s)
  return 'isProgressing=' .. tostring(s.isProgressing == true)
end

local function debugProtectedDeltaText(car, s)
  if s.protectedSpline == nil then
    return 'protectedDelta=nil'
  end

  local spline = car.splinePosition or 0
  local d = splineDelta(spline, s.protectedSpline)
  return string.format('protectedDelta=%.6f', d)
end

local function debugStatusText(car, s, reason)
  local slow = (car.speedMs or 0) < MIN_SPEED
  return table.concat({
    debugProgressText(s),
    'slow=' .. tostring(slow),
    'protected=' .. tostring(s.awaitingProtectedExit == true),
    debugProtectedDeltaText(car, s),
    'reason=' .. tostring(reason or 'none'),
  }, ' | ')
end

local function updateProtectedExit(car, s)
  if not s.awaitingProtectedExit then
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

local function shouldIgnoreCrashReason(s, reason)
  if reason ~= 'stalled' then
    return false
  end

  return s.awaitingProtectedExit == true
end

local function getCrashReason(car, s)
  local slow = (car.speedMs or 0) < MIN_SPEED
  if slow and not s.isProgressing then
    return 'stalled'
  end

  return nil
end

local function crashReasonText(reason)
  if reason == 'stalled' then return 'Stalled' end
  return 'Crash condition'
end

local function resetState(s)
  s.reason = nil
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
    reason = nil,
    remaining = TIME_THRESHOLD,
    cooldown = 0,
    messageKey = nil,
    awaitingProtectedExit = false,
    protectedSpline = nil,
  }

  local s = state[i]
  s.lastDt = dt
  s.isProgressing = isProgressing(car, s)
  updateProtectedExit(car, s)

  -- Cooldown (prevents restart spam loop)
  if s.cooldown > 0 then
    s.cooldown = s.cooldown - dt
    showMessage(s, 'Respawn Cooldown', debugStatusText(car, s, nil))
    resetState(s)
    return
  end

  local reason = getCrashReason(car, s)
  if reason and shouldIgnoreCrashReason(s, reason) then
    showMessage(s, 'Respawn Debug', debugStatusText(car, s, reason))
    resetState(s)
    return
  end

  -- Car recovered: reset timer so the clock starts fresh on the next crash.
  if not reason then
    showMessage(s, 'Respawn Debug', debugStatusText(car, s, nil))
    resetState(s)
    return
  end

  -- Crash condition changed: reset timer and accumulate from zero again.
  if s.reason ~= reason then
    s.reason = reason
    s.remaining = TIME_THRESHOLD
  end

  s.remaining = math.max(0, s.remaining - dt)

  if s.remaining <= 0 then
    respawnCar(i)
    s.cooldown = COOLDOWN
    s.awaitingProtectedExit = true
    s.protectedSpline = nil
    s.clock = 0
    s.lastDt = 0
    s.progressSamples = {}
    s.isProgressing = true
    showMessage(s, 'Respawning car', 'Teleporting to pits | ' .. debugStatusText(car, s, reason))
    resetState(s)
  else
    local t = math.ceil(s.remaining)
    showMessage(s, 'Restart in ' .. t .. 's', crashReasonText(reason) .. ' | ' .. debugStatusText(car, s, reason))
  end
end
