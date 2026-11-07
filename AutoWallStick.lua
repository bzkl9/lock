--[[
	AutoWallStick (enhanced)

	Sticks you close to walls while you move along them, and gets you past small things in your way.
	You steer; it shapes the line. Works in shift lock too. Re-running it stops the copy that's running.

	ALONG WALLS
	  * Get within STICK_DETECT_DISTANCE of a wall while moving along it and it pulls you in to
	    DESIRED_WALL_DISTANCE, on the SHORTEST line: it heads straight for the furthest point along the wall
	    it can reach in a straight line (up to BRIDGE_DISTANCE ahead). So it cuts straight across recesses /
	    the dent of an L, and hugs round curves and corners as tightly as it can.
	  * Inside corners: it turns along the wall ahead before you reach it (no stopping). Running straight
	    into a corner it commits to one way out: along the wall you're facing more, away from the corner.
	  * Pushing straight into a wall: it keeps the way it picked (no left/right flicker), and if it has none
	    yet it takes whichever side is open.
	  * Steering away from the wall it eases off, and lets go past LEAVE_DOT.

	SMALL OBSTACLES (only small ones: long things are followed like walls / left to you)
	  * Along a wall: something up to MAX_OBSTACLE_LENGTH long in your lane (a bin, a crate, a post):
	    your line steps out just far enough, just before you reach it, then back in once you're past.
	  * Away from walls: something small right in front of you: it steps you round its nearer end.

	STUCK (holding a key but not moving, on the ground, at normal speed)
	  * Goes the open way that's the smallest turn from where you were heading. Only backs out if there's
	    no other way; still stuck, it jumps.

	SHIFT LOCK: your body faces the camera, so every correction would be a strafe (slower). With
	SHIFTLOCK_TURN_BODY it turns your body by just the script's correction while it steers, so its
	corrections are always straight-ahead running. Your own strafing (A/D) is left as you chose it.

	Only real walls count: steep, at least WALL_HIGH tall (stairs, curbs and short blocks aren't walls),
	and never anything with a Humanoid (players, NPCs, the killer). IGNORE_PATHS folders are ignored
	completely (KillerDoors by default).

	Keys: Z on/off.  F6 debug overlay.  F7 copy the last few seconds of what it did (paste it to me).
	F8 lap timer (start/stop; compare the same route with Z on and off).

	Tweak live: _G.AutoWallStickController.Config.STICK_DETECT_DISTANCE = 5
]]
do
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
if not player then return end

-- Stop any copy (or sibling script) that's already running, including copies that errored and left
-- their steering hooked in, and clear leftover visuals.
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
	for _, name in ipairs({ "AutoWallStick_Visuals", "PathAssist_Visuals", "WallCircler_Visuals", "AutoPath_Visuals",
		"WallCirclerSimple_Visuals" }) do
		local f = workspace:FindFirstChild(name)
		if f then pcall(function() f:Destroy() end) end
	end
	local pg = player:FindFirstChildOfClass("PlayerGui")
	if pg then
		for _, name in ipairs({ "AutoWallStickHUD", "PathAssistHUD", "WallCirclerHUD", "AutoPathHUD", "WallCirclerSimpleHUD" }) do
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
	STICK_DETECT_DISTANCE = 4,     -- walls closer than this (from your center) pull you in
	DESIRED_WALL_DISTANCE = 1.3,   -- your center is kept this far from the wall
	STICK_DOT = 0.18,              -- grabs a wall only if you're not steering away from it more than this (~10 deg)
	BLEND_FROM = 0.1,              -- steering away more than this (~6 deg) it starts easing off...
	LEAVE_DOT = 0.3,               -- ...and lets go past this (~17 deg)
	HEAD_ON_DOT = 0.35,            -- less "along" than this = you're pushing into the wall (keeps its side)
	SIDE_MEMORY = 0.6,             -- seconds a picked side is kept while you push into the wall
	HUG_LOOKAHEAD = 2.5,           -- how sharply it pulls you onto your line when there's no long view
	STEER_SMOOTHING = 0.04,        -- seconds
	GRACE_KEEP_SECONDS = 0.12,     -- keep the last wall this long if it's briefly not seen
	SWITCH_MARGIN = 0.5,           -- another wall must be this much closer to switch to it

	-- inside corners
	CORNER_TURN = true,            -- turn along a wall ahead before you reach it
	CORNER_EARLY = 0.6,            -- the turn starts this much before you're at DESIRED distance from it
	COMMIT_TIME = 5,               -- the way it picked out of a corner is kept (up to this long) until you turn your camera
	COMMIT_TURN = 0.95,            -- "turned your camera" = your direction changed more than ~18 degrees

	-- shortest line along the wall (straight across recesses / the dent of an L, tight round curves)
	BRIDGE = true,
	BRIDGE_DISTANCE = 20,          -- how far ahead along the wall it looks (raise for longer shortcuts)
	BRIDGE_STEP = 2,
	RECESS_DEPTH = 6,              -- how deep a recess/dent it will look into to find the wall beyond it
	BRIDGE_MAX_ANGLE = 40,         -- never aims more than this many degrees in toward the wall

	-- small obstacles
	AVOID = true,                  -- along walls
	FREE_AVOID = true,             -- away from walls (step round small things in front of you)
	MAX_OBSTACLE_LENGTH = 8,       -- along a wall: things shorter than this: step out and back in
	FOLLOW_LONG = true,            -- longer low things (a bench): your line runs along their edge (false = left to you)
	MAX_SIDESTEP = 3.5,            -- away from walls: only things you can get round within this get a sidestep
	LOOKAHEAD_TIME = 0.5,          -- how far ahead (seconds of running) it looks for things in the way
	MIN_LOOKAHEAD = 3,
	MAX_LOOKAHEAD = 9,
	REACT_SLOPE = 1.0,             -- it starts moving out (offset needed x this) + REACT_MARGIN studs before it
	REACT_MARGIN = 1.5,            -- (the last moment that still gets past smoothly)
	MAX_DETOUR = 6,                -- along walls: furthest out it will move your line
	DETOUR_STEP = 0.5,
	BODY_RADIUS = 1.2,             -- body size for "will I hit it" (your body is ~1; a little margin)
	BODY_HEIGHTS = { 2.0, 3.5 },   -- above your feet
	WALL_GAP = 0.3,                -- bumps/trim sticking out of the wall less than this aren't obstacles
	STEP_UP = 1.2,                 -- rises up to this (stairs, curbs) you just walk up: never obstacles

	-- shift lock speed
	SHIFTLOCK_TURN_BODY = true,    -- turn your body by the script's correction so it's straight-ahead running
	MAX_BODY_TURN = 90,            -- degrees, at most

	-- stuck
	STUCK_SPEED = 1.5,             -- holding a move key but moving slower than this...
	STUCK_TIME = 0.25,             -- ...for this long = stuck (only on the ground, at normal speed)
	MIN_WALKSPEED = 4,             -- slower than this (slowed/stunned by the game): never counts as stuck
	ESCAPE_TIME = 0.35,            -- it goes the open way for up to this long...
	ESCAPE_MIN = 0.12,             -- ...but stops after this if the way you wanted is open again
	ESCAPE_CHECK = 2.5,            -- how far a direction must be clear to count as "open"
	ESCAPE_RADIUS = 1.0,           -- body size for those checks (checked from just behind you: you may be touching)
	ESCAPE_CLEAR = 2,
	UNSTICK_DETOUR = 1.0,          -- stuck on something along a wall: the line also moves out this much...
	UNSTICK_HOLD = 1.0,            -- ...and stays out this long (what snagged you is often invisible to checks)
	JUMP_AFTER_TRIES = 2,          -- still stuck after this many tries: jump

	-- what counts as a wall
	RAY_COUNT = 24,
	WALL_LOW = 1.5,                -- heights above your feet where walls are checked
	WALL_HIGH = 2.75,              -- (shorter than this = not a wall: stairs, curbs, short blocks)
	WALL_SLANT = 0.5,              -- both heights must hit within this of each other (stairs don't)
	WALL_MAX_SLOPE = 75,           -- steeper than this (degrees) = wall; anything you can walk up = floor

	-- testing
	DEBUG_KEY = Enum.KeyCode.F6,   -- overlay: what it's doing + arrows (white = your input, colour = its line)
	LOG_KEY = Enum.KeyCode.F7,     -- prints + copies the last LOG_SECONDS of what it did
	LAP_KEY = Enum.KeyCode.F8,     -- lap timer: press to start, again to stop
	LOG_SECONDS = 4,
	-- speed for moving at an angle to where your body faces (your numbers), for the overlay
	TAX = { { 0, 1 }, { 45, 0.975 }, { 90, 0.925 }, { 180, 0.7 } },
}
controller.Config = CONFIG

------------------------------------------------------------------------
-- STATE
------------------------------------------------------------------------
local running, enabled = true, true
local connections = {}
local char, hrp, humanoid
local TWO_PI = 2 * math.pi
local lastWall = nil            -- { point, part, normal, seen }
local attached = false
local smoothDir = nil
local detour, returnTimer, lastAvoidCheck = 0, 0, 0
local holdLaneUntil, wallLockUntil = 0, 0
local side, sideTime = nil, 0   -- which way along the wall (+1/-1 relative to the wall's tangent)
local commit = nil              -- { dir, input, untilT }: the way out of a corner / an escape
local bridgeAim, lastBridge = nil, 0
local freeSide, freeUntil, freeMove = 0, 0, nil
local stuckTime, stuckTries, freeTime = 0, 0, 0
local escapeDir, escapeUntil, escapeStart, escapeGoal, escapeInput, escapeEarlyOk = nil, 0, 0, nil, nil, false
local bodyTurning = false
local dbg = { dist = nil, away = nil }
local stats = { escapes = 0, detours = 0, corners = 0, backward = 0, offLine = 0 }
local pendingEvent = nil

local function event(text)
	pendingEvent = pendingEvent and (pendingEvent .. " | " .. text) or text
end

------------------------------------------------------------------------
-- WHAT RAYS IGNORE: players, anything with a Humanoid, IGNORE_PATHS, our own visuals
------------------------------------------------------------------------
local VIS_NAME = "AutoWallStick_Visuals"
local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
params.IgnoreWater = true
params.RespectCanCollide = true -- walk-through decorations don't count

local ignoredChars = {}         -- [model] = true
local ownerCache = setmetatable({}, { __mode = "k" }) -- part -> character model, or time it was checked

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
		if p.Character then list[#list + 1] = p.Character end
	end
	for _, path in ipairs(CONFIG.IGNORE_PATHS) do
		local inst = findPath(path) -- looked up every refresh: works when the map reloads
		if inst then list[#list + 1] = inst end
	end
	for m in pairs(ignoredChars) do
		if m.Parent then list[#list + 1] = m else ignoredChars[m] = nil end
	end
	local vis = workspace:FindFirstChild(VIS_NAME)
	if vis then list[#list + 1] = vis end
	params.FilterDescendantsInstances = list
end
refreshFilter()

-- the character model (anything with a Humanoid) this part belongs to, if any
local function characterOf(inst)
	local c = ownerCache[inst]
	local now = os.clock()
	if typeof(c) == "Instance" then return c end
	if type(c) == "number" and now - c < 2 then return nil end
	local m = inst:FindFirstAncestorOfClass("Model")
	while m do
		if m:FindFirstChildOfClass("Humanoid") then
			ownerCache[inst] = m
			return m
		end
		m = m:FindFirstAncestorOfClass("Model")
	end
	ownerCache[inst] = now
	return nil
end

local function ignoreCharacter(m)
	if ignoredChars[m] then
		refreshFilter()
		return
	end
	ignoredChars[m] = true
	if not pcall(function() params:AddToFilter(m) end) then refreshFilter() end
end

-- raycast / spherecast that never stops on a character (it adds it to the ignore list and looks again)
local function cast(origin, dir)
	for _ = 1, 4 do
		local hit = workspace:Raycast(origin, dir, params)
		if not hit then return nil end
		local m = characterOf(hit.Instance)
		if not m then return hit end
		ignoreCharacter(m)
	end
	return nil
end

local function sphereCast(origin, radius, dir)
	for _ = 1, 4 do
		local hit = workspace:Spherecast(origin, radius, dir, params)
		if not hit then return nil end
		local m = characterOf(hit.Instance)
		if not m then return hit end
		ignoreCharacter(m)
	end
	return nil
end

------------------------------------------------------------------------
-- HELPERS
------------------------------------------------------------------------
local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function unitFlat(v)
	local f = Vector3.new(v.X, 0, v.Z)
	return f.Magnitude > 1e-3 and f.Unit or Vector3.zero
end

-- rotate a flat vector round the vertical by angle a (radians); signedAngle is its inverse
local function rotateFlat(v, a)
	local c, s = math.cos(a), math.sin(a)
	return Vector3.new(v.X * c - v.Z * s, 0, v.X * s + v.Z * c)
end

local function signedAngle(from, to)
	return math.atan2(from.X * to.Z - from.Z * to.X, from.X * to.X + from.Z * to.Z)
end

local function taxAt(deg)
	local pts = CONFIG.TAX
	for i = 2, #pts do
		if deg <= pts[i][1] then
			local a, b = pts[i - 1], pts[i]
			return a[2] + (b[2] - a[2]) * (deg - a[1]) / (b[1] - a[1])
		end
	end
	return pts[#pts][2]
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
-- Uses the game's control module; the raw keys only if that module never reports anything
-- (so when the game freezes your controls, this doesn't move you anyway).
local controlsWork = false
local function getInput()
	local v = Vector3.zero
	if controls then
		local ok, mv = pcall(controls.GetMoveVector, controls)
		if ok and typeof(mv) == "Vector3" then
			v = mv
			if mv.Magnitude > 0.05 then controlsWork = true end
		end
	end
	if not controlsWork and v.Magnitude < 0.05 and not UserInputService:GetFocusedTextBox() then
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
	local hit = cast(hrp.Position, Vector3.new(0, -12, 0))
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
	local low = cast(Vector3.new(origin.X, feetY + CONFIG.WALL_LOW, origin.Z), dir * range)
	if not isSteep(low) then return nil end
	local d = flat(low.Position - origin).Magnitude
	local high = cast(Vector3.new(origin.X, feetY + CONFIG.WALL_HIGH, origin.Z), dir * (d + CONFIG.WALL_SLANT))
	if not isSteep(high) then return nil end
	return low, d
end

-- the wall you're on: same part (and, right after turning a corner, the same face)
local function onSameWall(hit)
	if not lastWall or hit.Instance ~= lastWall.part then return false end
	if os.clock() >= wallLockUntil then return true end
	local n = unitFlat(hit.Normal)
	return n.Magnitude < 0.5 or lastWall.normal.Magnitude < 0.5 or n:Dot(lastWall.normal) > 0.7
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
			if d < onLastD and onSameWall(hit) then onLast, onLastD = hit, d end
		end
	end
	if not best then return nil end
	for _, f in ipairs({ -0.5, -0.25, 0.25, 0.5 }) do -- refine (accurate at corners)
		local a = bestA + f * step
		local hit, d = wallFrom(center, feetY, Vector3.new(math.sin(a), 0, math.cos(a)), range)
		if hit and d < bestD then best, bestD = hit, d end
	end
	-- stay on the wall you're on unless another is clearly closer (no corridor flip-flop);
	-- while going round something / just after a corner, always stay on it
	if onLast and not onSameWall(best) and (lockToLast or onLastD < bestD + CONFIG.SWITCH_MARGIN) then
		best, bestD = onLast, onLastD
	end
	return best, bestD, onLast ~= nil
end

------------------------------------------------------------------------
-- BODY CHECKS
------------------------------------------------------------------------
-- Is what the body check hit just stairs / a curb you walk up? Walks the ground from `from` to just past
-- the contact: every rise must be a step (<= STEP_UP), nothing taller in between, and the contact must
-- be on that ground (not a beam or a table edge above it).
local function climbableHit(from, feetY, dir, hit)
	local reach = math.max(flat(hit.Position - from):Dot(dir) + 0.3, 0.3)
	local prevY, prevP = feetY, flat(from)
	local s = 0.5
	while true do
		s = math.min(s, reach)
		local p = flat(from) + dir * s
		local testY = prevY + CONFIG.STEP_UP + 0.05
		local a = Vector3.new(prevP.X, testY, prevP.Z)
		local b = Vector3.new(p.X, testY, p.Z)
		if cast(a, b - a) then return false end -- something taller than a step
		local g = cast(b, Vector3.new(0, -(CONFIG.STEP_UP + 3), 0))
		if not g then return false end -- a drop / hole: not "just steps"
		prevY, prevP = g.Position.Y, p
		if s >= reach then break end
		s += 0.5
	end
	return hit.Position.Y <= prevY + 0.5
end

-- How far your body can go from `from` along `delta` before hitting something (nil = all clear).
-- Knee + waist height; things you can walk on (floor, ramps, stairs, curbs) don't count.
local function bodyCast(from, feetY, delta, radius)
	if delta.Magnitude < 0.05 then return nil end
	radius = radius or CONFIG.BODY_RADIUS
	local dir = flat(delta)
	dir = dir.Magnitude > 1e-3 and dir.Unit or nil
	local best = nil
	for _, h in ipairs(CONFIG.BODY_HEIGHTS) do
		local hit = sphereCast(Vector3.new(from.X, feetY + h, from.Z), radius, delta)
		if hit and isSteep(hit) and (not best or hit.Distance < best)
			and not (dir and climbableHit(from, feetY, dir, hit)) then
			best = hit.Distance
		end
	end
	return best
end

-- body size for checks along a lane this far from the wall: never closer than WALL_GAP to the wall,
-- so trim / seams / tiny bumps on the wall itself don't count as things in your way
local function laneRadius(wallDist)
	return math.clamp(wallDist - CONFIG.WALL_GAP, 0.8, CONFIG.BODY_RADIUS)
end

-- Is direction d open for `len`? Checked from just behind you with your real size, so whatever you're
-- pressed against still counts (a check starting inside it wouldn't see it).
local function isOpen(center, feetY, d, len)
	return not bodyCast(center - d * 0.2, feetY, d * (len + 0.2), CONFIG.ESCAPE_RADIUS)
end

-- Lane k = DESIRED + k from the wall. Clear for `length` ahead, and can you get onto it?
local function laneClear(center, feetY, tangent, rhat, dist, k, length)
	local laneDist = CONFIG.DESIRED_WALL_DISTANCE + k
	local shift = laneDist - dist
	if math.abs(shift) > 0.2 and bodyCast(center, feetY, rhat * shift, laneRadius(math.min(dist, laneDist))) then
		return false
	end
	return bodyCast(center + rhat * shift, feetY, tangent * length, laneRadius(laneDist)) == nil
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
local function obstacleLength(center, feetY, tangent, rhat, dist, hitAt)
	local far = hitAt + CONFIG.MAX_OBSTACLE_LENGTH + 1
	local lane0 = center + rhat * (CONFIG.DESIRED_WALL_DISTANCE - dist)
	local back = bodyCast(lane0 + tangent * far, feetY, -tangent * (far - hitAt + 0.5),
		laneRadius(CONFIG.DESIRED_WALL_DISTANCE))
	if not back then return nil end
	local len = (far - back) - hitAt
	if len > CONFIG.MAX_OBSTACLE_LENGTH then return nil end
	return math.max(len, 0)
end

-- Shortest line along the wall: probe the wall at points ahead on your line and head for the FURTHEST
-- one (at your lane distance from the wall there) you can reach in a straight line.
local function bridgeAimPoint(center, feetY, tangent, rhat, dist, laneDist)
	local maxIn = math.tan(math.rad(CONFIG.BRIDGE_MAX_ANGLE))
	local radius = laneRadius(math.min(dist, laneDist))
	local s = CONFIG.BRIDGE_DISTANCE
	while s >= CONFIG.BRIDGE_STEP do
		local q = center + tangent * s
		local hit = wallFrom(q, feetY, -rhat, dist + CONFIG.RECESS_DEPTH)
		if hit then
			local n = unitFlat(hit.Normal)
			if n.Magnitude < 0.5 then n = rhat end
			if n:Dot(rhat) > 0.5 then -- a face looking back at you, i.e. the same side of the wall
				local p = Vector3.new(hit.Position.X, center.Y, hit.Position.Z) + n * laneDist
				local rel = flat(p - center)
				local inward = -rel:Dot(rhat)
				local fwd = rel:Dot(tangent)
				if fwd > 0.5 and inward <= fwd * maxIn and not bodyCast(center, feetY, rel, radius) then
					return p
				end
			end
		end
		s -= CONFIG.BRIDGE_STEP
	end
	return nil
end

------------------------------------------------------------------------
-- SIDES, CORNERS, STUCK
------------------------------------------------------------------------
local function releaseWall()
	detour, returnTimer, bridgeAim, commit = 0, 0, nil, nil
end

-- Which way along the wall (+1/-1 along tangent0)
local function pickSide(center, feetY, tangent0, along0, move, now)
	-- committed (way out of a corner / an escape): keep it until you turn your camera
	if commit then
		if now < commit.untilT and move:Dot(commit.input) > CONFIG.COMMIT_TURN then
			local d = tangent0:Dot(commit.dir)
			if math.abs(d) > 0.3 then
				side, sideTime = (d > 0) and 1 or -1, now
				return side
			end
		else
			commit = nil
		end
	end
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
	local plusOpen = isOpen(center, feetY, tangent0, CONFIG.ESCAPE_CHECK)
	local minusOpen = isOpen(center, feetY, -tangent0, CONFIG.ESCAPE_CHECK)
	if plusOpen ~= minusOpen then
		side = plusOpen and 1 or -1
	else
		side = (along0 >= 0) and 1 or -1
	end
	sideTime = now
	return side
end

-- Stuck: go the open way that's the smallest turn from `goal` (where you were heading).
-- `out` = away from the wall you're on (nil away from walls): never into it; straight back only if boxed in.
local function startEscape(center, feetY, goal, out, move, now, why)
	stuckTries += 1
	local cands = {}
	local function add(d)
		d = flat(d)
		if d.Magnitude > 1e-3 then cands[#cands + 1] = d.Unit end
	end
	for deg = 30, 150, 30 do
		add(rotateFlat(goal, math.rad(deg)))
		add(rotateFlat(goal, -math.rad(deg)))
	end
	-- along every wall right next to you (in a corner the way out is along one of them)
	for i = 0, 7 do
		local a = i * TWO_PI / 8
		local hit = wallFrom(center, feetY, Vector3.new(math.sin(a), 0, math.cos(a)), 2.5)
		if hit then
			local n = unitFlat(hit.Normal)
			if n.Magnitude > 0.5 then
				local t = Vector3.new(-n.Z, 0, n.X)
				add(t); add(-t); add(t + n * 0.35); add(-t + n * 0.35)
			end
		end
	end
	local function score(d) return d:Dot(goal) + 0.3 * d:Dot(move) end
	table.sort(cands, function(a, b) return score(a) > score(b) end)
	local chosen = nil
	for _, d in ipairs(cands) do
		if (not out or d:Dot(out) > -0.05) and isOpen(center, feetY, d, CONFIG.ESCAPE_CHECK) then
			chosen = d
			break
		end
	end
	if not chosen then
		chosen = out or -goal -- boxed in: back out
		humanoid.Jump = true
		why = why .. ", boxed in"
	end
	escapeEarlyOk = stuckTries == 1
	if stuckTries >= CONFIG.JUMP_AFTER_TRIES then
		humanoid.Jump = true
		stuckTries = 0
		why = why .. ", jump"
	end
	escapeDir, escapeGoal, escapeInput = chosen, goal, move
	escapeStart, escapeUntil = now, now + CONFIG.ESCAPE_TIME
	stats.escapes += 1
	event(string.format("ESCAPE (%s) -> %d deg off your input", why,
		math.floor(math.deg(math.acos(math.clamp(chosen:Dot(move), -1, 1))) + 0.5)))
end

-- returns stuck?, speed. Only counts on the ground, running, at normal speed (not climbing, not
-- slowed/stunned/anchored by the game), and relative to how hard you're pushing the stick.
local MOVING_STATES = {
	[Enum.HumanoidStateType.Running] = true,
	[Enum.HumanoidStateType.RunningNoPhysics] = true,
}
local function updateStuck(dt, mag)
	local speed = flat(hrp.AssemblyLinearVelocity).Magnitude
	local canStick = not hrp.Anchored and humanoid.WalkSpeed >= CONFIG.MIN_WALKSPEED
		and humanoid.FloorMaterial ~= Enum.Material.Air and MOVING_STATES[humanoid:GetState()] == true
	if not canStick then
		stuckTime = 0
		return false, speed
	end
	local limit = math.min(CONFIG.STUCK_SPEED, 0.3 * humanoid.WalkSpeed * mag)
	if speed < limit then
		stuckTime += dt
		freeTime = 0
		if stuckTime >= CONFIG.STUCK_TIME then
			stuckTime = 0
			return true, speed
		end
	else
		stuckTime = 0
		freeTime += dt
		if freeTime > 0.5 then stuckTries = 0 end
	end
	return false, speed
end

------------------------------------------------------------------------
-- AWAY FROM WALLS: step round small things in front of you
------------------------------------------------------------------------
local function freeMode(center, feetY, move, mag, dt, now)
	local stuck, speed = updateStuck(dt, mag)
	if stuck then
		startEscape(center, feetY, move, nil, move, now, string.format("stuck, no wall, speed %.1f", speed))
		return "escape", move, escapeDir, mag
	end
	if not CONFIG.FREE_AVOID then return "free", move, nil, mag end

	local perp = Vector3.new(-move.Z, 0, move.X)
	local look = math.clamp(humanoid.WalkSpeed * mag * CONFIG.LOOKAHEAD_TIME, CONFIG.MIN_LOOKAHEAD, CONFIG.MAX_LOOKAHEAD)
	if freeSide ~= 0 then
		-- keep stepping round it until the way ahead is clear (or you change direction)
		if now > freeUntil or move:Dot(freeMove) < 0.9 or not bodyCast(center, feetY, move * math.min(look, 3)) then
			freeSide = 0
			return "free", move, nil, mag
		end
		return "sidestep", move, move + perp * freeSide, mag
	end
	local hitAt = bodyCast(center, feetY, move * look)
	if not hitAt then return "free", move, nil, mag end
	-- small enough to get round? smallest sidestep on either side
	local o = CONFIG.DETOUR_STEP
	while o <= CONFIG.MAX_SIDESTEP + 1e-6 do
		for _, s in ipairs({ 1, -1 }) do
			local start = center + perp * (s * o)
			if not bodyCast(center, feetY, perp * (s * o)) and not bodyCast(start, feetY, move * (hitAt + 2)) then
				if hitAt <= o * CONFIG.REACT_SLOPE + CONFIG.REACT_MARGIN then
					freeSide, freeUntil, freeMove = s, now + 1.5, move
					event(string.format("SIDESTEP %.1f round something %.1f ahead", o, hitAt))
					return "sidestep", move, move + perp * s, mag
				end
				return "free", move, nil, mag -- not yet: wait until the last moment
			end
		end
		o += CONFIG.DETOUR_STEP
	end
	return "free", move, nil, mag -- too big to step round: that's yours to handle
end

------------------------------------------------------------------------
-- DECIDE: returns mode, your input, the direction to go (nil = leave it to you), strength
------------------------------------------------------------------------
local function decide(dt, now)
	dbg.dist, dbg.away = nil, nil
	local move, mag = getInput()
	if not move then
		if attached then releaseWall() end
		attached = false
		freeSide, stuckTime, stuckTries, escapeUntil = 0, 0, 0, 0
		return "idle", nil, nil, 0
	end
	local center = hrp.Position
	local feetY = getFeetY()

	-- escaping: keep going the open way (unless you turned, or the way you wanted is open again)
	if now < escapeUntil and escapeDir then
		if move:Dot(escapeInput) < 0.8 then
			escapeUntil = 0
			event("escape cancelled (you turned)")
		elseif escapeEarlyOk and now - escapeStart >= CONFIG.ESCAPE_MIN
			and isOpen(center, feetY, escapeGoal, CONFIG.ESCAPE_CLEAR) then
			escapeUntil = 0
		else
			stuckTime = 0
			return "escape", move, escapeDir, mag
		end
	end

	-- the wall you're on
	local prevPart = lastWall and lastWall.part
	local hit, dist, sawLast = findWall(center, feetY, detour, detour > 0 or now < wallLockUntil)
	if hit then
		lastWall = { point = hit.Position, part = hit.Instance, normal = unitFlat(hit.Normal), seen = now }
		if detour > 0 and not sawLast and hit.Instance ~= prevPart then
			-- the wall you were on is hidden behind what you're going round: that's your wall now
			detour, returnTimer, holdLaneUntil = 0, 0, 0
			event("following what you were going round as the wall")
		end
	elseif lastWall and now - lastWall.seen < CONFIG.GRACE_KEEP_SECONDS then
		dist = flat(center - lastWall.point).Magnitude
	else
		lastWall = nil
	end
	local rhat, away = nil, 0
	if lastWall and dist <= CONFIG.STICK_DETECT_DISTANCE + detour then
		local r = flat(center - lastWall.point)
		if r.Magnitude > 1e-3 then
			rhat = r.Unit -- from the wall toward you
			away = move:Dot(rhat)
		end
	end
	if not rhat or away > (attached and CONFIG.LEAVE_DOT or CONFIG.STICK_DOT) then
		if attached then
			releaseWall()
			attached = false
			event("let go of the wall")
		end
		return freeMode(center, feetY, move, mag, dt, now)
	end
	if not attached then
		attached = true
		event(string.format("on a wall %.1f away", dist))
	end
	freeSide = 0

	local tangent0 = Vector3.new(-rhat.Z, 0, rhat.X)
	local along0 = move:Dot(tangent0)
	local tangent = tangent0 * pickSide(center, feetY, tangent0, along0, move, now)
	local laneDist = CONFIG.DESIRED_WALL_DISTANCE + detour

	-- INSIDE CORNER: a real wall straight ahead -> turn before you reach it. Out of the corner either
	-- along the wall ahead (away from this one) or back along this one (away from that one): whichever is
	-- the smaller turn from where you're heading.
	if CONFIG.CORNER_TURN and detour == 0 then
		local front, fd = wallFrom(center, feetY, tangent, laneDist + CONFIG.CORNER_EARLY + 0.3)
		local n = front and unitFlat(front.Normal)
		if front and fd <= laneDist + CONFIG.CORNER_EARLY and n.Magnitude > 0.5 and n:Dot(tangent) < -0.5 then
			local ahead = Vector3.new(-n.Z, 0, n.X)
			if ahead:Dot(rhat) < 0 then ahead = -ahead end
			local back = -tangent
			if back:Dot(move) > ahead:Dot(move) + 0.05 and isOpen(center, feetY, back, CONFIG.ESCAPE_CHECK) then
				tangent = back
				side, sideTime = -(side or 1), now
				commit = { dir = back, input = move, untilT = now + CONFIG.COMMIT_TIME, corner = true }
				event("CORNER: back along this wall (you're facing it more)")
			else
				lastWall = { point = front.Position, part = front.Instance, normal = n, seen = now }
				wallLockUntil = now + 0.5
				rhat, dist = n, fd
				tangent0 = Vector3.new(-rhat.Z, 0, rhat.X)
				side, sideTime = (tangent0:Dot(ahead) > 0) and 1 or -1, now
				tangent = ahead
				commit = { dir = ahead, input = move, untilT = now + CONFIG.COMMIT_TIME, corner = true }
				event("CORNER: along the wall ahead")
			end
			away = move:Dot(rhat)
			stats.corners += 1
		end
	end
	dbg.dist, dbg.away = dist, away

	-- STUCK? go the open way that's the smallest turn
	local stuck, speed = updateStuck(dt, mag)
	if stuck then
		startEscape(center, feetY, tangent, rhat, move, now, string.format("stuck on a wall, speed %.1f", speed))
		commit = { dir = escapeDir, input = move, untilT = now + CONFIG.COMMIT_TIME }
		if escapeDir:Dot(tangent) > 0.3 then -- still going the same way along it: move the line out a bit
			detour = math.min(detour + CONFIG.UNSTICK_DETOUR, CONFIG.MAX_DETOUR)
			holdLaneUntil = now + CONFIG.ESCAPE_TIME + CONFIG.UNSTICK_HOLD
		end
		return "escape", move, escapeDir, mag
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
				local lane0 = center + rhat * (CONFIG.DESIRED_WALL_DISTANCE - dist)
				local hitAt = bodyCast(lane0, feetY, tangent * look, laneRadius(CONFIG.DESIRED_WALL_DISTANCE))
				local len = hitAt and obstacleLength(center, feetY, tangent, rhat, dist, hitAt)
				if hitAt and (len or CONFIG.FOLLOW_LONG) and hitAt <= k * CONFIG.REACT_SLOPE + CONFIG.REACT_MARGIN then
					detour, returnTimer = k, 0
					stats.detours += 1
					event(string.format("DETOUR out %.1f for a %s thing %.1f ahead", k,
						len and string.format("%.1f-long", len) or "long", hitAt))
				end
			end
		elseif k < detour and now >= holdLaneUntil then
			returnTimer += 0.05
			if returnTimer >= 0.12 then
				detour, returnTimer = k, 0 -- the way back in has been clear for a moment
				if k == 0 then event("back in") end
			end
		else
			returnTimer = 0
		end
		laneDist = CONFIG.DESIRED_WALL_DISTANCE + detour
	end

	-- the line: the furthest point along the wall you can reach straight (shortest), else a tight hug
	if CONFIG.BRIDGE and now - lastBridge >= 0.05 then
		lastBridge = now
		bridgeAim = bridgeAimPoint(center, feetY, tangent, rhat, dist, laneDist)
	end
	local dir, mode
	local offset = laneDist - dist
	if detour > 0 and offset > 0.2 then
		-- stepping out round something: at least 45 degrees out, so you're clear in time
		dir, mode = tangent * math.clamp(offset, 0.6, CONFIG.HUG_LOOKAHEAD) + rhat * offset, "detour"
	elseif bridgeAim and flat(bridgeAim - center):Dot(tangent) > 1 then
		dir, mode = flat(bridgeAim - center), "bridge"
	else
		dir, mode = tangent * CONFIG.HUG_LOOKAHEAD + rhat * offset, "hug"
		if offset < -0.05 and bodyCast(center, feetY, dir, laneRadius(laneDist)) then
			dir = tangent * (CONFIG.HUG_LOOKAHEAD * 3) + rhat * offset -- ease in: the sharp line would clip something
		end
	end
	if detour > 0 then
		mode = "detour"
	elseif commit and commit.corner then
		mode = "corner"
	end
	-- steering away from the wall: hand control back to you gradually
	if away > CONFIG.BLEND_FROM and dir.Magnitude > 1e-3 then
		local w = math.clamp((away - CONFIG.BLEND_FROM) / (CONFIG.LEAVE_DOT - CONFIG.BLEND_FROM), 0, 1)
		dir = dir.Unit * (1 - w) + move * w
	end
	return mode, move, dir, mag
end

------------------------------------------------------------------------
-- STEERING + SHIFT LOCK BODY TURN
------------------------------------------------------------------------
local function steer(dir, mag, dt)
	dir = flat(dir).Unit
	if smoothDir then
		local b = smoothDir:Lerp(dir, 1 - math.exp(-dt / CONFIG.STEER_SMOOTHING))
		if b.Magnitude > 1e-3 then dir = b.Unit end
	end
	smoothDir = dir
	humanoid:Move(dir * mag, false)
	return dir
end

-- Shift lock: your body faces the camera, so a correction would be a strafe. Turn the body by exactly
-- the script's correction, so your input keeps the same angle to your body (W stays straight-ahead).
local function turnBody(applied, move, shiftLocked)
	local want = nil
	if CONFIG.SHIFTLOCK_TURN_BODY and shiftLocked and applied and move then
		local cam = workspace.CurrentCamera
		local look = cam and flat(cam.CFrame.LookVector)
		if look and look.Magnitude > 1e-3 then
			local delta = signedAngle(move, applied)
			if math.abs(delta) > math.rad(bodyTurning and 1 or 3) then
				local maxT = math.rad(CONFIG.MAX_BODY_TURN)
				want = rotateFlat(look.Unit, math.clamp(delta, -maxT, maxT))
			end
		end
	end
	if want then
		if not bodyTurning then
			if not humanoid.AutoRotate then return end -- the game has turning switched off: leave it alone
			bodyTurning = true
			humanoid.AutoRotate = false
		end
		local p = hrp.Position
		hrp.CFrame = CFrame.lookAt(p, p + want)
	elseif bodyTurning then
		bodyTurning = false
		humanoid.AutoRotate = true
	end
end

------------------------------------------------------------------------
-- DEBUG OVERLAY, LOG, LAP TIMER
------------------------------------------------------------------------
local LOG_MAX = 400
local logBuf, logN = {}, 0
local lastBackward = false
local hudGui, hudLabel, lastHud = nil, nil, 0
local visFolder, visInput, visSteer, visWall, visAim = nil, nil, nil, nil, nil
local lap, laps = nil, {}
local lastFrame = { mode = "idle", dev = 0, speed = 0, tax = 1 }

local MODE_COLORS = {
	hug = Color3.fromRGB(0, 200, 255), bridge = Color3.fromRGB(0, 255, 120), detour = Color3.fromRGB(255, 170, 0),
	escape = Color3.fromRGB(255, 60, 60), sidestep = Color3.fromRGB(255, 120, 255),
}

local function visPart(color, size, shape)
	local p = Instance.new("Part")
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
	p.Material = Enum.Material.Neon
	p.Color = color
	if shape then p.Shape = shape end
	p.Size = size
	p.Parent = visFolder
	return p
end

local function setDebug(on)
	if on and not hudGui then
		local pg = player:FindFirstChildOfClass("PlayerGui")
		if pg then
			hudGui = Instance.new("ScreenGui")
			hudGui.Name = "AutoWallStickHUD"
			hudGui.ResetOnSpawn = false
			hudGui.DisplayOrder = 50
			hudLabel = Instance.new("TextLabel")
			hudLabel.Size = UDim2.fromOffset(470, 150)
			hudLabel.Position = UDim2.new(0, 10, 1, -260)
			hudLabel.BackgroundColor3 = Color3.new(0, 0, 0)
			hudLabel.BackgroundTransparency = 0.35
			hudLabel.TextColor3 = Color3.new(1, 1, 1)
			hudLabel.Font = Enum.Font.Code
			hudLabel.TextSize = 14
			hudLabel.TextXAlignment = Enum.TextXAlignment.Left
			hudLabel.TextYAlignment = Enum.TextYAlignment.Top
			local pad = Instance.new("UIPadding")
			pad.PaddingLeft, pad.PaddingTop = UDim.new(0, 6), UDim.new(0, 4)
			pad.Parent = hudLabel
			hudLabel.Parent = hudGui
			hudGui.Parent = pg
		end
		visFolder = Instance.new("Folder")
		visFolder.Name = VIS_NAME
		visFolder.Parent = workspace
		visInput = visPart(Color3.new(1, 1, 1), Vector3.new(0.1, 0.1, 4))
		visSteer = visPart(MODE_COLORS.hug, Vector3.new(0.18, 0.18, 4))
		visWall = visPart(Color3.fromRGB(255, 220, 0), Vector3.new(0.5, 0.5, 0.5), Enum.PartType.Ball)
		visAim = visPart(MODE_COLORS.bridge, Vector3.new(0.7, 0.7, 0.7), Enum.PartType.Ball)
		refreshFilter()
	elseif not on and hudGui then
		pcall(function() hudGui:Destroy() end)
		pcall(function() visFolder:Destroy() end)
		hudGui, hudLabel, visFolder = nil, nil, nil
	end
end

local HIDE = CFrame.new(0, -10000, 0)
local function arrow(part, from, dir, len)
	if not dir then
		part.CFrame = HIDE
		return
	end
	part.CFrame = CFrame.lookAt(from + dir * (len / 2), from + dir * len)
end

local function record(now, dt, mode, move, applied)
	local vel = flat(hrp.AssemblyLinearVelocity)
	local speed = vel.Magnitude
	local dev = 0
	if move and applied then
		local d = math.clamp(applied:Dot(move), -1, 1)
		dev = math.deg(math.acos(d))
		stats.offLine += speed * dt * (1 - d)
		local backward = d < -0.05 and mode ~= "corner" -- (out of a corner you're facing is meant to turn you round)
		if backward then
			stats.backward += 1
			if not lastBackward then event("BACKWARD (" .. mode .. ")") end
		end
		lastBackward = backward
	else
		lastBackward = false
	end
	local tax = 1
	if speed > 1 then
		local facing = flat(hrp.CFrame.LookVector)
		if facing.Magnitude > 1e-3 then
			tax = taxAt(math.deg(math.acos(math.clamp(vel.Unit:Dot(facing.Unit), -1, 1))))
		end
	end
	logN = logN % LOG_MAX + 1
	local e = logBuf[logN] or {}
	logBuf[logN] = e
	e.t, e.mode, e.dev, e.speed, e.dist, e.away, e.detour, e.tax, e.event =
		now, mode, dev, speed, dbg.dist, dbg.away, detour, tax, pendingEvent
	pendingEvent = nil
	lastFrame = e

	if visFolder then
		local base = hrp.Position - Vector3.new(0, 1.5, 0)
		arrow(visInput, base, move, 4)
		arrow(visSteer, base + Vector3.new(0, 0.15, 0), applied, 5)
		visSteer.Color = MODE_COLORS[mode] or Color3.fromRGB(200, 200, 200)
		visWall.CFrame = (attached and lastWall) and CFrame.new(lastWall.point) or HIDE
		visAim.CFrame = (attached and bridgeAim and mode == "bridge") and CFrame.new(bridgeAim) or HIDE
	end
end

local function fmt(v, f)
	return v and string.format(f, v) or "   -  "
end

local function hudText(now)
	local f = lastFrame
	local lines = {
		string.format("AutoWallStick %s  shift lock %s   F6 hide  F7 copy log  F8 lap",
			enabled and "ON" or "OFF", isShiftLocked() and "yes" or "no"),
		string.format("mode %-8s wall %s  away %s  detour %.1f", f.mode, fmt(f.dist, "%.2f"), fmt(f.away, "%+.2f"), detour),
		string.format("speed %4.1f  steered %3d deg off your input   speed vs facing x%.3f",
			f.speed, math.floor(f.dev + 0.5), f.tax),
		string.format("escapes %d  detours %d  corners %d  backward frames %d  off your line %.1f studs",
			stats.escapes, stats.detours, stats.corners, stats.backward, stats.offLine),
	}
	if lap then
		lines[#lines + 1] = string.format("lap %.2fs  %.1f studs  (running, F8 to stop)", now - lap.start, lap.dist)
	end
	if #laps > 0 then
		local parts = {}
		for i = 1, math.min(#laps, 4) do
			parts[i] = string.format("%.2fs %.0f %s", laps[i].t, laps[i].d, laps[i].tag)
		end
		lines[#lines + 1] = "laps: " .. table.concat(parts, " | ")
	end
	return table.concat(lines, "\n")
end

local function dumpLog()
	local now = os.clock()
	local out = {
		string.format("[AutoWallStick log] last %ds, t = seconds before F7. wall = distance to wall, away = + steering away from it,"
			.. " dev = degrees it steered you off your input, x = speed vs facing", CONFIG.LOG_SECONDS),
		string.format("settings: DESIRED %.2f  DETECT %.2f  WALL_LOW %.2f  WALL_HIGH %.2f  shiftlock %s  turnbody %s",
			CONFIG.DESIRED_WALL_DISTANCE, CONFIG.STICK_DETECT_DISTANCE, CONFIG.WALL_LOW, CONFIG.WALL_HIGH,
			tostring(isShiftLocked()), tostring(CONFIG.SHIFTLOCK_TURN_BODY)),
	}
	local prevMode, count = nil, 0
	for i = 1, LOG_MAX do
		local e = logBuf[(logN + i - 1) % LOG_MAX + 1]
		if e and e.t and now - e.t <= CONFIG.LOG_SECONDS then
			count += 1
			if e.event or e.mode ~= prevMode or e.dev > 20 or count % 6 == 0 then
				out[#out + 1] = string.format("%6.2f %-8s spd %4.1f dev %3d x%.3f wall %s away %s det %.1f%s",
					e.t - now, e.mode, e.speed, math.floor(e.dev + 0.5), e.tax, fmt(e.dist, "%.2f"),
					fmt(e.away, "%+.2f"), e.detour, e.event and ("  << " .. e.event) or "")
			end
			prevMode = e.mode
		end
	end
	out[#out + 1] = string.format("totals: escapes %d, detours %d, corners %d, backward frames %d, off your line %.1f studs",
		stats.escapes, stats.detours, stats.corners, stats.backward, stats.offLine)
	local text = table.concat(out, "\n")
	print(text)
	local clip = setclipboard or toclipboard
	if type(clip) == "function" and pcall(clip, text) then
		print("[AutoWallStick] log copied to clipboard")
	else
		print("[AutoWallStick] couldn't copy: open the console (F9) and copy it from there")
	end
end

local function toggleLap()
	local now = os.clock()
	if lap then
		local tag = lap.mixed and "MIXED" or (lap.on and "ON" or "OFF")
		table.insert(laps, 1, { t = now - lap.start, d = lap.dist, tag = tag })
		if #laps > 8 then table.remove(laps) end
		print(string.format("[AutoWallStick] lap %.2fs  %.1f studs  script %s", now - lap.start, lap.dist, tag))
		lap = nil
	elseif hrp then
		lap = { start = now, dist = 0, lastPos = hrp.Position, on = enabled, mixed = false }
		setDebug(true)
	end
end

------------------------------------------------------------------------
-- MAIN
------------------------------------------------------------------------
local function onStep(dt)
	if not running then return end
	if not (char and hrp and humanoid and hrp.Parent) or humanoid.Health <= 0 then return end
	local now = os.clock()
	if now - lastFilterRefresh > 1 then
		lastFilterRefresh = now
		refreshFilter()
	end
	if lap then
		local p = hrp.Position
		lap.dist += flat(p - lap.lastPos).Magnitude
		lap.lastPos = p
		if enabled ~= lap.on then lap.mixed = true end
	end

	local shiftLocked = isShiftLocked()
	local mode, move, dir, mag = "off", nil, nil, 0
	if enabled and not (CONFIG.SHIFTLOCK_DISABLES and shiftLocked) then
		mode, move, dir, mag = decide(dt, now)
	else
		if attached then releaseWall() end
		attached, lastWall = false, nil
		move = getInput()
	end

	local applied = nil
	if dir and flat(dir).Magnitude > 1e-3 then
		applied = steer(dir, mag, dt)
	else
		smoothDir = move -- you're steering yourself: the next correction starts from your direction
	end
	turnBody(applied, move, shiftLocked)
	record(now, dt, mode, move, applied)

	if hudLabel and now - lastHud > 0.1 then
		lastHud = now
		hudLabel.Text = hudText(now)
	end
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------
local function onCharacterAdded(c)
	char = c
	humanoid = c:WaitForChild("Humanoid", 5)
	hrp = c:WaitForChild("HumanoidRootPart", 5)
	lastWall, attached, smoothDir, bodyTurning = nil, false, nil, false
	releaseWall()
	refreshFilter()
end
if player.Character then task.spawn(onCharacterAdded, player.Character) end
connections[#connections + 1] = player.CharacterAdded:Connect(onCharacterAdded)

connections[#connections + 1] = UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or not running then return end
	if input.KeyCode == CONFIG.TOGGLE_KEY then
		enabled = not enabled
		lastWall, attached = nil, false
		releaseWall()
		if bodyTurning and humanoid then
			bodyTurning = false
			humanoid.AutoRotate = true
		end
		print("[AutoWallStick] " .. (enabled and "on" or "off"))
	elseif input.KeyCode == CONFIG.DEBUG_KEY then
		setDebug(hudGui == nil)
	elseif input.KeyCode == CONFIG.LOG_KEY then
		event("MARK (you pressed F7)")
		dumpLog()
	elseif input.KeyCode == CONFIG.LAP_KEY then
		toggleLap()
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
	if bodyTurning and humanoid then
		pcall(function() humanoid.AutoRotate = true end)
		bodyTurning = false
	end
	setDebug(false)
	if _G.AutoWallStickController == controller then _G.AutoWallStickController = nil end
end
controller.Cleanup = cleanup
controller.Stats = stats
controller.DumpLog = dumpLog

print("[AutoWallStick] running. Z = on/off, F6 = debug overlay, F7 = copy log, F8 = lap timer.")
end
