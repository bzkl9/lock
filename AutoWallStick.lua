--[[
	AutoWallStick (enhanced)

	Just sticks you close to walls while you move along them. You steer, it keeps you DESIRED_DISTANCE
	from the wall.

	  * Move along a wall (or into it at an angle): you slide along it at DESIRED_DISTANCE.
	  * Outside corners: it wraps you tightly round the edge; once you're past it and still steering
	    straight on, it lets go (turn toward the new face to keep following it).
	    Inside corners: you slide onto the new wall in whichever direction you're steering along it
	    (steering straight into the corner just stops you there).
	  * Something in the way along the wall (a bin, a crate, a pillar): it moves your line out just far
	    enough to get past it, then back in to the wall once you're past. It looks LOOKAHEAD_TIME ahead,
	    picks the smallest offset (DETOUR_STEP steps, up to MAX_DETOUR) whose line is clear for your body,
	    and keeps following the same wall while it does. Short things count too (anything taller than you
	    can step over). No route planning, just the line ahead of you.
	  * Steer away from the wall (more than LEAVE_DOT) and it lets you go.
	  * Works in shift lock too (set SHIFTLOCK_DISABLES = true if you want shift lock to turn it off).
	  * Z: on/off.

	What changed from the original
	  * Steers through your normal movement instead of teleporting the HumanoidRootPart every frame
	    (no stutter, no clipping into walls, physics and animations stay normal).
	  * Finds the closest point of the nearest wall all around you, not just left/right of where your
	    character faces, so it sees corners and walls in front of you.
	  * Only real walls count: steep (anything you can walk up is floor), tall (checked at two heights, so
	    stairs, curbs and short blocks are ignored) and not a character.
	  * Doesn't flip between two walls in a corridor (keeps the one it's on unless another is clearly closer).
	  * Reuses one set of raycast settings instead of making new ones every ray.
	  * IGNORE_PATHS: folders whose parts are ignored completely (KillerDoors by default).

	Tweak live: _G.AutoWallStickController.Config.DESIRED_WALL_DISTANCE = 1.3
]]
do
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
if not player then return end

for _, key in ipairs({ "AutoWallStickController", "WallCirclerSimpleController", "WallCirclerController",
	"AutoPathController", "PathAssistController" }) do
	local old = _G[key]
	if type(old) == "table" and type(old.Cleanup) == "function" then
		pcall(old.Cleanup)
	end
	_G[key] = nil
end

local controller = {}
_G.AutoWallStickController = controller

