--[[
	AutoWallStick (enhanced)

	Sticks you close to walls while you move along them, and gets you past small things in your way.
	You steer; it shapes the line. Works in shift lock too. Running it stops any other script from this
	set that's already running.

	ALONG WALLS
	  * You run DESIRED_WALL_DISTANCE from the wall, on the SHORTEST line: it looks up to BRIDGE_DISTANCE
	    ahead along the wall and heads straight for the furthest point it can reach in a straight line,
	    so it goes straight across recesses / the dent of an L instead of following the wall into them.
	  * Outside corners: wraps you tightly round the edge; past it and still steering straight on, it lets
	    go (turn toward the new face to keep following it).
	  * Pushing straight into a wall: it keeps the direction it already picked (no left/right flicker),
	    and if it has none yet it takes whichever side is open.
	  * Steer away from the wall (more than LEAVE_DOT) and it lets you go.

	SMALL OBSTACLES (only small ones: long things are treated as walls / left to you)
	  * Along a wall: something up to MAX_OBSTACLE_LENGTH long in your lane (a bin, a crate, a post):
	    your line steps out just far enough, just before you reach it, then back in once you're past.
	  * Away from walls: something small right in front of you: it steps you round its nearer end,
	    then gives you back your own direction.

	STUCK (holding a key but not moving, going by your real speed)
	  * It checks which way is actually open and goes that way properly (out of a corner, along the open
	    wall), not inching. Nothing open: it backs out. Still stuck: it jumps.

	Only real walls count: steep (anything you can walk up is floor), tall (checked at two heights, so
	stairs, curbs and short blocks aren't walls) and not a character. IGNORE_PATHS folders are ignored
	completely (KillerDoors by default). Z: on/off.

	Tweak live: _G.AutoWallStickController.Config.BRIDGE_DISTANCE = 30
]]
do
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
if not player then return end

-- Stop ANY script from this set that's already running (so you can swap between them / re-run freely),
-- including copies that errored and left their steering hooked in, and clear their leftover visuals.
do
	for _, key in ipairs({ "AutoWallStickController", "WallCirclerSimpleController", "WallCirclerController",
		"AutoPathController", "PathAssistController" }) do
		local old = _G[key]
		if type(old) == "table" and type(old.Cleanup) == "function" then
			pcall(old.Cleanup)
		end
		_G[key] = nil
	end
	for _, stepName in ipairs({ "AutoWallStickSteer", "WallCirclerSimpleSteer", "WallCirclerSteer",
		"AutoPathSteer", "PathAssistSteer" }) do
		pcall(function() game:GetService("RunService"):UnbindFromRenderStep(stepName) end)
	end
	for _, name in ipairs({ "PathAssist_Visuals", "WallCircler_Visuals", "AutoPath_Visuals", "WallCirclerSimple_Visuals" }) do
		local f = workspace:FindFirstChild(name)
		if f then pcall(function() f:Destroy() end) end
	end
	local pg = game:GetService("Players").LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if pg then
		for _, name in ipairs({ "PathAssistHUD", "WallCirclerHUD", "AutoPathHUD", "WallCirclerSimpleHUD" }) do
			local g = pg:FindFirstChild(name)
			if g then pcall(function() g:Destroy() end) end
		end
	end
end


local controller = {}
_G.AutoWallStickController = controller

------------------------------------------------------------------------
-- CONFIG
------------------------------------------------------------------------
local CONFIG = {
	TOGGLE_KEY = Enum.KeyCode.Z,
	SHIFTLOCK_DISABLES = false,    -- true = no sticking while shift lock is on

	-- folders (paths from Workspace) whose parts are completely ignored: never stuck to, never avoided
	IGNORE_PATHS = {
		{ "Map", "Ingame", "Map", "MapBoundaries", "KillerDoors" },
	},

	-- sticking
	STICK_DETECT_DISTANCE = 2.5,   -- walls closer than this (from your center) can be stuck to
	DESIRED_WALL_DISTANCE = 1.3,   -- your center is kept this far from the wall
	LEAVE_DOT = 0.3,               -- steering away from the wall more than this (~17 degrees) lets go
	MIN_ALONG = 0.15,              -- you must be moving at least a little along the wall (or into it)
	HEAD_ON_DOT = 0.35,            -- less "along" than this = you're pushing into the wall (keeps its side)
	SIDE_MEMORY = 0.6,             -- seconds a picked side is kept while you push into the wall
	HUG_LOOKAHEAD = 2.5,           -- how sharply it pulls you onto your line when there's no long view
	STEER_SMOOTHING = 0.04,        -- seconds
	GRACE_KEEP_SECONDS = 0.12,     -- keep the last wall this long if it's briefly not seen
	SWITCH_MARGIN = 0.5,           -- another wall must be this much closer to switch to it

	-- shortest line along the wall (straight across recesses / the dent of an L)
	BRIDGE = true,
	BRIDGE_DISTANCE = 20,          -- how far ahead along the wall it looks (raise for longer shortcuts)
	BRIDGE_STEP = 2,
	RECESS_DEPTH = 6,              -- how deep a recess/dent it will look into to find the wall beyond it
	BRIDGE_MAX_ANGLE = 40,         -- never aims more than this many degrees in toward the wall

	-- small obstacles
	AVOID = true,                  -- along walls
	FREE_AVOID = true,             -- away from walls (step round small things in front of you)
	MAX_OBSTACLE_LENGTH = 8,       -- along a wall: only things shorter than this get a detour
	MAX_SIDESTEP = 3.5,            -- away from walls: only things you can get round within this get a sidestep
	LOOKAHEAD_TIME = 0.5,          -- how far ahead (seconds of running) it looks for things in the way
	MIN_LOOKAHEAD = 3,
	MAX_LOOKAHEAD = 9,
	REACT_SLOPE = 1.0,             -- it starts moving out (offset needed x this) + REACT_MARGIN studs before it
	REACT_MARGIN = 1.0,            -- (the last moment that still gets past smoothly)
	MAX_DETOUR = 6,                -- along walls: furthest out it will move your line
	DETOUR_STEP = 0.5,
	BODY_RADIUS = 1.2,             -- body size for "will I hit it" (your body is ~1; a little margin)
	BODY_HEIGHTS = { 2.0, 3.5 },   -- above your feet: things lower than ~1 stud you just step over
	RETURN_DELAY = 0.12,           -- the way back in must be clear this long before moving back in

	-- stuck
	STUCK_SPEED = 1.5,             -- holding a move key but moving slower than this...
	STUCK_TIME = 0.25,             -- ...for this long = stuck
	ESCAPE_TIME = 0.35,            -- then it goes the open way, properly, for this long
	ESCAPE_ANGLE = 30,             -- degrees out from the wall while escaping along it
	ESCAPE_CHECK = 2.5,            -- how far a direction must be clear to count as "open"
	UNSTICK_DETOUR = 1.0,          -- along walls, the line also moves out this much...
	UNSTICK_HOLD = 1.0,            -- ...and stays out this long (what snagged you is often invisible to checks)
	JUMP_AFTER_TRIES = 2,          -- still stuck after this many tries: jump

	-- what counts as a wall
	RAY_COUNT = 24,
	WALL_LOW = 2.0,                -- heights above your feet where walls are checked
	WALL_HIGH = 3.5,               -- (shorter than WALL_HIGH = not a wall: stairs, curbs, short blocks)
	WALL_SLANT = 0.8,              -- both heights must hit within this of each other (stairs don't)
	WALL_MAX_SLOPE = 75,           -- steeper than this (degrees) = wall; anything you can walk up = floor
}
controller.Config = CONFIG

------------------------------------------------------------------------
-- STATE
------------------------------------------------------------------------
local running, enabled = true, true
local connections = {}
local char, hrp, humanoid
local TWO_PI = 2 * math.pi
local lastWall = nil            -- { point, part, seen }
local smoothDir = nil
local detour, returnTimer, lastAvoidCheck = 0, 0, 0
local holdLaneUntil = 0
local side, sideTime = nil, 0   -- which way along the wall (+1/-1 relative to the wall's tangent)
local bridgeAim, lastBridge = nil, 0
local freeSide, freeUntil = 0, 0
local stuckTime, stuckTries, freeTime = 0, 0, 0
local escapeDir, escapeUntil = nil, 0

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
params.IgnoreWater = true
params.RespectCanCollide = true -- walk-through decorations don't count

local function findPath(names)
	local inst = workspace
	for _, name in ipairs(names) do
		inst = inst:FindFirstChild(name)
		if not inst then return nil end
	end
	return inst
end

local lastFilterRefresh = 0
local function refreshFilter()
	local list = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then table.insert(list, p.Character) end
	end
	for _, path in ipairs(CONFIG.IGNORE_PATHS) do
		local inst = findPath(path) -- looked up every refresh: works when the map reloads
		if inst then table.insert(list, inst) end
	end
	params.FilterDescendantsInstances = list
end
refreshFilter()

------------------------------------------------------------------------
-- HELPERS
------------------------------------------------------------------------
local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local controls, cameras = nil, nil
pcall(function()
	local ps = player:WaitForChild("PlayerScripts", 5)
	local pm = ps and ps:WaitForChild("PlayerModule", 5)
	if pm then
		local mod = require(pm)
		controls = mod:GetControls()
		pcall(function() cameras = mod:GetCameras() end)
	end
end)

-- What you're pressing (not how fast you're actually going), as a world direction + strength.
-- Uses the game's control module, and the raw keys as a backup.
local function getInput()
	local v = Vector3.zero
	if controls then
		local ok, mv = pcall(controls.GetMoveVector, controls)
		if ok and typeof(mv) == "Vector3" then v = mv end
	end
	if v.Magnitude < 0.05 and not UserInputService:GetFocusedTextBox() then
		local x, z = 0, 0
		if UserInputService:IsKeyDown(Enum.KeyCode.W) or UserInputService:IsKeyDown(Enum.KeyCode.Up) then z -= 1 end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) or UserInputService:IsKeyDown(Enum.KeyCode.Down) then z += 1 end
		if UserInputService:IsKeyDown(Enum.KeyCode.A) or UserInputService:IsKeyDown(Enum.KeyCode.Left) then x -= 1 end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) or UserInputService:IsKeyDown(Enum.KeyCode.Right) then x += 1 end
		v = Vector3.new(x, 0, z)
	end
	local mag = v.Magnitude
	if mag < 0.05 then return nil, 0 end
	local cam = workspace.CurrentCamera
	if not cam then return nil, 0 end
	local look, right = flat(cam.CFrame.LookVector), flat(cam.CFrame.RightVector)
	if look.Magnitude < 1e-3 or right.Magnitude < 1e-3 then return nil, 0 end
	local w = right.Unit * v.X + look.Unit * -v.Z
	if w.Magnitude < 1e-3 then return nil, 0 end
	return w.Unit, math.min(mag, 1)
