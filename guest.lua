-- LocalScript (StarterPlayer > StarterPlayerScripts)
-- Multi-Guest turn away + slowdown stun, with BIGGER + LOWER "STUNNED" box

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local LOCAL_PLAYER = Players.LocalPlayer
if not LOCAL_PLAYER then return end

--========================
-- CONFIG
--========================
local RADIUS = 11
local STUN_SECONDS = 0.7
local TRIGGER_VALUE = 100

local KILLER_HEALTH_THRESHOLD = 500
local WALK_SPEED_TARGET = 8
local MIN_SPRINT_MULT_FACTOR = 0.35
local APPLY_SLOW_EVERY_FRAME = true

local TURN_LERP_ALPHA = 0.55

-- UI tuning (NEW)
local STUN_BOX_SIZE = UDim2.new(0, 520, 0, 150)  -- bigger
local STUN_BOX_POS  = UDim2.new(0.5, 0, 0.26, 0) -- slightly lower

--========================
-- CLEANUP PREVIOUS RUN
--========================
if _G.GuestRadiusWalkStun and type(_G.GuestRadiusWalkStun.Cleanup) == "function" then
	pcall(function() _G.GuestRadiusWalkStun.Cleanup() end)
end

local ctrl = {
	conns = {},
	running = true,

	stunUntil = 0,
	wasCondTrue = false,

	stunned = false,
	savedWalkSpeed = nil,
	savedJumpPower = nil,
	savedAutoRotate = nil,

	stunWasKiller = false,
	sprintObj = nil,
	sprintOriginal = nil,

	gui = nil,
	box = nil,

	lastEscapeDir = nil,
}

_G.GuestRadiusWalkStun = ctrl

local function connect(sig, fn)
	local c = sig:Connect(fn)
	table.insert(ctrl.conns, c)
	return c
end

function ctrl.Cleanup()
	ctrl.running = false
	for _, c in ipairs(ctrl.conns) do
		pcall(function() c:Disconnect() end)
	end
	ctrl.conns = {}
	if ctrl.gui then
		pcall(function() ctrl.gui:Destroy() end)
	end
	ctrl.gui, ctrl.box = nil, nil
end

local function getMyHumanoidAndHRP()
	local char = LOCAL_PLAYER.Character
	if not char then return nil, nil end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local hrp = char:FindFirstChild("HumanoidRootPart")
	return hum, hrp
end

local function wsPlayersFolder()
	return workspace:FindFirstChild("Players")
end

local function survivorsFolder()
	local p = wsPlayersFolder()
	return p and p:FindFirstChild("Survivors") or nil
end

local function killersFolder()
	local p = wsPlayersFolder()
	return p and p:FindFirstChild("Killers") or nil
end

local function getModelPart(model)
	if not model then return nil end
	return model:FindFirstChild("HumanoidRootPart")
		or model:FindFirstChild("Head")
		or model.PrimaryPart
end

local function guestTriggered(model)
	local rm = model and model:FindFirstChild("ResistanceMultipliers")
	if not rm then return false end
	for _, child in ipairs(rm:GetChildren()) do
		if child.Name == "ResistanceStatus" and (child:IsA("IntValue") or child:IsA("NumberValue")) then
			if child.Value == TRIGGER_VALUE then
				return true
			end
		end
	end
	return false
end

local function getTriggeredGuestPartsWithinRadius(myHRP)
	local surv = survivorsFolder()
	if not surv or not myHRP then return {} end

	local parts = {}
	local myPos = myHRP.Position

	for _, m in ipairs(surv:GetChildren()) do
		if m:IsA("Model") and guestTriggered(m) then
			local part = getModelPart(m)
			if part then
				local dist = (part.Position - myPos).Magnitude
				if dist <= RADIUS then
					table.insert(parts, part)
				end
			end
		end
	end

	return parts
end

local function isLocalKiller(hum)
	return hum and hum.Health > KILLER_HEALTH_THRESHOLD
end

local function findMyKillerSprintingValue()
	local killers = killersFolder()
	if not killers then return nil end

	local direct = killers:FindFirstChild(LOCAL_PLAYER.Name)
	if direct then
		local sm = direct:FindFirstChild("SpeedMultipliers")
		local sprint = sm and sm:FindFirstChild("Sprinting")
		if sprint and (sprint:IsA("NumberValue") or sprint:IsA("IntValue")) then
			return sprint
		end
	end

	for _, model in ipairs(killers:GetChildren()) do
		if model:IsA("Model") then
			local sm = model:FindFirstChild("SpeedMultipliers")
			local sprint = sm and sm:FindFirstChild("Sprinting")
			if sprint and (sprint:IsA("NumberValue") or sprint:IsA("IntValue")) then
				local ok, uid = pcall(function() return model:GetAttribute("UserId") end)
				if ok and uid == LOCAL_PLAYER.UserId then
					return sprint
				end
				if model.Name == LOCAL_PLAYER.Name then
					return sprint
				end
			end
		end
	end

	return nil
end

--========================
-- UI (UPDATED size/pos)
--========================
local function makeStunGui()
	local playerGui = LOCAL_PLAYER:WaitForChild("PlayerGui")
	local old = playerGui:FindFirstChild("WalkStunOverlayGui")
	if old then old:Destroy() end

	local gui = Instance.new("ScreenGui")
	gui.Name = "WalkStunOverlayGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 999999
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = STUN_BOX_POS
	frame.Size = STUN_BOX_SIZE
	frame.BackgroundColor3 = Color3.fromRGB(10, 10, 10)
	frame.BackgroundTransparency = 0.15
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.ZIndex = 50
	frame.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 16)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Transparency = 0.12
	stroke.Color = Color3.fromRGB(255, 60, 60)
	stroke.Parent = frame

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 1, 0)
	label.Font = Enum.Font.SourceSansBold
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 60, 60)
	label.TextStrokeTransparency = 0.6
	label.Text = "STUNNED"
	label.ZIndex = 51
	label.Parent = frame

	return gui, frame
