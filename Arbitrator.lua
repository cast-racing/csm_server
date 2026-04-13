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

local SPLINE_EPSILON = 0.0005

local function showMessage(s, title, subtitle)
  local key = title .. '\n' .. subtitle
  if s.messageKey == key then return end

  ac.setMessage(title, subtitle)
  s.messageKey = key
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

local function getCrashReason(car, s)
  local slow = (car.speedMs or 0) < MIN_SPEED
  local progressing = isProgressing(car, s)

  if slow and not progressing then
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
  s.reasonTime = 0
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
    reason = nil,
    reasonTime = 0,
    cooldown = 0,
    messageKey = nil
  }

  local s = state[i]

  -- Cooldown (prevents restart spam loop)
  if s.cooldown > 0 then
    s.cooldown = s.cooldown - dt
    resetState(s)
    return
  end

  local reason = getCrashReason(car, s)

  -- Car recovered: reset timer so the clock starts fresh on the next crash.
  if not reason then
    resetState(s)
    return
  end

  -- Crash condition changed: reset timer and accumulate from zero again.
  if s.reason ~= reason then
    s.reason = reason
    s.reasonTime = 0
  end

  s.reasonTime = s.reasonTime + dt

  if s.reasonTime >= TIME_THRESHOLD then
    -- HARD SESSION RESET
    ac.setMessage('SESSION RESTART', 'Crash detected')
    ac.debug('Restarting session due to crash')

    ac.execConsoleCommand('restart_session')

    s.cooldown = COOLDOWN
    resetState(s)
  else
    local remaining = math.max(0, TIME_THRESHOLD - s.reasonTime)
    local t = math.ceil(remaining)
    showMessage(s, 'Restart in ' .. t .. 's', crashReasonText(reason))
  end
end