end

local function isShiftLocked()
	local mlc = cameras and cameras.activeMouseLockController
	if mlc and mlc.GetIsMouseLocked then
		local ok, v = pcall(mlc.GetIsMouseLocked, mlc)
		if ok then return v == true end
	end
	local cam = workspace.CurrentCamera
	return UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
		and cam ~= nil and (cam.Focus.Position - cam.CFrame.Position).Magnitude > 1.5
end

local function getFeetY()
	local hit = workspace:Raycast(hrp.Position, Vector3.new(0, -12, 0), params)
	if hit then return hit.Position.Y end
	local offset = (humanoid.RigType == Enum.HumanoidRigType.R6) and 3 or (humanoid.HipHeight + hrp.Size.Y / 2)
	return hrp.Position.Y - offset
end

local function isSteep(hit)
	if not hit then return false end
	local slope = math.min(humanoid.MaxSlopeAngle or 89, CONFIG.WALL_MAX_SLOPE)
	return math.abs(hit.Normal.Y) < math.cos(math.rad(slope))
end

------------------------------------------------------------------------
-- WALLS
------------------------------------------------------------------------
-- A real wall from `origin` (only X/Z used) in direction dir: steep, and tall + straight up
-- (blocked at both WALL_LOW and WALL_HIGH at about the same distance). Returns hit, distance.
local function wallFrom(origin, feetY, dir, range)
	local low = workspace:Raycast(Vector3.new(origin.X, feetY + CONFIG.WALL_LOW, origin.Z), dir * range, params)
	if not isSteep(low) then return nil end
	local d = flat(low.Position - origin).Magnitude
	local high = workspace:Raycast(Vector3.new(origin.X, feetY + CONFIG.WALL_HIGH, origin.Z),
		dir * (d + CONFIG.WALL_SLANT), params)
	if not isSteep(high) then return nil end
	return low, d
