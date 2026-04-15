do
local RunService = game:GetService("RunService")
local PlayersService = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = PlayersService.LocalPlayer
if not LocalPlayer then return end

local SURVIVORS_PATH = {"Players", "Survivors"}
local TARGET_NAMES = {
	Guest1337 = true,
	Shedletsky = true,
	TwoTime = true,
	JaneDoe = true,
	Chance = true,
}

local RESISTANCE_FOLDER_NAME = "ResistanceMultipliers"
local RESISTANCE_VALUE_NAME = "ResistanceStatus"
local TRIGGER_VALUES = { [20] = true, [40] = true }

local DODGE_COOLDOWN = 0.5
local DODGE_RANGE = 20
local MIN_SPEED_TO_TRIGGER = 0.2
local DODGE_FORCE_P = 1e4
local DODGE_FORCE_MAX = Vector3.new(1e5, 1e5, 1e5)
local DODGE_MAX_SPEED = 19

-- Separate dodge delays per survivor
local DODGE_DELAYS = {
	Shedletsky = 0,
	JaneDoe = 0,
	Chance = 0,
}

-- Separate dodge durations per survivor
local DODGE_DURATIONS = {
	Default = 0.35,
	Shedletsky = 0.5,
	JaneDoe = 0.50,
	Chance = 0.50,
}

local ENABLE_AUTO_KILL_PREVIOUS = true
local KILL_HOTKEY = Enum.KeyCode.K

local WATCHED_ANIM_IDS = {
	["131430497821198"] = true,
	["119181003138006"] = true,
	["101101433684051"] = true,
	["116787687605496"] = true,
	["83685305553364"]  = true,
	["99030950661794"]  = true,
	["100592913030351"] = true,
	["81935774508746"]  = true,
	["109777684604906"] = true,
	["105026134432828"] = true,
	["119429069577280"] = true,
	["85667731859561"]  = true,
	["108757133541940"] = true,
	["130130264576253"] = true,
	["105747066695777"] = true,
	["126355327951215"] = true,
	["121086746534252"] = true,
	["126681776859538"] = true,
	["129976080405072"] = true,
	["106847695270773"] = true,
	["93284670378212"]  = true,
}

local running = true
local connections = {}
local watchedValues = {}
local watchedChanceObjects = {}
local lastDodgeTime = 0
local char, hrp, humanoid = nil, nil, nil
local sprintValueInstance = nil
local currentSprintMultiplier = 1
local animatorConnection = nil

if _G.AutoReflexController and _G.AutoReflexController ~= true then
	_G.AutoReflexPrevious = _G.AutoReflexController
end
local controller = {}
_G.AutoReflexController = controller

local function safeFind(pathParts)
	local node = Workspace
	for _, p in ipairs(pathParts) do
		if not node then return nil end
		node = node:FindFirstChild(p)
	end
	return node
end

local function findSurvivorsFolder()
	return safeFind(SURVIVORS_PATH)
end

local function getModelRootPart(model)
	if not model then return nil end
	if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then
		return model.PrimaryPart
	end
	local candidates = {"HumanoidRootPart", "Torso", "UpperTorso", "LowerTorso"}
	for _, name in ipairs(candidates) do
		local p = model:FindFirstChild(name)
		if p and p:IsA("BasePart") then
			return p
		end
	end
	return nil
end

local function getModelPosition(model)
	local root = getModelRootPart(model)
	if root then
		return root.Position
	end
	if not model then return nil end

	local sum = Vector3.new(0, 0, 0)
	local count = 0
	for _, desc in ipairs(model:GetDescendants()) do
		if desc:IsA("BasePart") then
			sum += desc.Position
			count += 1
		end
	end
	if count > 0 then
		return sum / count
	end
	return nil
end

local function getHorizontalUnit(vec)
	local flat = Vector3.new(vec.X, 0, vec.Z)
	if flat.Magnitude < 0.001 then
		return nil
	end
	return flat.Unit
end

local function getDodgeDurationForSurvivor(name)
	if name and DODGE_DURATIONS[name] then
		return DODGE_DURATIONS[name]
	end
	return DODGE_DURATIONS.Default
end

