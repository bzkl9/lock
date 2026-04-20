do
	local RunService = game:GetService("RunService")
	local PlayersService = game:GetService("Players")
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

	local TRIGGER_VALUES = {
		[20] = true,
		[40] = true,
	}

	local DODGE_COOLDOWN = 0.5
	local DODGE_RANGE = 25
	local MIN_SPEED_TO_TRIGGER = 0.2
	local DODGE_FORCE_P = 1e4
	local DODGE_FORCE_MAX = Vector3.new(1e5, 0, 1e5)
	local DODGE_MAX_SPEED = 21
	local POLL_INTERVAL = 0.03

	local GROUND_RAY_HEIGHT = 2.5
	local GROUND_RAY_DISTANCE = 6
	local AIR_CANCEL_GRACE = 0.05

	local TWOTIME_TURN_MIN_OFFSET_DEGREES = 8
	local TWOTIME_TURN_MAX_OFFSET_DEGREES = 20
	local TWOTIME_TURN_HOLD = 0.5
	local TWOTIME_TURN_GYRO_P = 1e6
	local TWOTIME_TURN_GYRO_D = 1
	local TWOTIME_TURN_GYRO_MAX_TORQUE = Vector3.new(1e8, 1e8, 1e8)

	local DODGE_DELAYS = {
		Shedletsky = 0,
		JaneDoe = 0,
		Chance = 0,
	}

	local DODGE_DURATIONS = {
		Default = 0.35,
		Shedletsky = 0.5,
		JaneDoe = 0.5,
		Chance = 0.5,
	}

	local NO_DODGE_SPEED_MULTIPLIERS = {
		Entanglement = true,
		MassInfection = true,
		BeheadAbility = true,
		CorruptEnergy = true,
		DigitalFootprint = true,
		UnstableEye = true,
		["404Error"] = true,
		VoidRushCharging = true,
		VoidRushDash = true,
		VoidRushEndlag = true,
		NovaWindupSlowness = true,
		NoliObserving = true,
		HinderedMovement = true,
		NosBloodhookThrow = true,
		NosCataclysm = true,
		["666PursuitStart"] = true,
		["666PursuitEndlag"] = true,
		["666BloodHuntStart"] = true,
	}

	local ENABLE_AUTO_KILL_PREVIOUS = true
	local DEBUG = true

	local running = true
	local connections = {}

	local char = nil
	local hrp = nil
	local humanoid = nil

	local sprintValueInstance = nil
	local sprintValueConnection = nil
	local currentSprintMultiplier = 1

	local resistanceState = {}
	local chanceState = {}

	local lastDodgeTime = 0
	local pollAccum = 0
	local lastBlockedState = false
	local lastKillerPresent = false

	if ENABLE_AUTO_KILL_PREVIOUS and _G.AutoReflexController and type(_G.AutoReflexController.Cleanup) == "function" then
		pcall(function()
			_G.AutoReflexController.Cleanup()
		end)
	end

	local controller = {}
	_G.AutoReflexController = controller

	local function dbg(...)
		if DEBUG then
			warn("[AutoReflex]", ...)
		end
	end

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

	local function refreshCharacter()
		char = LocalPlayer.Character
		if not char then
			humanoid = nil
			hrp = nil
			return
		end

		humanoid = char:FindFirstChildOfClass("Humanoid")
		hrp = char:FindFirstChild("HumanoidRootPart")

		if not humanoid then
			humanoid = char:FindFirstChild("Humanoid")
		end
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

	local function rotateVectorAroundY(vec, radians)
		local cosA = math.cos(radians)
		local sinA = math.sin(radians)
		return Vector3.new(
			vec.X * cosA - vec.Z * sinA,
			0,
			vec.X * sinA + vec.Z * cosA
		)
	end

	local function hasGroundSupportFor(hrpRef, humanoidRef, charRef)
		if not hrpRef or not hrpRef.Parent or not humanoidRef or not humanoidRef.Parent then
			return false
		end

		if humanoidRef.FloorMaterial and humanoidRef.FloorMaterial ~= Enum.Material.Air then
			return true
		end

		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = charRef and {charRef} or {}

		local origin = hrpRef.Position + Vector3.new(0, GROUND_RAY_HEIGHT, 0)
		local direction = Vector3.new(0, -(GROUND_RAY_HEIGHT + GROUND_RAY_DISTANCE), 0)
		local result = Workspace:Raycast(origin, direction, params)

		return result ~= nil
	end

	local function getDodgeDurationForSurvivor(name)
		if name and DODGE_DURATIONS[name] then
			return DODGE_DURATIONS[name]
		end
		return DODGE_DURATIONS.Default
	end

	local function getMyKillerEntry()
		local playersFolder = Workspace:FindFirstChild("Players")
		if not playersFolder then return nil end

		local killersFolder = playersFolder:FindFirstChild("Killers")
		if not killersFolder then return nil end

		for _, child in ipairs(killersFolder:GetChildren()) do
			local username = child:GetAttribute("Username")
			if typeof(username) == "string" and username == LocalPlayer.Name then
				return child
			end

			if child.Name == LocalPlayer.Name then
				return child
			end
		end

		return nil
	end

	local function isCurrentlyKiller()
		return getMyKillerEntry() ~= nil
	end

	local function disconnectSprintWatcher()
		if sprintValueConnection then
			pcall(function()
				sprintValueConnection:Disconnect()
			end)
			sprintValueConnection = nil
		end
		sprintValueInstance = nil
		currentSprintMultiplier = 1
	end

	local function refreshSprintValue()
		disconnectSprintWatcher()

		local killerEntry = getMyKillerEntry()
		if not killerEntry then
			return
		end

		local speedFolder = killerEntry:FindFirstChild("SpeedMultipliers")
		if not speedFolder then
			return
		end

		local sprintVal = speedFolder:FindFirstChild("Sprinting")
		if sprintVal and (sprintVal:IsA("NumberValue") or sprintVal:IsA("IntValue")) then
			sprintValueInstance = sprintVal
			currentSprintMultiplier = tonumber(sprintVal.Value) or 1

			sprintValueConnection = sprintVal:GetPropertyChangedSignal("Value"):Connect(function()
				if not running then return end
				currentSprintMultiplier = tonumber(sprintVal.Value) or 1
			end)
		end
	end

	local function getCurrentSpeed()
		if sprintValueInstance and sprintValueInstance.Parent and sprintValueInstance.Value ~= nil then
			local mv = tonumber(sprintValueInstance.Value) or currentSprintMultiplier or 1
			return 8 * mv
		end

		if humanoid and humanoid.WalkSpeed then
			return humanoid.WalkSpeed
		end

		return 16
	end

	local function isNoDodgeBlocked()
		local killerEntry = getMyKillerEntry()
		if not killerEntry then
			return false
		end

		local speedFolder = killerEntry:FindFirstChild("SpeedMultipliers")
		if not speedFolder then
			return false
		end

		for _, child in ipairs(speedFolder:GetChildren()) do
			if NO_DODGE_SPEED_MULTIPLIERS[child.Name] then
				return true, child.Name
			end
		end

		return false
	end

	local function endActiveDodge(info)
		if not info or info.finished then
			return
		end

		info.finished = true

		if controller._activeDodge == info then
			controller._activeDodge = nil
		end

		if info.bv and info.bv.Parent then
			pcall(function()
				info.bv:Destroy()
			end)
		end

		if info.dieConn then
			pcall(function()
				info.dieConn:Disconnect()
			end)
		end

		if info.groundConn then
			pcall(function()
				info.groundConn:Disconnect()
			end)
		end

		if info.humanoid and info.humanoid.Parent then
			pcall(function()
				info.humanoid.AutoRotate = info.savedAutoRotate
			end)
		end
	end

	local function endActiveTurn(info)
		if not info or info.finished then
			return
		end

		info.finished = true

		if controller._activeTurn == info then
			controller._activeTurn = nil
		end

		if info.bg and info.bg.Parent then
			pcall(function()
				info.bg:Destroy()
			end)
		end

		if info.hbConn then
			pcall(function()
				info.hbConn:Disconnect()
			end)
		end

		if info.dieConn then
			pcall(function()
				info.dieConn:Disconnect()
			end)
		end

		if info.humanoid and info.humanoid.Parent then
			pcall(function()
				info.humanoid.AutoRotate = info.savedAutoRotate
			end)
		end
	end

	local function interruptActiveOverrides()
		if controller._activeDodge then
			endActiveDodge(controller._activeDodge)
		end

		if controller._activeTurn then
			endActiveTurn(controller._activeTurn)
		end
	end

	local function forceTurnOffIfNotKiller()
		if isCurrentlyKiller() then
			return
		end

		controller._pendingBackwardDodgeToken = nil
		interruptActiveOverrides()
		disconnectSprintWatcher()
	end

	local function performBackwardDodge(dodgeDuration, reasonText)
		refreshCharacter()
		if not char or not hrp or not humanoid then
			dbg("Dodge skipped: missing char/hrp/humanoid")
			return
		end

		if not isCurrentlyKiller() then
			dbg("Dodge skipped: not on any killer brick")
			forceTurnOffIfNotKiller()
			return
		end

		local blocked, blockedName = isNoDodgeBlocked()
		if blocked then
			dbg("Dodge blocked by", blockedName)
			return
		end

		local speed = getCurrentSpeed()
		if speed < MIN_SPEED_TO_TRIGGER then
			dbg("Dodge skipped: speed too low", speed)
			return
		end

		if type(DODGE_MAX_SPEED) == "number" then
			speed = math.min(speed, DODGE_MAX_SPEED)
		end

		local backward = getHorizontalUnit(-hrp.CFrame.LookVector)
		if not backward then
			dbg("Dodge skipped: no backward vector")
			return
		end

		interruptActiveOverrides()

		local humanoidRef = humanoid
		local hrpRef = hrp
		local charRef = char
		local savedAutoRotate = humanoidRef.AutoRotate

		humanoidRef.AutoRotate = false

		local currentY = 0
		pcall(function()
			currentY = hrpRef.AssemblyLinearVelocity.Y
		end)

		currentY = math.min(currentY, 0)

		local newVel = Vector3.new(backward.X * speed, currentY, backward.Z * speed)

		pcall(function()
			hrpRef.AssemblyLinearVelocity = newVel
		end)

		local bv = Instance.new("BodyVelocity")
		bv.Name = "AutoReflexBackwardDodge"
		bv.MaxForce = DODGE_FORCE_MAX
		bv.P = DODGE_FORCE_P
		bv.Velocity = newVel
		bv.Parent = hrpRef

		local info = nil

		local dieConn = humanoidRef.Died:Connect(function()
			if info then
				endActiveDodge(info)
			end
		end)

		local groundConn = RunService.Heartbeat:Connect(function()
			if not running or not info or info.finished then
				return
			end

			if hasGroundSupportFor(hrpRef, humanoidRef, charRef) then
				info.airLostAt = nil
				return
			end

			if not info.airLostAt then
				info.airLostAt = os.clock()
				return
			end

			if os.clock() - info.airLostAt >= AIR_CANCEL_GRACE then
				dbg("Dodge cut short: lost ground support")
				endActiveDodge(info)
			end
		end)

		info = {
			bv = bv,
			savedAutoRotate = savedAutoRotate,
			dieConn = dieConn,
			groundConn = groundConn,
			humanoid = humanoidRef,
			hrp = hrpRef,
			char = charRef,
			airLostAt = nil,
			finished = false,
		}

		controller._activeDodge = info

		dbg("DODGE FIRED", reasonText or "")

		task.delay(tonumber(dodgeDuration) or DODGE_DURATIONS.Default, function()
			if not running then return end
			endActiveDodge(info)
		end)
	end

	local function performInstantTurnTowardSurvivor(survivor, reasonText)
		refreshCharacter()
		if not char or not hrp or not humanoid then
			dbg("TwoTime turn skipped: missing char/hrp/humanoid")
			return
		end

		if not isCurrentlyKiller() then
			dbg("TwoTime turn skipped: not on any killer brick")
			forceTurnOffIfNotKiller()
			return
		end

		if not survivor or not survivor.Parent then
			dbg("TwoTime turn skipped: survivor missing")
			return
		end

		local sPos = getModelPosition(survivor)
		if not sPos then
			dbg("TwoTime turn skipped: no survivor position")
			return
		end

		local dist = (hrp.Position - sPos).Magnitude
		if dist > DODGE_RANGE then
			dbg("TwoTime turn skipped: out of range", dist)
			return
		end

		if os.clock() - lastDodgeTime < DODGE_COOLDOWN then
			dbg("TwoTime turn skipped: cooldown")
			return
		end

		local toward = getHorizontalUnit(sPos - hrp.Position)
		if not toward then
			dbg("TwoTime turn skipped: no turn vector")
			return
		end

		lastDodgeTime = os.clock()
		controller._pendingBackwardDodgeToken = nil

		local offsetSign = (math.random(0, 1) == 0) and -1 or 1
		local offsetDegrees = math.random(TWOTIME_TURN_MIN_OFFSET_DEGREES, TWOTIME_TURN_MAX_OFFSET_DEGREES) * offsetSign
		local fixedLook = rotateVectorAroundY(toward, math.rad(offsetDegrees))

		interruptActiveOverrides()

		local humanoidRef = humanoid
		local hrpRef = hrp
		local savedAutoRotate = humanoidRef.AutoRotate

		humanoidRef.AutoRotate = false

		local targetCFrame = CFrame.lookAt(hrpRef.Position, hrpRef.Position + fixedLook)

		pcall(function()
			hrpRef.CFrame = targetCFrame
			hrpRef.AssemblyAngularVelocity = Vector3.zero
			hrpRef.RotVelocity = Vector3.zero
		end)

		local bg = Instance.new("BodyGyro")
		bg.Name = "AutoReflexTwoTimeTurnHold"
		bg.MaxTorque = TWOTIME_TURN_GYRO_MAX_TORQUE
		bg.P = TWOTIME_TURN_GYRO_P
		bg.D = TWOTIME_TURN_GYRO_D
		bg.CFrame = targetCFrame
		bg.Parent = hrpRef

		local info = nil

		local hbConn = RunService.Heartbeat:Connect(function()
			if not running or not info or info.finished then
				return
			end

			if not hrpRef or not hrpRef.Parent or not bg or not bg.Parent then
				endActiveTurn(info)
				return
			end

			local pos = hrpRef.Position
			local fixed = CFrame.lookAt(pos, pos + fixedLook)

			pcall(function()
				hrpRef.CFrame = fixed
				hrpRef.AssemblyAngularVelocity = Vector3.zero
				hrpRef.RotVelocity = Vector3.zero
			end)

			bg.CFrame = fixed
		end)

		local dieConn = humanoidRef.Died:Connect(function()
			if info then
				endActiveTurn(info)
			end
		end)

		info = {
			bg = bg,
			hbConn = hbConn,
			dieConn = dieConn,
			humanoid = humanoidRef,
			savedAutoRotate = savedAutoRotate,
			finished = false,
		}

		controller._activeTurn = info

		dbg("TWOTIME TURN FIRED", reasonText or "", "offset:", offsetDegrees)

		task.delay(TWOTIME_TURN_HOLD, function()
			if not running then return end
			endActiveTurn(info)
		end)
	end

	local function scheduleTrackedBackwardDodge(survivor, delayTime, dodgeDuration, reasonText)
		refreshCharacter()
		if not hrp then
			dbg("Schedule skipped: no HRP")
			return
		end

		if not isCurrentlyKiller() then
			dbg("Schedule skipped: not on any killer brick")
			forceTurnOffIfNotKiller()
			return
		end

		local blocked, blockedName = isNoDodgeBlocked()
		if blocked then
			dbg("Schedule blocked by", blockedName)
			return
		end

		local sPos = getModelPosition(survivor)
		if not sPos then
			dbg("Schedule skipped: no survivor position for", survivor and survivor.Name or "nil")
			return
		end

		local dist = (hrp.Position - sPos).Magnitude
		if dist > DODGE_RANGE then
			dbg("Schedule skipped: out of range", survivor.Name, dist)
			return
		end

		if os.clock() - lastDodgeTime < DODGE_COOLDOWN then
			dbg("Schedule skipped: cooldown")
			return
		end

		lastDodgeTime = os.clock()

		local token = tostring(os.clock()) .. "_" .. tostring(math.random(1000, 9999))
		controller._pendingBackwardDodgeToken = token

		dbg("Trigger detected for", survivor.Name, "reason:", reasonText or "unknown", "dist:", math.floor(dist))

		task.delay(tonumber(delayTime) or 0, function()
			if not running then return end
			if controller._pendingBackwardDodgeToken ~= token then return end
			controller._pendingBackwardDodgeToken = nil

			refreshCharacter()
			if not hrp or not humanoid then
				dbg("Delayed dodge cancelled: no char/hrp/humanoid")
				return
			end

			if not survivor or not survivor.Parent then
				dbg("Delayed dodge cancelled: survivor missing")
				return
			end

			if not isCurrentlyKiller() then
				dbg("Delayed dodge cancelled: no killer brick found")
				forceTurnOffIfNotKiller()
				return
			end

			local blockedNow, blockedNameNow = isNoDodgeBlocked()
			if blockedNow then
				dbg("Delayed dodge cancelled by", blockedNameNow)
				return
			end

			local latestPos = getModelPosition(survivor)
			if not latestPos then
				dbg("Delayed dodge cancelled: latest pos missing")
				return
			end

			if (hrp.Position - latestPos).Magnitude > DODGE_RANGE then
				dbg("Delayed dodge cancelled: moved out of range")
				return
			end

			performBackwardDodge(dodgeDuration, reasonText)
		end)
	end

	local function handleResistanceSurvivor(survivor)
		if not survivor or not TARGET_NAMES[survivor.Name] then return end
		if survivor.Name == "Chance" then return end

		local resistanceFolder = survivor:FindFirstChild(RESISTANCE_FOLDER_NAME)
		local resistanceValue = resistanceFolder and resistanceFolder:FindFirstChild(RESISTANCE_VALUE_NAME)

		local currentValue = nil
		if resistanceValue and (resistanceValue:IsA("IntValue") or resistanceValue:IsA("NumberValue")) then
			currentValue = tonumber(resistanceValue.Value)
		end

		local prevValue = resistanceState[survivor]
		resistanceState[survivor] = currentValue

		if currentValue and TRIGGER_VALUES[currentValue] and prevValue ~= currentValue then
			if survivor.Name == "TwoTime" then
				performInstantTurnTowardSurvivor(
					survivor,
					survivor.Name .. " ResistanceStatus = " .. tostring(currentValue)
				)
			else
				scheduleTrackedBackwardDodge(
					survivor,
					DODGE_DELAYS[survivor.Name] or 0,
					getDodgeDurationForSurvivor(survivor.Name),
					survivor.Name .. " ResistanceStatus = " .. tostring(currentValue)
				)
			end
		end
	end

	local function handleChanceSurvivor(survivor)
		if not survivor or survivor.Name ~= "Chance" then return end

		local speedFolder = survivor:FindFirstChild("SpeedMultipliers")
		local hasShootingGun = speedFolder and speedFolder:FindFirstChild("ShootingGun") ~= nil

		local prev = chanceState[survivor]
		chanceState[survivor] = hasShootingGun

		if hasShootingGun and not prev then
			scheduleTrackedBackwardDodge(
				survivor,
				DODGE_DELAYS.Chance or 0,
				getDodgeDurationForSurvivor("Chance"),
				"Chance ShootingGun"
			)
		end
	end

	local function scanSurvivors()
		local survivorsFolder = findSurvivorsFolder()
		if not survivorsFolder then
			return
		end

		local seen = {}

		for _, survivor in ipairs(survivorsFolder:GetChildren()) do
			if TARGET_NAMES[survivor.Name] then
				seen[survivor] = true

				if survivor.Name == "Chance" then
					handleChanceSurvivor(survivor)
				else
					handleResistanceSurvivor(survivor)
				end
			end
		end

		for survivor, _ in pairs(resistanceState) do
			if not seen[survivor] or survivor.Parent == nil then
				resistanceState[survivor] = nil
			end
		end

		for survivor, _ in pairs(chanceState) do
			if not seen[survivor] or survivor.Parent == nil then
				chanceState[survivor] = nil
			end
		end
	end

	table.insert(connections, LocalPlayer.CharacterAdded:Connect(function()
		task.delay(0.05, function()
			if not running then return end
			refreshCharacter()
			refreshSprintValue()
		end)
	end))

	refreshCharacter()
	refreshSprintValue()

	table.insert(connections, RunService.Heartbeat:Connect(function(dt)
		if not running then return end

		pollAccum += dt
		if pollAccum < POLL_INTERVAL then
			return
		end
		pollAccum = 0

		refreshCharacter()

		local killerPresent = isCurrentlyKiller()
		if not killerPresent and lastKillerPresent then
			dbg("No killer brick found anymore; reflex turning off")
			forceTurnOffIfNotKiller()
		elseif killerPresent and not lastKillerPresent then
			dbg("Killer brick found; reflex enabled")
			refreshSprintValue()
		end
		lastKillerPresent = killerPresent

		if not killerPresent then
			lastBlockedState = false
			return
		end

		if sprintValueInstance and sprintValueInstance.Parent == nil then
			refreshSprintValue()
		end

		local blocked = isNoDodgeBlocked()
		if blocked and not lastBlockedState then
			dbg("Blocked state entered")
			controller._pendingBackwardDodgeToken = nil
			interruptActiveOverrides()
		end
		lastBlockedState = blocked and true or false

		scanSurvivors()
	end))

	local function cleanup()
		running = false

		for _, conn in ipairs(connections) do
			pcall(function()
				conn:Disconnect()
			end)
		end
		connections = {}

		disconnectSprintWatcher()

		controller._pendingBackwardDodgeToken = nil
		resistanceState = {}
		chanceState = {}

		interruptActiveOverrides()

		if _G.AutoReflexController == controller then
			_G.AutoReflexController = nil
		end

		controller.Cleanup = nil
	end

	controller.Cleanup = cleanup

	function controller.TriggerDodgeNow()
		performBackwardDodge(DODGE_DURATIONS.Default, "manual trigger function")
	end

	dbg("Polling reflex script running.")
end
