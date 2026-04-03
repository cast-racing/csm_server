local state = {}

local MIN_SPEED = 1.5
local RESPAWN_DELAY = 2.0
local COOLDOWN = 3.0

local SPLINE_EPSILON = 0.0005

local function hasValidSurface(car)
  for i = 0, 3 do
    local w = car.wheels and car.wheels[i]
    if w and w.surface == 0 then
      return true
    end
  end
  return false
end

local function isStuck(car, s)
  local speed = car.speedMs or 0
  local spline = car.splinePosition

  if not s.lastSpline then
    s.lastSpline = spline
    return false
  end

  local d = math.abs(spline - s.lastSpline)

  if d > 0.5 then
    d = 1.0 - d
  end

  s.lastSpline = spline

  local noProgress = d < SPLINE_EPSILON
  local slow = speed < MIN_SPEED
  -- edge cases here are: stuck on wall (still on track) off track but still moving
  return slow and (noProgress or (not hasValidSurface(car)))
end

function script.update(dt)
  local count = sim.carsCount

  for i = 0, count - 1 do
    local car = ac.getCar(i)

    if car and car.isActive then
      state[i] = state[i] or { t = 0, cd = 0, lastSpline = nil }

      local s = state[i]

      if s.cd > 0 then
        s.cd = s.cd - dt
        goto continue
      end

      local stuck = isStuck(car, s)

      if stuck then
        s.t = s.t + dt
      else
        s.t = 0
      end

      if s.t > RESPAWN_DELAY then
        ac.resetCar(i)
        s.t = 0
        s.cd = COOLDOWN
      end

      ::continue::
    end
  end
end