local function killPreviousController()
	if _G.AutoReflexPrevious then
		pcall(function()
			if type(_G.AutoReflexPrevious.Cleanup) == "function" then
				_G.AutoReflexPrevious.Cleanup()
			end
		end)
		_G.AutoReflexPrevious = nil
	end
end

local function locateAndWatchSprintValue()
	if sprintValueInstance and sprintValueInstance._conn then
		pcall(function() sprintValueInstance._conn:Disconnect() end)
		sprintValueInstance._conn = nil
	end
	sprintValueInstance = nil
	currentSprintMultiplier = 1

	local playersNode = Workspace:FindFirstChild("Players")
	if not playersNode then return end
	local killersFolder = playersNode:FindFirstChild("Killers")
	if not killersFolder then return end

	local myKillerEntry = killersFolder:FindFirstChild(LocalPlayer.Name)
	if not myKillerEntry then
		local conn
		conn = killersFolder.ChildAdded:Connect(function(child)
			if not running then
				conn:Disconnect()
				return
			end
			if child.Name == LocalPlayer.Name then
				conn:Disconnect()
				task.delay(0.05, locateAndWatchSprintValue)
			end
		end)
		table.insert(connections, conn)
		return
	end

	local speedMultFolder = myKillerEntry:FindFirstChild("SpeedMultipliers")
	if not speedMultFolder then
		local conn = myKillerEntry.ChildAdded:Connect(function(child)
			if not running then return end
			if child.Name == "SpeedMultipliers" then
				task.delay(0.05, locateAndWatchSprintValue)
			end
		end)
		table.insert(connections, conn)
		return
	end

	local sprintVal = speedMultFolder:FindFirstChild("Sprinting")
	if sprintVal and (sprintVal:IsA("NumberValue") or sprintVal:IsA("IntValue")) then
		sprintValueInstance = sprintVal
		currentSprintMultiplier = sprintVal.Value or 1
		local conn = sprintVal:GetPropertyChangedSignal("Value"):Connect(function()
			if not running then return end
			currentSprintMultiplier = sprintVal.Value or 1
		end)
		sprintVal._conn = conn
		table.insert(connections, conn)
	else
		local conn2 = speedMultFolder.ChildAdded:Connect(function(child)
			if not running then return end
			if child.Name == "Sprinting" and (child:IsA("NumberValue") or child:IsA("IntValue")) then
				task.delay(0.02, locateAndWatchSprintValue)
			end
		end)
		table.insert(connections, conn2)
	end
end

local function getCurrentSpeed()
	if sprintValueInstance and sprintValueInstance.Value then
		local mv = tonumber(sprintValueInstance.Value) or currentSprintMultiplier or 1
		return 8 * mv
	end
	if humanoid and humanoid.WalkSpeed then
		return humanoid.WalkSpeed
	end
	return 8
end

local function isPlayingKiller()
	if humanoid then
		local okMax = humanoid.MaxHealth and humanoid.MaxHealth > 500
		local okCur = humanoid.Health and humanoid.Health > 500
		if okMax or okCur then
			return true
		end
	end

	local playersNode = Workspace:FindFirstChild("Players")
	if playersNode then
		local killers = playersNode:FindFirstChild("Killers")
		if killers and killers:FindFirstChild(LocalPlayer.Name) then
			return true
		end
	end

	return false
end

local function interruptActiveOverrides()
	if controller._activeDodge then
		local info = controller._activeDodge
		controller._activeDodge = nil

		pcall(function()
			if info.bv and info.bv.Parent then
				info.bv:Destroy()
			end
		end)

		pcall(function()
			if info.dieConn then
				info.dieConn:Disconnect()
			end
		end)

		pcall(function()
			if humanoid then
				humanoid.AutoRotate = info.savedAutoRotate
			end
		end)
	end
end

