local carStates = {}

local CONFIG_DEFAULTS = {
  TARGET_CAR_INDEX = -1,
  TIME_THRESHOLD = 5.0,
  COOLDOWN = 10.0,
  FIRST_LAP_SPEED_LIMIT = 100.0,
  FIRST_LAP_BRAKE_FORCE = 1.0,
}

local MIN_SPEED_MS = 2.0 / 3.6
local PROTECTED_EXIT_EPSILON = 0.0005
local PROTECTED_ANCHOR_DELAY = 0.1
local PROGRESS_EPSILON = 0.0001
local PROGRESS_WINDOW = 0.5
local RESPAWN_SPAWN_SET = ac.SpawnSet.Pits

local function copyTable(source)
  local copy = {}
  for key, value in pairs(source) do
    copy[key] = value
  end
  return copy
end

local function loadTweaksConfig()
  local extrasCfg = ac.INIConfig.onlineExtras()
  if not extrasCfg then
    return copyTable(CONFIG_DEFAULTS)
  end

  return extrasCfg:mapSection('EXTRA_TWEAKS', copyTable(CONFIG_DEFAULTS))
end

local tweaksCfg = loadTweaksConfig()
local TARGET_CAR_INDEX = tweaksCfg.TARGET_CAR_INDEX
local TIME_THRESHOLD = tweaksCfg.TIME_THRESHOLD
local COOLDOWN = tweaksCfg.COOLDOWN
local FIRST_LAP_SPEED_LIMIT = tweaksCfg.FIRST_LAP_SPEED_LIMIT
local FIRST_LAP_BRAKE_FORCE = tweaksCfg.FIRST_LAP_BRAKE_FORCE

local function splineDelta(a, b)
  local delta = math.abs((a or 0) - (b or 0))
  if delta > 0.5 then
    return 1.0 - delta
  end
  return delta
end

local function showMessage(state, title, subtitle)
  local key = title .. '\n' .. subtitle
  if state.messageKey == key then
    return
  end

  ac.setMessage(title, subtitle)
  state.messageKey = key
end

local function getSpeedKmh(car)
  return car.speedKmh or ((car.speedMs or 0) * 3.6)
end

local function resolveCarIndex()
  if sim.carsCount <= 0 then
    return nil
  end

  local targetIndex = TARGET_CAR_INDEX
  if targetIndex < 0 then
    targetIndex = carIndex or 0
  end

  if targetIndex >= sim.carsCount then
    return nil
  end

  return targetIndex
end

local function createCarState(car)
  return {
    clock = 0,
    progressSamples = {},
    isProgressing = true,
    remaining = TIME_THRESHOLD,
    cooldown = 0,
    messageKey = nil,
    awaitingProtectedExit = true,
    protectedAnchorDelay = 0,
    protectedSpline = car.splinePosition or 0,
    firstLapDone = false,
    startLapCount = car.lapCount,
  }
end

local function getCarState(carIndex, car)
  carStates[carIndex] = carStates[carIndex] or createCarState(car)
  return carStates[carIndex]
end

local function resetRecoveryTimer(state)
  state.remaining = TIME_THRESHOLD
  state.messageKey = nil
end

local function resetProgressTracking(state)
  state.clock = 0
  state.progressSamples = {}
  state.isProgressing = true
end

local function armProtectedExit(state)
  state.awaitingProtectedExit = true
  state.protectedAnchorDelay = PROTECTED_ANCHOR_DELAY
  state.protectedSpline = nil
end

local function clearProtectedExit(state)
  state.awaitingProtectedExit = false
  state.protectedSpline = nil
end

local function updateProgressState(car, state, dt)
  state.clock = state.clock + dt

  local spline = car.splinePosition or 0
  local samples = state.progressSamples
  samples[#samples + 1] = { t = state.clock, spline = spline }

  local cutoff = state.clock - PROGRESS_WINDOW
  while #samples > 1 and samples[1].t < cutoff do
    table.remove(samples, 1)
  end

  if #samples < 2 then
    state.isProgressing = true
    return
  end

  state.isProgressing = splineDelta(spline, samples[1].spline) >= PROGRESS_EPSILON
end

local function updateProtectedExit(car, state, dt)
  if not state.awaitingProtectedExit then
    return
  end

  if state.protectedAnchorDelay > 0 then
    state.protectedAnchorDelay = math.max(0, state.protectedAnchorDelay - dt)
    return
  end

  local spline = car.splinePosition or 0
  if state.protectedSpline == nil then
    state.protectedSpline = spline
    return
  end

  if splineDelta(spline, state.protectedSpline) >= PROTECTED_EXIT_EPSILON then
    clearProtectedExit(state)
  end
end

local function updateFirstLapState(car, state)
  if state.startLapCount == nil and car.lapCount ~= nil then
    state.startLapCount = car.lapCount
  end

  if state.firstLapDone or car.lapCount == nil or state.startLapCount == nil then
    return
  end

  if car.lapCount > state.startLapCount then
    state.firstLapDone = true
  end
end

local function isStalled(car, state)
  return (car.speedMs or 0) < MIN_SPEED_MS and not state.isProgressing
end

local function enforceFirstLapSpeedLimit(car, state)
  if state.firstLapDone then
    return
  end

  if getSpeedKmh(car) <= FIRST_LAP_SPEED_LIMIT then
    return
  end

  physics.forceUserBrakesFor(0.5, FIRST_LAP_BRAKE_FORCE)
  physics.forceUserThrottleFor(0.5, 0)
  showMessage(state, 'BRAKING APPLIED', 'Lap 1 capped at ' .. tostring(math.floor(FIRST_LAP_SPEED_LIMIT)) .. ' km/h')
end

local function respawnCar(carIndex, state)
  physics.teleportCarTo(carIndex, RESPAWN_SPAWN_SET)
  state.cooldown = COOLDOWN
  armProtectedExit(state)
  resetProgressTracking(state)
  showMessage(state, 'Respawning car', 'Teleporting to pits')
  resetRecoveryTimer(state)
end

function script.update(dt)
  local targetIndex = resolveCarIndex()
  if targetIndex == nil then
    return
  end

  local car = ac.getCar(targetIndex)
  if not car or not car.isActive then
    return
  end

  local carState = getCarState(targetIndex, car)
  updateProgressState(car, carState, dt)
  updateProtectedExit(car, carState, dt)
  updateFirstLapState(car, carState)

  if carState.cooldown > 0 then
    carState.cooldown = math.max(0, carState.cooldown - dt)
    resetRecoveryTimer(carState)
    return
  end

  local stalled = isStalled(car, carState)
  if stalled and carState.awaitingProtectedExit then
    resetRecoveryTimer(carState)
    return
  end

  if not stalled then
    enforceFirstLapSpeedLimit(car, carState)
    resetRecoveryTimer(carState)
    return
  end

  carState.remaining = math.max(0, carState.remaining - dt)
  if carState.remaining <= 0 then
    respawnCar(targetIndex, carState)
    return
  end

  showMessage(carState, 'Restart in ' .. tostring(math.ceil(carState.remaining)) .. 's', 'Stalled')
end