end

local function findWall(center, feetY, extraRange, lockToLast)
	local range = CONFIG.STICK_DETECT_DISTANCE + 0.5 + (extraRange or 0)
	local n = CONFIG.RAY_COUNT
	local step = TWO_PI / n
	local best, bestD, bestA = nil, math.huge, 0
	local onLast, onLastD = nil, math.huge
	for i = 0, n - 1 do
		local a = i * step
		local hit, d = wallFrom(center, feetY, Vector3.new(math.sin(a), 0, math.cos(a)), range)
		if hit then
			if d < bestD then best, bestD, bestA = hit, d, a end
			if lastWall and hit.Instance == lastWall.part and d < onLastD then onLast, onLastD = hit, d end
		end
	end
	if not best then return nil end
	for _, f in ipairs({ -0.5, -0.25, 0.25, 0.5 }) do -- refine (accurate at corners)
		local a = bestA + f * step
		local hit, d = wallFrom(center, feetY, Vector3.new(math.sin(a), 0, math.cos(a)), range)
		if hit and d < bestD then best, bestD = hit, d end
	end
	-- stay on the wall you're on unless another is clearly closer (no corridor flip-flop);
	-- while going round something, always stay on it (the thing you're passing mustn't take over)
	if onLast and onLast.Instance ~= best.Instance and (lockToLast or onLastD < bestD + CONFIG.SWITCH_MARGIN) then
		best, bestD = onLast, onLastD
	end
	return best, bestD