local function performBackwardDodge(dodgeDuration)
	if not isPlayingKiller() then return end
	if not char or not hrp or not humanoid then return end

	local speed = getCurrentSpeed()
	if speed < MIN_SPEED_TO_TRIGGER then return end
	if DODGE_MAX_SPEED and type(DODGE_MAX_SPEED) == "number" then
		speed = math.min(speed, DODGE_MAX_SPEED)
	end

	local backward = getHorizontalUnit(-hrp.CFrame.LookVector)
	if not backward then return end

	interruptActiveOverrides()

	local savedAutoRotate = humanoid.AutoRotate
	humanoid.AutoRotate = false
	humanoid.WalkSpeed = 0

	local bv = Instance.new("BodyVelocity")
	bv.Name = "AutoReflexBackwardDodge"

	local maxForceHoriz
	if typeof(DODGE_FORCE_MAX) == "Vector3" then
		maxForceHoriz = Vector3.new(DODGE_FORCE_MAX.X, 0, DODGE_FORCE_MAX.Z)
	else
		local scalar = tonumber(DODGE_FORCE_MAX) or 1e5
		maxForceHoriz = Vector3.new(scalar, 0, scalar)
	end

	local preservedY = 0
	pcall(function()
		if hrp and hrp:IsA("BasePart") then
			preservedY = hrp.Velocity.Y or 0
		end
	end)

	bv.MaxForce = maxForceHoriz
	bv.P = DODGE_FORCE_P
	bv.Velocity = Vector3.new(backward.X * speed, preservedY, backward.Z * speed)
	bv.Parent = hrp

	local dieConn
	dieConn = humanoid.Died:Connect(function()
		if bv and bv.Parent then
			pcall(function() bv:Destroy() end)
		end
		if dieConn then
			pcall(function() dieConn:Disconnect() end)
		end
	end)

	controller._activeDodge = {
		bv = bv,
		savedAutoRotate = savedAutoRotate,
		dieConn = dieConn,
	}

	if ENABLE_AUTO_KILL_PREVIOUS then
		killPreviousController()
	end

	task.delay(tonumber(dodgeDuration) or DODGE_DURATIONS.Default, function()
		if not controller then return end
		local info = controller._activeDodge
		controller._activeDodge = nil

		if info and info.bv and info.bv.Parent then
			pcall(function() info.bv:Destroy() end)
		end
		if info and info.dieConn then
			pcall(function() info.dieConn:Disconnect() end)
		end
		if info and humanoid then
			pcall(function() humanoid.AutoRotate = info.savedAutoRotate end)
		end
	end)
end

local function scheduleTrackedBackwardDodge(survivor, delayTime, dodgeDuration)
	if not survivor then return end
	if not isPlayingKiller() then return end

	if not hrp then
		local c = LocalPlayer.Character
		if c then
			hrp = c:FindFirstChild("HumanoidRootPart")
		end
		if not hrp then return end
	end

	local sPos = getModelPosition(survivor)
	if not sPos then return end
	local dist = (hrp.Position - sPos).Magnitude
	if dist > DODGE_RANGE then return end

	if tick() - lastDodgeTime < DODGE_COOLDOWN then return end
	lastDodgeTime = tick()

	local delayToUse = tonumber(delayTime) or 0
	local durationToUse = tonumber(dodgeDuration) or DODGE_DURATIONS.Default
	local token = tostring(tick()) .. "_" .. tostring(math.random(1000, 9999))
	controller._pendingBackwardDodgeToken = token

	task.delay(delayToUse, function()
		if not running then return end
		if controller._pendingBackwardDodgeToken ~= token then return end
		controller._pendingBackwardDodgeToken = nil

		if not survivor or not survivor.Parent then return end
		if not isPlayingKiller() then return end
		if not char or not hrp or not humanoid then return end

		local latestPos = getModelPosition(survivor)
		if not latestPos then return end
		local latestDist = (hrp.Position - latestPos).Magnitude
		if latestDist > DODGE_RANGE then return end

		performBackwardDodge(durationToUse)
	end)
end

local function onResistanceValueChanged(resVal)
	if not resVal then return end
	local v = tonumber(resVal.Value) or 0
	if not TRIGGER_VALUES[v] then return end
	if not isPlayingKiller() then return end

	local mapping = watchedValues[resVal]
	local survivor = mapping and mapping.survivor
	if not survivor then
		if resVal.Parent and resVal.Parent.Parent then
			survivor = resVal.Parent.Parent
		end
	end
	if not survivor then return end

	local sPos = getModelPosition(survivor)
	if not sPos then return end

	if not hrp then
		local c = LocalPlayer.Character
		if c then
			hrp = c:FindFirstChild("HumanoidRootPart")
		end
		if not hrp then return end
	end

	local dist = (hrp.Position - sPos).Magnitude
	if dist <= DODGE_RANGE then
		scheduleTrackedBackwardDodge(
			survivor,
			DODGE_DELAYS[survivor.Name] or 0,
			getDodgeDurationForSurvivor(survivor.Name)
		)
	end