------------------------------------------------------------------------
-- CONFIG
------------------------------------------------------------------------
local CONFIG = {
	TOGGLE_KEY = Enum.KeyCode.Z,
	SHIFTLOCK_DISABLES = false,

	-- folders (paths from Workspace) whose parts are completely ignored: never stuck to, never avoided
	IGNORE_PATHS = {
		{ "Map", "Ingame", "Map", "MapBoundaries", "KillerDoors" },
	},    -- true = no sticking while shift lock is on

	STICK_DETECT_DISTANCE = 3.5,   -- walls closer than this (from your center) can be stuck to
	DESIRED_WALL_DISTANCE = 1.5,   -- your center is kept this far from the wall
	LEAVE_DOT = 0.3,               -- steering away from the wall more than this (~17 degrees) lets go
	MIN_ALONG = 0.15,              -- you must be moving at least a little along the wall (or into it)
	DISTANCE_GAIN = 1.2,           -- how hard it pulls/pushes you to DESIRED_WALL_DISTANCE
	MAX_CORRECTION = 1.0,
	STEER_SMOOTHING = 0.04,        -- seconds
	GRACE_KEEP_SECONDS = 0.12,     -- keep the last wall this long if it's briefly not seen
	SWITCH_MARGIN = 0.5,           -- another wall must be this much closer to switch to it

	-- getting past things along the wall
	AVOID = true,
	LOOKAHEAD_TIME = 0.6,          -- seconds of running ahead that are checked
	MIN_LOOKAHEAD = 4,             -- studs, at least
	MAX_DETOUR = 8,                -- the furthest out from the wall it will move your line
	DETOUR_STEP = 0.5,
	BODY_RADIUS = 1.2,             -- body size for "will I hit it" (your body is ~1; a little margin)
	HUG_LOOKAHEAD = 2.5,           -- how sharply it pulls you back in to the wall (shorter = tighter)
	BODY_HEIGHTS = { 2.0, 3.5 },   -- above your feet: things lower than ~1 stud you just step over
	RETURN_DELAY = 0.12,           -- the way back to the wall must be clear this long before moving back in

	-- what counts as a wall
	RAY_COUNT = 24,                -- rays around you
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
local lastWall = nil        -- { point, part, seen }
local smoothDir = nil
local TWO_PI = 2 * math.pi
local detour = 0            -- how far out from the wall your line currently is (studs)
local returnTimer = 0
local lastAvoidCheck = 0

-- one RaycastParams, reused (the original made a new one for every ray)
local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
params.IgnoreWater = true
params.RespectCanCollide = true -- walk-through decorations don't count

-- follow a path of names down from Workspace (nil if it doesn't exist right now, e.g. map not loaded)
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
	-- ignored folders (looked up again every refresh, so it works when the map reloads)
	for _, path in ipairs(CONFIG.IGNORE_PATHS) do
		local inst = findPath(path)
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

-- your input as a world direction (+ how hard you're pushing)
local function getInput()
	local v = nil
	if controls then
		local ok, mv = pcall(controls.GetMoveVector, controls)
		if ok and typeof(mv) == "Vector3" then v = mv end
	end
	if not v then
		local x, z = 0, 0
		if UserInputService:IsKeyDown(Enum.KeyCode.W) then z -= 1 end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then z += 1 end
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then x -= 1 end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then x += 1 end
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
-- WALL DETECTION: closest point of a real wall, all around you
------------------------------------------------------------------------
local function castAt(center, feetY, dir, range)
	local low = workspace:Raycast(Vector3.new(center.X, feetY + CONFIG.WALL_LOW, center.Z), dir * range, params)
	if not isSteep(low) then return nil end
	local d = flat(low.Position - center).Magnitude
	-- tall + straight up: the same direction must also be blocked higher up, at about the same distance
	local high = workspace:Raycast(Vector3.new(center.X, feetY + CONFIG.WALL_HIGH, center.Z),
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
		local hit, d = castAt(center, feetY, Vector3.new(math.sin(a), 0, math.cos(a)), range)
		if hit then
			if d < bestD then best, bestD, bestA = hit, d, a end
			if lastWall and hit.Instance == lastWall.part and d < onLastD then onLast, onLastD = hit, d end
		end
	end
	if not best then return nil end
	-- refine the closest direction (accurate at corners)
	for _, f in ipairs({ -0.5, -0.25, 0.25, 0.5 }) do
		local a = bestA + f * step
		local hit, d = castAt(center, feetY, Vector3.new(math.sin(a), 0, math.cos(a)), range)
		if hit and d < bestD then best, bestD = hit, d end
	end
	-- stay on the wall you're on unless another one is clearly closer (no flip-flop in corridors);
	-- while going round something, always stay on it (the thing you're passing must not take over)
	if onLast and onLast.Instance ~= best.Instance and (lockToLast or onLastD < bestD + CONFIG.SWITCH_MARGIN) then
		best, bestD = onLast, onLastD
	end
	return best, bestD
end

------------------------------------------------------------------------
-- GETTING PAST THINGS ALONG THE WALL
------------------------------------------------------------------------
-- Is the straight line from you to `to` clear for your body? (knee + waist height; things you can walk on don't count)
local function bodyLineClear(center, feetY, to)
	local delta = flat(to - center)
	if delta.Magnitude < 0.05 then return true end
	for _, h in ipairs(CONFIG.BODY_HEIGHTS) do
		local hit = workspace:Spherecast(Vector3.new(center.X, feetY + h, center.Z), CONFIG.BODY_RADIUS, delta, params)
		if hit and isSteep(hit) then return false end
	end
	return true
end

-- Smallest offset from the wall (0, DETOUR_STEP, ... MAX_DETOUR) whose line ahead is clear.
-- Returns the offset and the point to head for, or nil if nothing within MAX_DETOUR gets past.
local function findLane(center, feetY, tangent, rhat, dist, lookahead)
	local k = 0
	while k <= CONFIG.MAX_DETOUR + 1e-6 do
		local lanePoint = center + tangent * lookahead + rhat * (CONFIG.DESIRED_WALL_DISTANCE + k - dist)
		if bodyLineClear(center, feetY, lanePoint) then return k, lanePoint end
		k += CONFIG.DETOUR_STEP
	end
	return nil
end

------------------------------------------------------------------------
-- STEERING
------------------------------------------------------------------------
local function steer(dir, mag, dt)
	if smoothDir then
		local b = smoothDir:Lerp(dir, 1 - math.exp(-dt / CONFIG.STEER_SMOOTHING))
		if b.Magnitude > 1e-3 then dir = b.Unit end
	end
	smoothDir = dir
	humanoid:Move(dir * mag, false)
end

local function onStep(dt)
	if not running or not enabled then return end
	if not (char and hrp and humanoid and hrp.Parent) or humanoid.Health <= 0 then return end
	local now = os.clock()
	if now - lastFilterRefresh > 1 then
		lastFilterRefresh = now
		refreshFilter()
	end

	if CONFIG.SHIFTLOCK_DISABLES and isShiftLocked() then
		lastWall, smoothDir = nil, nil
		return
	end
	local move, mag = getInput()
	if not move or humanoid.FloorMaterial == Enum.Material.Air then
		smoothDir = nil
		if not move then detour = 0 end
		return -- not moving / in the air: leave you alone
	end

	local center = hrp.Position
	local feetY = getFeetY()
	local hit, dist = findWall(center, feetY, detour, detour > 0)
	if hit then
		lastWall = { point = hit.Position, part = hit.Instance, seen = now }
	elseif lastWall and now - lastWall.seen < CONFIG.GRACE_KEEP_SECONDS then
		dist = flat(center - lastWall.point).Magnitude
	else
		lastWall, smoothDir, detour = nil, nil, 0
		return
	end
	if dist > CONFIG.STICK_DETECT_DISTANCE + detour then
		smoothDir, detour = nil, 0
		return
	end

	-- the wall's direction at the closest point: rhat points from the wall to you
	local r = flat(center - lastWall.point)
	if r.Magnitude < 1e-3 then return end
	local rhat = r.Unit
	local away = move:Dot(rhat)
	if away > CONFIG.LEAVE_DOT then
		smoothDir, detour = nil, 0
		return -- you're steering away from it: let go
	end
	local tangent = Vector3.new(-rhat.Z, 0, rhat.X)
	local along = move:Dot(tangent)
	if along < 0 then
		tangent, along = -tangent, -along
	end
	if along < CONFIG.MIN_ALONG and away > -0.5 then
		smoothDir, detour = nil, 0
		return -- not really moving along it
	end

	local dir
	if CONFIG.AVOID then
		-- something in the way further along the wall? pick the lane that gets past it
		local lookahead = math.max(CONFIG.MIN_LOOKAHEAD, humanoid.WalkSpeed * mag * CONFIG.LOOKAHEAD_TIME)
		if now - lastAvoidCheck >= 0.05 then
			lastAvoidCheck = now
			local k = findLane(center, feetY, tangent, rhat, dist, lookahead)
			if not k then
				k = 0 -- nothing nearby gets past (inside corner / big structure): no detour
			end
			if k > detour then
				detour, returnTimer = k, 0 -- move out right away
			elseif k < detour then
				returnTimer += 0.05
				if returnTimer >= CONFIG.RETURN_DELAY then
					detour, returnTimer = k, 0 -- the way back in has been clear for a moment
				end
			else
				returnTimer = 0
			end
		end
		-- always head along a line that's been checked clear: get onto the lane sharply (short line)
		-- if that's clear, otherwise along the long checked lane line
		local offset = CONFIG.DESIRED_WALL_DISTANCE + detour - dist
		local short = center + tangent * CONFIG.HUG_LOOKAHEAD + rhat * offset
		if bodyLineClear(center, feetY, short) then
			dir = flat(short - center)
		else
			dir = flat(tangent * lookahead + rhat * offset)
		end
	else
		-- slide along the wall, pulled/pushed to DESIRED_WALL_DISTANCE
		local correction = math.clamp(-(dist - CONFIG.DESIRED_WALL_DISTANCE) * CONFIG.DISTANCE_GAIN,
			-CONFIG.MAX_CORRECTION, CONFIG.MAX_CORRECTION)
		dir = tangent + rhat * correction
	end
	if dir.Magnitude < 1e-3 then return end
	steer(dir.Unit, mag, dt)
end

------------------------------------------------------------------------
-- LIFECYCLE
------------------------------------------------------------------------
local function onCharacterAdded(c)
	char = c
	humanoid = c:WaitForChild("Humanoid", 5)
	hrp = c:WaitForChild("HumanoidRootPart", 5)
	lastWall, smoothDir = nil, nil
	refreshFilter()
end
if player.Character then task.spawn(onCharacterAdded, player.Character) end
connections[#connections + 1] = player.CharacterAdded:Connect(onCharacterAdded)

connections[#connections + 1] = UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or not running then return end
	if input.KeyCode == CONFIG.TOGGLE_KEY then
		enabled = not enabled
		lastWall, smoothDir = nil, nil
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
