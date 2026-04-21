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

local SPLINE_EPSILON = 0.0001

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
  local spline = car.splinePosition or 0

  if not s.lastSpline then
    s.lastSpline = spline
    return true
  end

  local d = splineDelta(spline, s.lastSpline)

  s.lastSpline = spline

  return d >= SPLINE_EPSILON
end

local function debugProgressText(s)
  return 'isProgressing=' .. tostring(s.isProgressing == true)
end

local function debugStatusText(car, s, reason)
  local slow = (car.speedMs or 0) < MIN_SPEED
  return table.concat({
    debugProgressText(s),
    'slow=' .. tostring(slow),
    'protected=' .. tostring(s.awaitingProtectedExit == true),
    'reason=' .. tostring(reason or 'none'),
  }, ' | ')
end

local function shouldIgnoreCrashReason(car, s, reason)
  if reason ~= 'stalled' then
    return false
  end

  local spline = car.splinePosition or 0

  if s.awaitingProtectedExit then
    if s.protectedSpline == nil then
      s.protectedSpline = spline
    end

    local leftProtectedSpot = splineDelta(spline, s.protectedSpline) >= SPLINE_EPSILON
    if leftProtectedSpot then
      s.awaitingProtectedExit = false
      s.protectedSpline = nil
    else
      return true
    end
  end

  return false
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
    lastSpline = nil,
    isProgressing = true,
    reason = nil,
    remaining = TIME_THRESHOLD,
    cooldown = 0,
    messageKey = nil,
    awaitingProtectedExit = true,
    protectedSpline = nil,
  }

  local s = state[i]
  s.isProgressing = isProgressing(car, s)

  -- Cooldown (prevents restart spam loop)
  if s.cooldown > 0 then
    s.cooldown = s.cooldown - dt
    showMessage(s, 'Respawn Cooldown', debugStatusText(car, s, nil))
    resetState(s)
    return
  end

  local reason = getCrashReason(car, s)
  if reason and shouldIgnoreCrashReason(car, s, reason) then
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
    showMessage(s, 'Respawning car', 'Teleporting to pits | ' .. debugStatusText(car, s, reason))
    s.cooldown = COOLDOWN
    s.awaitingProtectedExit = true
    s.protectedSpline = nil
    resetState(s)
  else
    local t = math.ceil(s.remaining)
    showMessage(s, 'Restart in ' .. t .. 's', crashReasonText(reason) .. ' | ' .. debugStatusText(car, s, reason))
  end
end