end

local function triggerChanceShootingGunDodge(chanceSurvivor)
	if not chanceSurvivor or chanceSurvivor.Name ~= "Chance" then return end
	if not isPlayingKiller() then return end

	local sPos = getModelPosition(chanceSurvivor)
	if not sPos then return end

	if not hrp then
		local c = LocalPlayer.Character
		if c then
			hrp = c:FindFirstChild("HumanoidRootPart")
		end
		if not hrp then return end
	end

	local dist = (hrp.Position - sPos).Magnitude
	if dist <= DODGE_RANGE then
		scheduleTrackedBackwardDodge(
			chanceSurvivor,
			DODGE_DELAYS.Chance,
			getDodgeDurationForSurvivor("Chance")
		)
	end
end

local function watchChanceShootingGun(chanceSurvivor)
	if not chanceSurvivor or chanceSurvivor.Name ~= "Chance" then return end

	local speedFolder = chanceSurvivor:FindFirstChild("SpeedMultipliers")
	if speedFolder then
		local existing = speedFolder:FindFirstChild("ShootingGun")
		if existing and not watchedChanceObjects[existing] then
			watchedChanceObjects[existing] = true
			triggerChanceShootingGunDodge(chanceSurvivor)
		end

		local conn = speedFolder.ChildAdded:Connect(function(child)
			if not running then return end
			if child.Name == "ShootingGun" and not watchedChanceObjects[child] then
				watchedChanceObjects[child] = true
				triggerChanceShootingGunDodge(chanceSurvivor)
			end
		end)
		table.insert(connections, conn)
	else
		local conn2 = chanceSurvivor.ChildAdded:Connect(function(child)
			if not running then return end
			if child.Name == "SpeedMultipliers" then
				task.delay(0.03, function()
					watchChanceShootingGun(chanceSurvivor)
				end)
			end
		end)
		table.insert(connections, conn2)
	end
end

local function watchSurvivor(survivor)
	if not survivor or not TARGET_NAMES[survivor.Name] then return end

	if survivor.Name == "Chance" then
		watchChanceShootingGun(survivor)
		return
	end

	local folder = survivor:FindFirstChild(RESISTANCE_FOLDER_NAME)
	if folder then
		local val = folder:FindFirstChild(RESISTANCE_VALUE_NAME)
		if val and (val:IsA("IntValue") or val:IsA("NumberValue")) then
			if not watchedValues[val] then
				local conn = val:GetPropertyChangedSignal("Value"):Connect(function()
					onResistanceValueChanged(val)
				end)
				watchedValues[val] = { conn = conn, survivor = survivor }
				table.insert(connections, conn)
				onResistanceValueChanged(val)
			end
		else
			local conn2 = folder.ChildAdded:Connect(function(child)
				if not running then return end
				if child.Name == RESISTANCE_VALUE_NAME and (child:IsA("IntValue") or child:IsA("NumberValue")) then
					if not watchedValues[child] then
						local conn = child:GetPropertyChangedSignal("Value"):Connect(function()
							onResistanceValueChanged(child)
						end)
						watchedValues[child] = { conn = conn, survivor = survivor }
						table.insert(connections, conn)
						onResistanceValueChanged(child)
					end
				end
			end)
			table.insert(connections, conn2)
		end
	else
		local c = survivor.ChildAdded:Connect(function(child)
			if not running then return end
			if child.Name == RESISTANCE_FOLDER_NAME then
				task.delay(0.03, function()
					watchSurvivor(survivor)
				end)
			end
		end)
		table.insert(connections, c)
	end
end

local function scanAndWatchSurvivors()
	local survivorsFolder = findSurvivorsFolder()
	if not survivorsFolder then return end

	for _, child in ipairs(survivorsFolder:GetChildren()) do
		pcall(function()
			watchSurvivor(child)
		end)
	end

	local connAdd = survivorsFolder.ChildAdded:Connect(function(child)
		if not running then return end
		pcall(function()
			watchSurvivor(child)
		end)
	end)
	table.insert(connections, connAdd)