end

------------------------------------------------------------------------
-- BODY CHECKS
------------------------------------------------------------------------
-- How far your body can go from `from` along `delta` before hitting something (nil = all clear).
-- Knee + waist height; things you can walk on don't count.
local function bodyCast(from, feetY, delta)
	if delta.Magnitude < 0.05 then return nil end
	local best = nil
	for _, h in ipairs(CONFIG.BODY_HEIGHTS) do
		local hit = workspace:Spherecast(Vector3.new(from.X, feetY + h, from.Z), CONFIG.BODY_RADIUS, delta, params)
		if hit and isSteep(hit) and (not best or hit.Distance < best) then best = hit.Distance end
	end
	return best
end

-- Lane k = DESIRED + k from the wall. Clear for `length` ahead, and can you get onto it?
local function laneClear(center, feetY, tangent, rhat, dist, k, length)
	local shift = CONFIG.DESIRED_WALL_DISTANCE + k - dist
	local start = center + rhat * shift
	if math.abs(shift) > 0.2 and bodyCast(center, feetY, rhat * shift) then return false end
	return bodyCast(start, feetY, tangent * length) == nil
end

local function smallestClearLane(center, feetY, tangent, rhat, dist, length)
	local k = 0
	while k <= CONFIG.MAX_DETOUR + 1e-6 do
		if laneClear(center, feetY, tangent, rhat, dist, k, length) then return k end
		k += CONFIG.DETOUR_STEP
	end
	return nil
end

-- How long is the thing in your lane (starting hitAt ahead)? nil = longer than MAX_OBSTACLE_LENGTH.
-- Looks back from past the max length for its back end.
local function obstacleLength(center, feetY, tangent, rhat, dist, hitAt)
	local far = hitAt + CONFIG.MAX_OBSTACLE_LENGTH + 1
	local lane0 = center + rhat * (CONFIG.DESIRED_WALL_DISTANCE - dist)
	local back = bodyCast(lane0 + tangent * far, feetY, -tangent * (far - hitAt + 0.5))
	if not back then return nil end
	local len = (far - back) - hitAt
	if len > CONFIG.MAX_OBSTACLE_LENGTH then return nil end
	return math.max(len, 0)
end

