-- load RACE_FLAGS config
local extras = ac.INIConfig.onlineExtras()
local raceFlags = extras and extras:mapSection('RACE_FLAGS', {
  COMMIT_ZONE_COUNT = 0,
  GHOST_ENABLED = 0
}) or { COMMIT_ZONE_COUNT = 0, GHOST_ENABLED = 0 }

local ghostEnabled = raceFlags.GHOST_ENABLED == 1

local zones = {}
for i = 0, raceFlags.COMMIT_ZONE_COUNT - 1 do
  local z = extras:mapSection('COMMIT_ZONE_' .. i, {
    NAME = 'Zone ' .. i,
    SPLINE_IN = 0,
    SPLINE_OUT = 0
  })
  zones[#zones + 1] = z
end

-- ghost car state
local GHOST_DELAY = 3.0
local ghostHistory = {}
local ghostSplinePos = -1
local ghostWorldPos = vec3()
local ghostActive = false
local sessionTime = 0

local currentFlag = ac.FlagType.None
local FLAG_HOLD_TIME = 2.0
local flagTimer = 0

-- check if spline position is between IN and OUT
local function inZone(splinePos, zone)
  if zone.SPLINE_IN < zone.SPLINE_OUT then
    return splinePos >= zone.SPLINE_IN and splinePos <= zone.SPLINE_OUT
  else
    -- wraps around start/finish
    return splinePos >= zone.SPLINE_IN or splinePos <= zone.SPLINE_OUT
  end
end

-- handles start/finish wrap
local function isAhead(splineA, splineB)
  local d = splineA - splineB
  if d > 0.5 then d = d - 1.0
  elseif d < -0.5 then d = d + 1.0 end
  return d > 0
end

local hasOverrideFlag = type(physics) == 'table' and type(physics.overrideRacingFlag) == 'function'
local hasTrackCoord = type(ac.trackCoordinateToWorld) == 'function'
local hasDrawRaceFlag = type(ui) == 'table' and type(ui.drawRaceFlag) == 'function'

function script.update(dt)
  sessionTime = sessionTime + dt

  local playerCar = car
  local playerSpline = playerCar.splinePosition
  local playerPos = playerCar.position

  -- record and replay ghost position
  ghostActive = false
  if ghostEnabled then
    ghostHistory[#ghostHistory + 1] = {
      time = sessionTime,
      spline = playerSpline,
      pos = vec3(playerPos.x, playerPos.y, playerPos.z)
    }

    while #ghostHistory > 0 and ghostHistory[1].time < sessionTime - 10 do
      table.remove(ghostHistory, 1)
    end

    if sessionTime > GHOST_DELAY + 1 then
      local targetTime = sessionTime - GHOST_DELAY
      for i = #ghostHistory, 1, -1 do
        if ghostHistory[i].time <= targetTime then
          ghostSplinePos = ghostHistory[i].spline
          ghostWorldPos = ghostHistory[i].pos
          ghostActive = true
          break
        end
      end
    end
  end

  local totalCars = sim.carsCount

  local carPositions = {}
  carPositions[#carPositions + 1] = { spline = playerSpline, isPlayer = true }

  for i = 0, totalCars - 1 do
    local c = ac.getCar(i)
    if c and c.isConnected and c.isRemote and c.isActive then
      carPositions[#carPositions + 1] = { spline = c.splinePosition, isPlayer = false }
    end
  end

  -- ghost only used when no real opponents are present
  local hasOpponents = #carPositions > 1
  if not hasOpponents and ghostActive then
    carPositions[#carPositions + 1] = { spline = ghostSplinePos, isPlayer = false }
  end

  local newFlag = ac.FlagType.None
  local newZone = ''
  local newRole = ''

  for _, zone in ipairs(zones) do
    if inZone(playerSpline, zone) then
      for _, other in ipairs(carPositions) do
        if not other.isPlayer and inZone(other.spline, zone) then
          if isAhead(playerSpline, other.spline) then
            newFlag = ac.FlagType.FasterCar -- blue
            newRole = 'DEFENDER'
          else
            newFlag = ac.FlagType.Caution   -- yellow
            newRole = 'ATTACKER'
          end
          newZone = zone.NAME
          break
        end
      end
    end

    if newFlag ~= ac.FlagType.None then break end
  end

  -- hold flag briefly after leaving zone so it doesn't flicker
  if newFlag ~= ac.FlagType.None then
    currentFlag = newFlag
    flagTimer = FLAG_HOLD_TIME
  elseif flagTimer > 0 then
    flagTimer = flagTimer - dt
    if flagTimer <= 0 then
      currentFlag = ac.FlagType.None
      flagTimer = 0
    end
  else
    currentFlag = ac.FlagType.None
  end

  if hasOverrideFlag then
    physics.overrideRacingFlag(currentFlag)
  end

  if newFlag ~= ac.FlagType.None and flagTimer >= FLAG_HOLD_TIME - dt * 2 then
    ac.setMessage(newZone, newRole)
  end
end

function script.draw3D()
  if not hasTrackCoord then return end

  local red = rgbm(3, 0, 0, 1)
  local redFaint = rgbm(1.5, 0, 0, 0.7)
  local green = rgbm(0, 3, 0, 1)
  local greenFaint = rgbm(0, 1.5, 0, 0.7)
  local yellow = rgbm(3, 3, 0, 1)
  local offset = 0.0003

  for _, zone in ipairs(zones) do
    -- entry line (red)
    local leftIn = ac.trackCoordinateToWorld(vec3(-1, 0.3, zone.SPLINE_IN))
    local rightIn = ac.trackCoordinateToWorld(vec3(1, 0.3, zone.SPLINE_IN))
    render.debugLine(leftIn, rightIn, red)
    render.debugLine(
      ac.trackCoordinateToWorld(vec3(-1, 0.3, zone.SPLINE_IN + offset)),
      ac.trackCoordinateToWorld(vec3(1, 0.3, zone.SPLINE_IN + offset)), redFaint)
    render.debugLine(
      ac.trackCoordinateToWorld(vec3(-1, 0.3, zone.SPLINE_IN - offset)),
      ac.trackCoordinateToWorld(vec3(1, 0.3, zone.SPLINE_IN - offset)), redFaint)

    -- exit line (green)
    local leftOut = ac.trackCoordinateToWorld(vec3(-1, 0.3, zone.SPLINE_OUT))
    local rightOut = ac.trackCoordinateToWorld(vec3(1, 0.3, zone.SPLINE_OUT))
    render.debugLine(leftOut, rightOut, green)
    render.debugLine(
      ac.trackCoordinateToWorld(vec3(-1, 0.3, zone.SPLINE_OUT + offset)),
      ac.trackCoordinateToWorld(vec3(1, 0.3, zone.SPLINE_OUT + offset)), greenFaint)
    render.debugLine(
      ac.trackCoordinateToWorld(vec3(-1, 0.3, zone.SPLINE_OUT - offset)),
      ac.trackCoordinateToWorld(vec3(1, 0.3, zone.SPLINE_OUT - offset)), greenFaint)

    -- zone name above entry line
    local center = ac.trackCoordinateToWorld(vec3(0, 0.5, zone.SPLINE_IN))
    render.debugText(center, zone.NAME, yellow, 1.5)
  end

  if ghostActive then
    render.debugCross(ghostWorldPos, 3, rgbm(0, 0, 3, 1))
    render.debugText(vec3(ghostWorldPos.x, ghostWorldPos.y + 3, ghostWorldPos.z), 'GHOST', rgbm(0, 0, 3, 1), 2)
  end
end

function script.drawUI()
  if hasDrawRaceFlag and currentFlag ~= ac.FlagType.None then
    ui.drawRaceFlag(currentFlag)
  end
end
