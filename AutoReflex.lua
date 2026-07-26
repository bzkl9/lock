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
	local DODGE_FORCE_MAX = Vector3.new(1e5, 1e5, 1e5)
	local DODGE_MAX_SPEED = 21
	local POLL_INTERVAL = 0.03

	local GROUND_RAY_HEIGHT = 2.5
	local GROUND_RAY_DISTANCE = 6
	local DODGE_GROUND_PROBE_PADDING = 1.25
	local DODGE_GROUND_LOOKAHEAD = 1.25
	local DODGE_GROUND_STICK_SPEED = 1.5
	local DODGE_MAX_VERTICAL_SPEED = 18

	local TWOTIME_TURN_MIN_OFFSET_DEGREES = 8
	local TWOTIME_TURN_MAX_OFFSET_DEGREES = 20
	local TWOTIME_TURN_HOLD = 0.5
	local TWOTIME_TURN_GYRO_P = 1e6
	local TWOTIME_TURN_GYRO_D = 1
	local TWOTIME_TURN_GYRO_MAX_TORQUE = Vector3.new(1e8, 1e8, 1e8)

	local DODGE_DELAYS = {
		Shedletsky = 0.2,
		JaneDoe = 0.1,
		Chance = 0.8,
	}

	local DODGE_DURATIONS = {
		Default = 0.35,
		Shedletsky = 0.3,
		JaneDoe = 0.4,
		Chance = 0.4,
	}

	local TRIGGER_RANGES = {
		Default = DODGE_RANGE,
		Chance = 50,
	}

	local CHANCE_TRIGGER_ANIMATION_ID = "133491532453922"
	local JANE_ATTACK_RANGE = 13

	local SMART_DODGE_MIN_DISTANCE = 5
	local SMART_DODGE_SIDE_OFFSET = 1.1
	local SMART_DODGE_MIN_CLEARANCE = 1.25
	local SMART_DODGE_HEIGHT_SAMPLES = {1.4, 2.8, 4.2}

	local DODGE_POPUP_GUI_NAME = "AutoReflexDodgeGui"
	local DODGE_POPUP_TEXT = "DODGING"

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

	local dodgeGui = nil
	local dodgeLabel = nil

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
		if typeof(vec) ~= "Vector3" then
			return nil
		end
		local flat = Vector3.new(vec.X, 0, vec.Z)
		if flat.Magnitude < 0.001 then
			return nil
		end
		return flat.Unit
	end

	local function getPerpendicularUnit(vec)
		local unit = getHorizontalUnit(vec)
		if not unit then
			return nil
		end
		return Vector3.new(-unit.Z, 0, unit.X)
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

	local function buildRaycastParams(charRef)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = charRef and {charRef} or {}
		return params
	end

	local function hasGroundSupportAtPosition(position, charRef)
		local params = buildRaycastParams(charRef)
		local origin = position + Vector3.new(0, GROUND_RAY_HEIGHT, 0)
		local direction = Vector3.new(0, -(GROUND_RAY_HEIGHT + GROUND_RAY_DISTANCE), 0)
		local result = Workspace:Raycast(origin, direction, params)
		return result ~= nil
	end

	local function hasGroundSupportFor(hrpRef, humanoidRef, charRef)
		if not hrpRef or not hrpRef.Parent or not humanoidRef or not humanoidRef.Parent then
			return false
		end

		if humanoidRef.FloorMaterial and humanoidRef.FloorMaterial ~= Enum.Material.Air then
			return true
		end

		return hasGroundSupportAtPosition(hrpRef.Position, charRef)
	end

	local function getDodgeGroundHit(hrpRef, humanoidRef, charRef, moveDir)
		if not hrpRef or not hrpRef.Parent or not humanoidRef or not humanoidRef.Parent then
			return nil
		end

		local rootHalfHeight = hrpRef.Size.Y * 0.5
		local rootToFloor = math.max(0, humanoidRef.HipHeight) + rootHalfHeight
		local maxGroundGap = rootToFloor + DODGE_GROUND_PROBE_PADDING
		local castLift = 0.5
		local params = buildRaycastParams(charRef)

		local function castDown(position)
			local origin = position + Vector3.new(0, castLift, 0)
			local result = Workspace:Raycast(
				origin,
				Vector3.new(0, -(castLift + maxGroundGap), 0),
				params
			)

			if result and position.Y - result.Position.Y <= maxGroundGap then
				return result
			end

			return nil
		end

		local currentHit = castDown(hrpRef.Position)
		if not currentHit then
			return nil
		end

		local forwardHit = castDown(hrpRef.Position + moveDir * DODGE_GROUND_LOOKAHEAD)
		return forwardHit or currentHit
	end

	local function getGroundFollowingVelocity(moveDir, speed, groundNormal)
		local normal = groundNormal
		if typeof(normal) ~= "Vector3" or normal.Magnitude < 0.001 then
			normal = Vector3.new(0, 1, 0)
		else
			normal = normal.Unit
		end

		local alongGround = moveDir - normal * moveDir:Dot(normal)
		if alongGround.Magnitude < 0.001 then
			alongGround = moveDir
		else
			alongGround = alongGround.Unit
		end

		local velocity = alongGround * speed
		local vertical = math.clamp(
			velocity.Y - DODGE_GROUND_STICK_SPEED,
			-DODGE_MAX_VERTICAL_SPEED,
			DODGE_MAX_VERTICAL_SPEED
		)

		return Vector3.new(velocity.X, vertical, velocity.Z)
	end

	local function extractAnimationId(rawId)
		if typeof(rawId) ~= "string" then
			return nil
		end
		return rawId:match("(%d+)")
	end

	local function getHumanoidFromModel(model)
		if not model then return nil end
		return model:FindFirstChildOfClass("Humanoid") or model:FindFirstChild("Humanoid")
	end

	local function isAnimationPlaying(model, targetAnimationId)
		local hum = getHumanoidFromModel(model)
		if not hum then
			return false
		end

		local ok, tracks = pcall(function()
			return hum:GetPlayingAnimationTracks()
		end)

		if not ok or not tracks then
			return false
		end

		local targetId = tostring(targetAnimationId)
		for _, track in ipairs(tracks) do
			local anim = track.Animation
			local animId = anim and extractAnimationId(anim.AnimationId)
			if animId == targetId then
				return true
			end
		end

		return false
	end

	local function getPlayerGui()
		local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if pg then
			return pg
		end

		local ok, result = pcall(function()
			return LocalPlayer:WaitForChild("PlayerGui", 2)
		end)

		if ok then
			return result
		end

		return nil
	end

	local function ensureDodgeGui()
		local playerGui = getPlayerGui()
		if not playerGui then
			return nil, nil
		end

		if dodgeGui and dodgeGui.Parent == playerGui and dodgeLabel and dodgeLabel.Parent == dodgeGui then
			return dodgeGui, dodgeLabel
		end

		local existing = playerGui:FindFirstChild(DODGE_POPUP_GUI_NAME)
		if existing and existing:IsA("ScreenGui") then
			local existingLabel = existing:FindFirstChild("DodgeText")
			if existingLabel and existingLabel:IsA("TextLabel") then
				dodgeGui = existing
				dodgeLabel = existingLabel
				return dodgeGui, dodgeLabel
			end

			pcall(function()
				existing:Destroy()
			end)
		end

		local gui = Instance.new("ScreenGui")
		gui.Name = DODGE_POPUP_GUI_NAME
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = 99999
		gui.Enabled = false
		gui.Parent = playerGui

		local label = Instance.new("TextLabel")
		label.Name = "DodgeText"
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.new(0.5, 0, 0.28, 0)
		label.Size = UDim2.new(0, 320, 0, 70)
		label.BackgroundTransparency = 1
		label.BorderSizePixel = 0
		label.Text = DODGE_POPUP_TEXT
		label.TextScaled = true
		label.Font = Enum.Font.GothamBlack
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.Visible = false
		label.Parent = gui

		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 3
		stroke.Color = Color3.fromRGB(0, 0, 0)
		stroke.Parent = label

		dodgeGui = gui
		dodgeLabel = label
		return dodgeGui, dodgeLabel
	end

	local function setDodgePopupVisible(isVisible)
		local gui, label = ensureDodgeGui()
		if not gui or not label then
			return
		end

		label.Text = DODGE_POPUP_TEXT
		label.Visible = isVisible and true or false
		gui.Enabled = isVisible and true or false
	end

	local function getDodgeDurationForSurvivor(name)
		if name and DODGE_DURATIONS[name] then
			return DODGE_DURATIONS[name]
		end
		return DODGE_DURATIONS.Default
	end

	local function getTriggerRangeForSurvivor(name)
		if name and TRIGGER_RANGES[name] then
			return TRIGGER_RANGES[name]
		end
		return TRIGGER_RANGES.Default
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

		-- Do not keep upward momentum created while following an uphill slope.
		if info.hrp and info.hrp.Parent then
			pcall(function()
				local velocity = info.hrp.AssemblyLinearVelocity
				if velocity.Y > 0 then
					info.hrp.AssemblyLinearVelocity = Vector3.new(
						velocity.X,
						0,
						velocity.Z
					)
				end
			end)
		end

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

		setDodgePopupVisible(false)
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

		controller._pendingDodgeToken = nil
		interruptActiveOverrides()
		disconnectSprintWatcher()
	end

	local function estimateDirectionClearance(originPos, dir, travelDistance, charRef)
		local moveDir = getHorizontalUnit(dir)
		if not moveDir then
			return 0
		end

		local params = buildRaycastParams(charRef)
		local clearance = travelDistance
		local perp = getPerpendicularUnit(moveDir)

		for _, height in ipairs(SMART_DODGE_HEIGHT_SAMPLES) do
			local baseOrigin = originPos + Vector3.new(0, height, 0)
			local origins = {baseOrigin}

			if perp then
				table.insert(origins, baseOrigin + perp * SMART_DODGE_SIDE_OFFSET)
				table.insert(origins, baseOrigin - perp * SMART_DODGE_SIDE_OFFSET)
			end

			for _, rayOrigin in ipairs(origins) do
				local result = Workspace:Raycast(rayOrigin, moveDir * travelDistance, params)
				if result and result.Distance < clearance then
					clearance = result.Distance
				end
			end
		end

		return clearance
	end

	local function distancePointToSegmentXZ(point, segA, segB)
		local p = Vector3.new(point.X, 0, point.Z)
		local a = Vector3.new(segA.X, 0, segA.Z)
		local b = Vector3.new(segB.X, 0, segB.Z)

		local ab = b - a
		local abLenSq = ab:Dot(ab)
		if abLenSq <= 1e-6 then
			return (p - a).Magnitude
		end

		local t = math.clamp((p - a):Dot(ab) / abLenSq, 0, 1)
		local closest = a + ab * t
		return (p - closest).Magnitude
	end

	local function chooseBestDodgeDirection(hrpRef, charRef, candidateDirs, travelDistance, extraScoreFn)
		local bestDir = nil
		local bestScore = nil
		local fallbackDir = nil

		for index, candidate in ipairs(candidateDirs) do
			local unit = getHorizontalUnit(candidate)
			if unit then
				if not fallbackDir then
					fallbackDir = unit
				end

				local clearance = estimateDirectionClearance(hrpRef.Position, unit, travelDistance, charRef)
				local moveDistance = math.min(clearance, travelDistance)
				local targetPos = hrpRef.Position + unit * moveDistance
				local grounded = hasGroundSupportAtPosition(targetPos, charRef)

				local score = moveDistance
				score += math.max(0, (#candidateDirs - index)) * 0.75

				if grounded then
					score += 3
				else
					score -= 50
				end

				if clearance < SMART_DODGE_MIN_CLEARANCE then
					score -= 100
				end

				if type(extraScoreFn) == "function" then
					local ok, extra = pcall(extraScoreFn, unit, moveDistance, clearance, targetPos)
					if ok and type(extra) == "number" then
						score += extra
					end
				end

				if not bestScore or score > bestScore then
					bestScore = score
					bestDir = unit
				end
			end
		end

		return bestDir or fallbackDir
	end

	local function performDirectionalDodge(direction, dodgeDuration, reasonText)
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

		local moveDir = getHorizontalUnit(direction)
		if not moveDir then
			dbg("Dodge skipped: invalid move direction")
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

		interruptActiveOverrides()

		local humanoidRef = humanoid
		local hrpRef = hrp
		local charRef = char
		local savedAutoRotate = humanoidRef.AutoRotate

		humanoidRef.AutoRotate = false

		local initialGroundHit = getDodgeGroundHit(hrpRef, humanoidRef, charRef, moveDir)
		local newVel

		if initialGroundHit then
			newVel = getGroundFollowingVelocity(moveDir, speed, initialGroundHit.Normal)
		else
			local currentY = 0
			pcall(function()
				currentY = hrpRef.AssemblyLinearVelocity.Y
			end)
			newVel = Vector3.new(moveDir.X * speed, math.min(currentY, 0), moveDir.Z * speed)
		end

		pcall(function()
			hrpRef.AssemblyLinearVelocity = newVel
		end)

		local bv = Instance.new("BodyVelocity")
		bv.Name = "AutoReflexDirectionalDodge"
		bv.MaxForce = initialGroundHit
			and DODGE_FORCE_MAX
			or Vector3.new(DODGE_FORCE_MAX.X, 0, DODGE_FORCE_MAX.Z)
		bv.P = DODGE_FORCE_P
		bv.Velocity = newVel
		bv.Parent = hrpRef

		setDodgePopupVisible(true)

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

			local groundHit = getDodgeGroundHit(hrpRef, humanoidRef, charRef, moveDir)
			if groundHit then
				info.airLostAt = nil
				bv.MaxForce = DODGE_FORCE_MAX
				bv.Velocity = getGroundFollowingVelocity(moveDir, speed, groundHit.Normal)
				return
			end

			if not info.airLostAt then
				info.airLostAt = os.clock()

				-- Cancel upward slope momentum once, but do not end the dodge.
				pcall(function()
					local velocity = hrpRef.AssemblyLinearVelocity
					if velocity.Y > 0 then
						hrpRef.AssemblyLinearVelocity = Vector3.new(
							velocity.X,
							0,
							velocity.Z
						)
					end
				end)
			end

			-- Preserve the full requested dodge duration. Only Y control is
			-- released here, so Roblox gravity resumes while X/Z keeps dodging.
			bv.MaxForce = Vector3.new(DODGE_FORCE_MAX.X, 0, DODGE_FORCE_MAX.Z)
			bv.Velocity = Vector3.new(moveDir.X * speed, 0, moveDir.Z * speed)
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

	local function performBackwardDodge(dodgeDuration, reasonText)
		refreshCharacter()
		if not hrp then
			dbg("Backward dodge skipped: no HRP")
			return
		end

		local backward = getHorizontalUnit(-hrp.CFrame.LookVector)
		if not backward then
			dbg("Backward dodge skipped: no backward vector")
			return
		end

		performDirectionalDodge(backward, dodgeDuration, reasonText)
	end

	local function chooseSmartDodgeDirectionForSurvivor(survivor, dodgeDuration, mode)
		refreshCharacter()
		if not char or not hrp then
			return nil
		end

		local sPos = getModelPosition(survivor)
		if not sPos then
			return nil
		end

		local root = getModelRootPart(survivor)

		local speed = getCurrentSpeed()
		if type(DODGE_MAX_SPEED) == "number" then
			speed = math.min(speed, DODGE_MAX_SPEED)
		end

		local travelDistance = math.max(
			SMART_DODGE_MIN_DISTANCE,
			speed * (tonumber(dodgeDuration) or DODGE_DURATIONS.Default)
		)

		local awayFromSurvivor = getHorizontalUnit(hrp.Position - sPos)
		local backward = getHorizontalUnit(-hrp.CFrame.LookVector)
		local forward = getHorizontalUnit(hrp.CFrame.LookVector)

		local candidateDirs = {}
		local extraScoreFn = nil

		local function pushDir(vec)
			local unit = getHorizontalUnit(vec)
			if unit then
				table.insert(candidateDirs, unit)
			end
		end

		if mode == "chance_beam" then
			local beamDir = getHorizontalUnit(root and root.CFrame.LookVector or nil)
			if not beamDir then
				beamDir = getHorizontalUnit(sPos - hrp.Position) or forward or backward
			end

			local beamSide = getPerpendicularUnit(beamDir)

			pushDir(beamSide)
			if beamSide then pushDir(-beamSide) end
			pushDir(awayFromSurvivor)
			pushDir(backward)
			if beamDir then pushDir(-beamDir) end
			pushDir(forward)
			if awayFromSurvivor then pushDir(-awayFromSurvivor) end
		elseif mode == "jane_aim" then
			local attackDir = getHorizontalUnit(root and root.CFrame.LookVector or nil)
			if not attackDir then
				attackDir = getHorizontalUnit(sPos - hrp.Position) or awayFromSurvivor or backward or forward
			end

			local attackSide = getPerpendicularUnit(attackDir)
			local attackStart = sPos
			local attackEnd = sPos + attackDir * JANE_ATTACK_RANGE

			pushDir(attackSide)
			if attackSide then pushDir(-attackSide) end
			pushDir(-attackDir)
			pushDir(awayFromSurvivor)
			pushDir(backward)
			pushDir(forward)
			if awayFromSurvivor then pushDir(-awayFromSurvivor) end
			pushDir(attackDir)

			extraScoreFn = function(unit, moveDistance, clearance, targetPos)
				local laneDistance = distancePointToSegmentXZ(targetPos, attackStart, attackEnd)
				local currentLaneDistance = distancePointToSegmentXZ(hrp.Position, attackStart, attackEnd)
				local score = laneDistance * 12

				if laneDistance > currentLaneDistance then
					score += 14
				end

				if laneDistance <= 1.0 then
					score -= 150
				elseif laneDistance <= 2.0 then
					score -= 60
				end

				if getHorizontalUnit(unit) and attackSide then
					local sideDot = math.abs(unit:Dot(attackSide))
					score += sideDot * 12
				end

				if attackDir then
					local backDot = unit:Dot(-attackDir)
					score += math.max(0, backDot) * 4
				end

				if clearance < SMART_DODGE_MIN_CLEARANCE then
					score -= 50
				end

				return score
			end
		else
			local side = getPerpendicularUnit(awayFromSurvivor or backward or forward)

			pushDir(awayFromSurvivor)
			if side then
				pushDir(side)
				pushDir(-side)
			end
			pushDir(backward)
			pushDir(forward)
			if awayFromSurvivor then pushDir(-awayFromSurvivor) end
		end

		return chooseBestDodgeDirection(hrp, char, candidateDirs, travelDistance, extraScoreFn)
			or awayFromSurvivor
			or backward
			or forward
	end

	local function performSmartSurvivorDodge(survivor, dodgeDuration, reasonText, mode)
		local chosenDir = chooseSmartDodgeDirectionForSurvivor(survivor, dodgeDuration, mode)
		if not chosenDir then
			dbg("Smart dodge skipped: no direction found for", survivor and survivor.Name or "nil")
			return
		end

		performDirectionalDodge(chosenDir, dodgeDuration, reasonText)
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
		if dist > getTriggerRangeForSurvivor(survivor.Name) then
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
		controller._pendingDodgeToken = nil

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

	local function scheduleTrackedDodge(survivor, delayTime, dodgeDuration, reasonText, triggerRange, dodgeExecutor)
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

		local allowedRange = tonumber(triggerRange) or DODGE_RANGE
		local dist = (hrp.Position - sPos).Magnitude
		if dist > allowedRange then
			dbg("Schedule skipped: out of range", survivor.Name, dist)
			return
		end

		if os.clock() - lastDodgeTime < DODGE_COOLDOWN then
			dbg("Schedule skipped: cooldown")
			return
		end

		lastDodgeTime = os.clock()

		local token = tostring(os.clock()) .. "_" .. tostring(math.random(1000, 9999))
		controller._pendingDodgeToken = token

		dbg("Trigger detected for", survivor.Name, "reason:", reasonText or "unknown", "dist:", math.floor(dist))

		task.delay(tonumber(delayTime) or 0, function()
			if not running then return end
			if controller._pendingDodgeToken ~= token then return end
			controller._pendingDodgeToken = nil

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

			if (hrp.Position - latestPos).Magnitude > allowedRange then
				dbg("Delayed dodge cancelled: moved out of range")
				return
			end

			if type(dodgeExecutor) == "function" then
				dodgeExecutor(survivor, dodgeDuration, reasonText)
			end
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
			elseif survivor.Name == "JaneDoe" then
				scheduleTrackedDodge(
					survivor,
					DODGE_DELAYS.JaneDoe or 0,
					getDodgeDurationForSurvivor("JaneDoe"),
					survivor.Name .. " ResistanceStatus = " .. tostring(currentValue),
					getTriggerRangeForSurvivor("JaneDoe"),
					function(target, duration, text)
						performSmartSurvivorDodge(target, duration, text, "jane_aim")
					end
				)
			else
				scheduleTrackedDodge(
					survivor,
					DODGE_DELAYS[survivor.Name] or 0,
					getDodgeDurationForSurvivor(survivor.Name),
					survivor.Name .. " ResistanceStatus = " .. tostring(currentValue),
					getTriggerRangeForSurvivor(survivor.Name),
					function(_, duration, text)
						performBackwardDodge(duration, text)
					end
				)
			end
		end
	end

	local function handleChanceSurvivor(survivor)
		if not survivor or survivor.Name ~= "Chance" then return end

		local isTriggerPlayingNow = isAnimationPlaying(survivor, CHANCE_TRIGGER_ANIMATION_ID)

		local prev = chanceState[survivor]
		chanceState[survivor] = isTriggerPlayingNow

		if isTriggerPlayingNow and not prev then
			scheduleTrackedDodge(
				survivor,
				DODGE_DELAYS.Chance or 0,
				getDodgeDurationForSurvivor("Chance"),
				"Chance animation " .. CHANCE_TRIGGER_ANIMATION_ID,
				getTriggerRangeForSurvivor("Chance"),
				function(target, duration, text)
					performSmartSurvivorDodge(target, duration, text, "chance_beam")
				end
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
			ensureDodgeGui()
			setDodgePopupVisible(false)
		end)
	end))

	refreshCharacter()
	refreshSprintValue()
	ensureDodgeGui()
	setDodgePopupVisible(false)

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
			controller._pendingDodgeToken = nil
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

		controller._pendingDodgeToken = nil
		resistanceState = {}
		chanceState = {}

		interruptActiveOverrides()
		setDodgePopupVisible(false)

		if dodgeGui and dodgeGui.Parent then
			pcall(function()
				dodgeGui:Destroy()
			end)
		end
		dodgeGui = nil
		dodgeLabel = nil

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