-- Shortest line along the wall: probe the wall at points ahead on your line and head for the FURTHEST
-- one (at your lane distance from the wall there) you can reach in a straight line. Goes straight
-- across recesses instead of into them.
local function bridgeAimPoint(center, feetY, tangent, rhat, dist, laneDist)
	local maxIn = math.tan(math.rad(CONFIG.BRIDGE_MAX_ANGLE))
	local s = CONFIG.BRIDGE_DISTANCE
	while s >= CONFIG.BRIDGE_STEP do
		local q = center + tangent * s
		local hit = wallFrom(q, feetY, -rhat, dist + CONFIG.RECESS_DEPTH)
		if hit then
			local n = flat(hit.Normal)
			n = n.Magnitude > 0.1 and n.Unit or rhat
			if n:Dot(rhat) > 0.5 then -- a face looking back at you, i.e. the same side of the wall
				local p = Vector3.new(hit.Position.X, center.Y, hit.Position.Z) + n * laneDist
				local rel = flat(p - center)
				local inward = -rel:Dot(rhat)
				local fwd = rel:Dot(tangent)
				if fwd > 0.5 and inward <= fwd * maxIn and not bodyCast(center, feetY, rel) then
					return p
				end
			end
		end
		s -= CONFIG.BRIDGE_STEP
	end
	return nil
end

------------------------------------------------------------------------
-- STEERING
------------------------------------------------------------------------
local function steer(dir, mag, dt)
	dir = flat(dir)
	if dir.Magnitude < 1e-3 then return end
	dir = dir.Unit
	if smoothDir then
		local b = smoothDir:Lerp(dir, 1 - math.exp(-dt / CONFIG.STEER_SMOOTHING))
		if b.Magnitude > 1e-3 then dir = b.Unit end
	end
	smoothDir = dir
	humanoid:Move(dir * mag, false)
end

local function releaseWall()
	smoothDir, detour, returnTimer, bridgeAim = nil, 0, 0, nil
end

-- Which way along the wall (+1/-1 along tangent0)
local function pickSide(center, feetY, tangent0, along0, now)
	if math.abs(along0) >= CONFIG.HEAD_ON_DOT then
		side, sideTime = (along0 > 0) and 1 or -1, now -- you're clearly going one way: that way
		return side
	end
	-- pushing into the wall: keep the side you had (no left/right flicker)
	if side and now - sideTime < CONFIG.SIDE_MEMORY then
		sideTime = now
		return side
	end
	-- no side yet: the open one
	local plusOpen = not bodyCast(center, feetY, tangent0 * CONFIG.ESCAPE_CHECK)
	local minusOpen = not bodyCast(center, feetY, -tangent0 * CONFIG.ESCAPE_CHECK)
	if plusOpen ~= minusOpen then
		side = plusOpen and 1 or -1
	else
		side = (along0 >= 0) and 1 or -1
	end
	sideTime = now
	return side
end

-- Stuck: go the open way properly. `along` = the direction along whatever you're stuck on,
-- `out` = away from it.
local function startEscape(center, feetY, along, out, now)
	local dir = nil
	if not bodyCast(center, feetY, along * CONFIG.ESCAPE_CHECK) then
		dir = along
	elseif not bodyCast(center, feetY, -along * CONFIG.ESCAPE_CHECK) then
		dir = -along
		side = side and -side or nil
	end
	stuckTries += 1
	if dir then
		local a = math.rad(CONFIG.ESCAPE_ANGLE)
		escapeDir = dir * math.cos(a) + out * math.sin(a)
	else
		escapeDir = out -- boxed in: back out
		humanoid.Jump = true
	end
	if stuckTries >= CONFIG.JUMP_AFTER_TRIES then
		humanoid.Jump = true
		stuckTries = 0
	end
	escapeUntil = now + CONFIG.ESCAPE_TIME
end

-- returns true if you count as stuck right now
local function updateStuck(dt)
	if flat(hrp.AssemblyLinearVelocity).Magnitude < CONFIG.STUCK_SPEED then
		stuckTime += dt
		freeTime = 0
		if stuckTime >= CONFIG.STUCK_TIME then
			stuckTime = 0
			return true
		end
	else
		stuckTime = 0
		freeTime += dt
		if freeTime > 0.5 then stuckTries = 0 end
	end
	return false
end