end

ctrl.gui, ctrl.box = makeStunGui()

local function setStunUi(on)
	if ctrl.box then ctrl.box.Visible = on end
end

--========================
-- TURN AWAY FROM ALL GUESTS
--========================
local function computeEscapeDir(myPos, guestParts)
	if #guestParts == 0 then return nil end
	local sum = Vector3.zero
	for _, part in ipairs(guestParts) do
		local gp = part.Position
		local away = Vector3.new(myPos.X - gp.X, 0, myPos.Z - gp.Z)
		local d = away.Magnitude
		if d > 0.001 then
			local w = 1 / math.max(0.25, d)
			sum += (away / d) * w
		end
	end
	if sum.Magnitude < 0.001 then
		return nil
	end
	return sum.Unit
end

local function faceDir(myHRP, dir)
	if not myHRP or not dir then return end
	local pos = myHRP.Position
	if ctrl.lastEscapeDir then
		local blended = ctrl.lastEscapeDir:Lerp(dir, TURN_LERP_ALPHA)
		if blended.Magnitude > 0.001 then
			dir = blended.Unit
		end
	end
	ctrl.lastEscapeDir = dir
	myHRP.CFrame = CFrame.new(pos, pos + dir)
end

--========================
-- SLOWDOWN
--========================
local function applySlow(hum, hrp)
	if ctrl.stunWasKiller then
		if not ctrl.sprintObj then
			ctrl.sprintObj = findMyKillerSprintingValue()
			if ctrl.sprintObj then ctrl.sprintOriginal = ctrl.sprintObj.Value end
		end
		if ctrl.sprintObj and ctrl.sprintOriginal ~= nil then
			local currentSpeed = (hrp and hrp.AssemblyLinearVelocity.Magnitude) or 0
			currentSpeed = math.max(currentSpeed, 0.1)
			local desiredFactor = WALK_SPEED_TARGET / currentSpeed
			local factor = math.clamp(desiredFactor, MIN_SPRINT_MULT_FACTOR, 1)
			ctrl.sprintObj.Value = ctrl.sprintOriginal * factor
		else
			hum.WalkSpeed = WALK_SPEED_TARGET
		end
	else
		hum.WalkSpeed = WALK_SPEED_TARGET
	end
end

local function startStun(hum)
	ctrl.stunWasKiller = isLocalKiller(hum)
	ctrl.stunUntil = math.max(ctrl.stunUntil, os.clock() + STUN_SECONDS)
	ctrl.lastEscapeDir = nil
end

local function beginStunIfNeeded(hum)
	if ctrl.stunned then return end
	ctrl.stunned = true
	ctrl.savedWalkSpeed = hum.WalkSpeed
	ctrl.savedJumpPower = hum.JumpPower
	ctrl.savedAutoRotate = hum.AutoRotate
	hum.AutoRotate = false
	ctrl.sprintObj, ctrl.sprintOriginal = nil, nil
end

local function endStun(hum)
	if not ctrl.stunned then return end
	ctrl.stunned = false
	if ctrl.sprintObj and ctrl.sprintOriginal ~= nil then
		pcall(function() ctrl.sprintObj.Value = ctrl.sprintOriginal end)
	end
	ctrl.sprintObj, ctrl.sprintOriginal = nil, nil
	ctrl.stunWasKiller = false
	ctrl.lastEscapeDir = nil
	if ctrl.savedAutoRotate ~= nil then hum.AutoRotate = ctrl.savedAutoRotate end
	if ctrl.savedWalkSpeed ~= nil then hum.WalkSpeed = ctrl.savedWalkSpeed end
	if ctrl.savedJumpPower ~= nil then hum.JumpPower = ctrl.savedJumpPower end
end

connect(LOCAL_PLAYER.CharacterAdded, function()
	ctrl.stunned = false
	ctrl.stunUntil = 0
	ctrl.wasCondTrue = false
	ctrl.lastEscapeDir = nil
	setStunUi(false)
end)

--========================
-- MAIN LOOP
--========================
connect(RunService.Heartbeat, function()
	if not ctrl.running then return end

	local hum, myHRP = getMyHumanoidAndHRP()
	if not hum or not myHRP then return end

	local guestParts = getTriggeredGuestPartsWithinRadius(myHRP)
	local condNow = (#guestParts > 0)

	if condNow and not ctrl.wasCondTrue then
		startStun(hum)
	end
	ctrl.wasCondTrue = condNow

	local stunnedNow = os.clock() < ctrl.stunUntil

	if stunnedNow then
		beginStunIfNeeded(hum)
		if APPLY_SLOW_EVERY_FRAME then
			applySlow(hum, myHRP)
		end

		local dir = computeEscapeDir(myHRP.Position, guestParts)
		if not dir then
			dir = ctrl.lastEscapeDir or Vector3.new(myHRP.CFrame.LookVector.X, 0, myHRP.CFrame.LookVector.Z).Unit
		end
		faceDir(myHRP, dir)

		setStunUi(true)
	else
		endStun(hum)
		setStunUi(false)
	end
end)

print("[WalkStun MultiGuest] UI bigger/lower applied.")