end

table.insert(connections, UserInputService.InputBegan:Connect(function(input, gp)
	if gp then return end
	if input.KeyCode == KILL_HOTKEY then
		killPreviousController()
	end
end))

locateAndWatchSprintValue()
do
	local node = Workspace:FindFirstChild("Players")
	if node then
		local killers = node:FindFirstChild("Killers")
		if killers then
			local conn = killers.ChildAdded:Connect(function()
				if not running then return end
				task.delay(0.05, locateAndWatchSprintValue)
			end)
			table.insert(connections, conn)
		end

		local conn2 = node.ChildAdded:Connect(function()
			if not running then return end
			if node:FindFirstChild("Killers") then
				task.delay(0.05, locateAndWatchSprintValue)
			end
		end)
		table.insert(connections, conn2)
	else
		local conn = Workspace.ChildAdded:Connect(function(child)
			if not running then return end
			if child.Name == "Players" then
				task.delay(0.05, locateAndWatchSprintValue)
			end
		end)
		table.insert(connections, conn)
	end
end

local function onAnimationPlayed(track)
	if not track or not track.Animation then return end
	local animId = tostring(track.Animation.AnimationId or "")
	local idNum = animId:match("(%d+)")
	if not idNum then return end

	if WATCHED_ANIM_IDS[tostring(idNum)] then
		interruptActiveOverrides()
	end
end

local function onCharacterAdded(c)
	char = c
	humanoid = char:FindFirstChildOfClass("Humanoid")
	hrp = char:FindFirstChild("HumanoidRootPart")

	if not humanoid then
		humanoid = char:WaitForChild("Humanoid", 2)
	end
	if not hrp then
		hrp = char:WaitForChild("HumanoidRootPart", 2)
	end

	task.delay(0.05, locateAndWatchSprintValue)

	pcall(function()
		if animatorConnection then
			pcall(function() animatorConnection:Disconnect() end)
			animatorConnection = nil
		end

		local animator = humanoid:FindFirstChildOfClass("Animator") or humanoid:WaitForChild("Animator", 1)
		if animator then
			animatorConnection = animator.AnimationPlayed:Connect(onAnimationPlayed)
			table.insert(connections, animatorConnection)
		end
	end)
end

if LocalPlayer.Character then
	onCharacterAdded(LocalPlayer.Character)
end
table.insert(connections, LocalPlayer.CharacterAdded:Connect(onCharacterAdded))

scanAndWatchSurvivors()

local function cleanup()
	running = false

	for _, conn in ipairs(connections) do
		pcall(function() conn:Disconnect() end)
	end
	connections = {}

	for _, info in pairs(watchedValues) do
		if info and info.conn then
			pcall(function() info.conn:Disconnect() end)
		end
	end
	watchedValues = {}
	watchedChanceObjects = {}
	controller._pendingBackwardDodgeToken = nil

	if sprintValueInstance and sprintValueInstance._conn then
		pcall(function() sprintValueInstance._conn:Disconnect() end)
		sprintValueInstance._conn = nil
	end
	sprintValueInstance = nil

	if animatorConnection then
		pcall(function() animatorConnection:Disconnect() end)
		animatorConnection = nil
	end

	interruptActiveOverrides()

	if _G.AutoReflexController == controller then
		_G.AutoReflexController = nil
	end
	controller.Cleanup = nil
end
controller.Cleanup = cleanup

function controller.KillPrevious()
	killPreviousController()
end

function controller.TriggerDodgeNow()
	if hrp then
		performBackwardDodge(DODGE_DURATIONS.Default)
	end
end

if RunService:IsStudio() then
	warn(
		"[AutoReflex_BackwardOnly] running. Press 'K' to kill previous controller.",
		"Shed delay:", DODGE_DELAYS.Shedletsky,
		"Jane delay:", DODGE_DELAYS.JaneDoe,
		"Chance delay:", DODGE_DELAYS.Chance,
		"Shed duration:", DODGE_DURATIONS.Shedletsky,
		"Jane duration:", DODGE_DURATIONS.JaneDoe,
		"Chance duration:", DODGE_DURATIONS.Chance,
		"Range:", DODGE_RANGE
	)
end
end