------------------------------------------------------------------------
-- AWAY FROM WALLS: step round small things in front of you
------------------------------------------------------------------------
local function freeStep(center, feetY, move, mag, dt, now)
	local perp = Vector3.new(-move.Z, 0, move.X)
	if updateStuck(dt) then
		startEscape(center, feetY, perp, -move, now)
	end
	if now < escapeUntil and escapeDir then
		steer(escapeDir, mag, dt)
		return true
	end
	if not CONFIG.FREE_AVOID then return false end

	local look = math.clamp(humanoid.WalkSpeed * mag * CONFIG.LOOKAHEAD_TIME, CONFIG.MIN_LOOKAHEAD, CONFIG.MAX_LOOKAHEAD)
	if freeSide ~= 0 then
		-- keep stepping round it until the way ahead is clear (or you change direction)
		if now > freeUntil or not bodyCast(center, feetY, move * math.min(look, 3)) then
			freeSide = 0
			return false
		end
		steer(move + perp * freeSide, mag, dt)
		return true
	end
	local hitAt = bodyCast(center, feetY, move * look)
	if not hitAt then return false end
	-- small enough to get round? smallest sidestep on either side
	local o = CONFIG.DETOUR_STEP
	while o <= CONFIG.MAX_SIDESTEP + 1e-6 do
		for _, s in ipairs({ 1, -1 }) do
			local start = center + perp * (s * o)
			if not bodyCast(center, feetY, perp * (s * o)) and not bodyCast(start, feetY, move * (hitAt + 2)) then
				if hitAt <= o * CONFIG.REACT_SLOPE + CONFIG.REACT_MARGIN then
					freeSide, freeUntil = s, now + 1.5
					steer(move + perp * s, mag, dt)
					return true
				end
				return false -- not yet: wait until the last moment
			end
		end
		o += CONFIG.DETOUR_STEP
	end
	return false -- too big to step round: that's yours to handle
end

------------------------------------------------------------------------
-- MAIN
------------------------------------------------------------------------
local function onStep(dt)
	if not running or not enabled then return end
	if not (char and hrp and humanoid and hrp.Parent) or humanoid.Health <= 0 then return end
	local now = os.clock()
	if now - lastFilterRefresh > 1 then
		lastFilterRefresh = now
		refreshFilter()
	end
	if CONFIG.SHIFTLOCK_DISABLES and isShiftLocked() then
		lastWall = nil
		releaseWall()
		return
	end

	local move, mag = getInput()
	if not move then
		releaseWall()
		freeSide, stuckTime, stuckTries = 0, 0, 0
		return -- not pressing anything: leave you alone
	end

	local center = hrp.Position
	local feetY = getFeetY()
	local hit, dist = findWall(center, feetY, detour, detour > 0)
	if hit then
		lastWall = { point = hit.Position, part = hit.Instance, seen = now }
	elseif lastWall and now - lastWall.seen < CONFIG.GRACE_KEEP_SECONDS then
		dist = flat(center - lastWall.point).Magnitude
	else
		lastWall = nil
	end
	if not lastWall or dist > CONFIG.STICK_DETECT_DISTANCE + detour then
		releaseWall()
		freeStep(center, feetY, move, mag, dt, now)
		return
	end
	freeSide = 0

	local r = flat(center - lastWall.point)
	if r.Magnitude < 1e-3 then return end
	local rhat = r.Unit -- from the wall toward you
	local away = move:Dot(rhat)
	if away > CONFIG.LEAVE_DOT then
		releaseWall()
		freeStep(center, feetY, move, mag, dt, now)
		return -- you're steering away from it: let go
	end
	local tangent0 = Vector3.new(-rhat.Z, 0, rhat.X)
	local along0 = move:Dot(tangent0)
	if math.abs(along0) < CONFIG.MIN_ALONG and away > -0.5 then
		releaseWall()
		return -- not really moving along it
	end
	local tangent = tangent0 * pickSide(center, feetY, tangent0, along0, now)

	-- STUCK? go the open way properly
	if updateStuck(dt) then
		startEscape(center, feetY, tangent, rhat, now)
		detour = math.min(detour + CONFIG.UNSTICK_DETOUR, CONFIG.MAX_DETOUR)
		holdLaneUntil = now + CONFIG.ESCAPE_TIME + CONFIG.UNSTICK_HOLD
	end
	if now < escapeUntil and escapeDir then
		steer(escapeDir, mag, dt)
		return
	end

	-- small obstacles in your lane: step the line out at the last moment, only for short things
	local look = math.clamp(humanoid.WalkSpeed * mag * CONFIG.LOOKAHEAD_TIME, CONFIG.MIN_LOOKAHEAD, CONFIG.MAX_LOOKAHEAD)
	if CONFIG.AVOID and now - lastAvoidCheck >= 0.05 then
		lastAvoidCheck = now
		local k = smallestClearLane(center, feetY, tangent, rhat, dist, look) or 0
		if k > detour then
			if detour > 0 then
				detour, returnTimer = k, 0 -- already going round something: widen right away
			else
				local hitAt = bodyCast(center + rhat * (CONFIG.DESIRED_WALL_DISTANCE - dist), feetY, tangent * look)
				local short = hitAt and obstacleLength(center, feetY, tangent, rhat, dist, hitAt)
				if hitAt and short and hitAt <= k * CONFIG.REACT_SLOPE + CONFIG.REACT_MARGIN then
					detour, returnTimer = k, 0
				end
			end
		elseif k < detour and now >= holdLaneUntil then
			returnTimer += 0.05
			if returnTimer >= CONFIG.RETURN_DELAY then
				detour, returnTimer = k, 0 -- the way back in has been clear for a moment
			end
		else
			returnTimer = 0
		end
	end

	-- the line: the furthest point along the wall you can reach straight (shortest), else a tight hug
	local laneDist = CONFIG.DESIRED_WALL_DISTANCE + detour
	if CONFIG.BRIDGE and now - lastBridge >= 0.05 then
		lastBridge = now
		bridgeAim = bridgeAimPoint(center, feetY, tangent, rhat, dist, laneDist)
	end
	local dir
	if bridgeAim and flat(bridgeAim - center):Dot(tangent) > 1 then
		dir = flat(bridgeAim - center)
	else
		local offset = laneDist - dist
		dir = tangent * CONFIG.HUG_LOOKAHEAD + rhat * offset
		if offset < -0.05 and bodyCast(center, feetY, dir) then
			dir = tangent * (CONFIG.HUG_LOOKAHEAD * 3) + rhat * offset -- ease in: the sharp line would clip something
		end
	end
	steer(dir, mag, dt)
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------
local function onCharacterAdded(c)
	char = c
	humanoid = c:WaitForChild("Humanoid", 5)
	hrp = c:WaitForChild("HumanoidRootPart", 5)
	lastWall = nil
	releaseWall()
	refreshFilter()
end
if player.Character then task.spawn(onCharacterAdded, player.Character) end
connections[#connections + 1] = player.CharacterAdded:Connect(onCharacterAdded)

connections[#connections + 1] = UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or not running then return end
	if input.KeyCode == CONFIG.TOGGLE_KEY then
		enabled = not enabled
		lastWall = nil
		releaseWall()
		print("[AutoWallStick] " .. (enabled and "on" or "off"))
	end
end)

-- runs right after the default controls, so our Move wins
local STEP_NAME = "AutoWallStickSteer"
local lastErrorWarn = 0
pcall(function() RunService:UnbindFromRenderStep(STEP_NAME) end)
RunService:BindToRenderStep(STEP_NAME, Enum.RenderPriority.Input.Value + 1, function(dt)
	local ok, err = pcall(onStep, dt)
	if not ok and os.clock() - lastErrorWarn > 2 then
		lastErrorWarn = os.clock()
		warn("[AutoWallStick] " .. tostring(err))
	end
end)

local function cleanup()
	running = false
	pcall(function() RunService:UnbindFromRenderStep(STEP_NAME) end)
	for _, c in ipairs(connections) do
		pcall(function() c:Disconnect() end)
	end
	table.clear(connections)
	if _G.AutoWallStickController == controller then _G.AutoWallStickController = nil end
end
controller.Cleanup = cleanup

print("[AutoWallStick] running. Move along a wall to stick to it. Z = on/off.")
end
