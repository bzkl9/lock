do
local RunService = game:GetService("RunService")
local PlayersService = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local workspace = workspace

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

local DODGE_OBSTACLE_CHECK_DISTANCE = 5
local CHANCE_SECONDARY_WEIGHT = 0.75

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

local FACE_OVERRIDE_DURATION = 0.5

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
    local node = workspace
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
    local sum = Vector3.new(0,0,0)
    local count = 0
    for _, desc in ipairs(model:GetDescendants()) do
        if desc:IsA("BasePart") then
            sum = sum + desc.Position
            count = count + 1
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

    local playersNode = workspace:FindFirstChild("Players")
    if not playersNode then return end
    local killersFolder = playersNode:FindFirstChild("Killers")
    if not killersFolder then return end
    local myKillerEntry = killersFolder:FindFirstChild(LocalPlayer.Name)
    if not myKillerEntry then
        local conn = killersFolder.ChildAdded:Connect(function(child)
            if not running then conn:Disconnect(); return end
            if child.Name == LocalPlayer.Name then
                conn:Disconnect()
                delay(0.05, locateAndWatchSprintValue)
            end
        end)
        connections[#connections+1] = conn
        return
    end

    local speedMultFolder = myKillerEntry:FindFirstChild("SpeedMultipliers")
    if not speedMultFolder then
        local conn = myKillerEntry.ChildAdded:Connect(function(child)
            if not running then return end
            if child.Name == "SpeedMultipliers" then
                delay(0.05, locateAndWatchSprintValue)
            end
        end)
        connections[#connections+1] = conn
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
        connections[#connections+1] = conn
    else
        local conn2 = speedMultFolder.ChildAdded:Connect(function(child)
            if not running then return end
            if child.Name == "Sprinting" and (child:IsA("NumberValue") or child:IsA("IntValue")) then
                delay(0.02, locateAndWatchSprintValue)
            end
        end)
        connections[#connections+1] = conn2
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
    local playersNode = workspace:FindFirstChild("Players")
    if playersNode then
        local killers = playersNode:FindFirstChild("Killers")
        if killers and killers:FindFirstChild(LocalPlayer.Name) then
            return true
        end
    end
    return false
end

local TURN_SPEED_REDUCTION = 0.30
local TURN_PENALTY_DURATION = 0.5

local function getMySpeedMultipliersFolder()
    local playersNode = workspace:FindFirstChild("Players")
    if not playersNode then return nil end
    local killersFolder = playersNode:FindFirstChild("Killers")
    if not killersFolder then return nil end
    local myEntry = killersFolder:FindFirstChild(LocalPlayer.Name)
    if not myEntry then return nil end
    return myEntry:FindFirstChild("SpeedMultipliers")
end

local function applyDirectionalPenalty(multipliedValue)
    local folder = getMySpeedMultipliersFolder()
    if not folder then return false end
    local dirVal = folder:FindFirstChild("DirectionalMovement")
    if not dirVal or not (dirVal:IsA("NumberValue") or dirVal:IsA("IntValue")) then return false end

    local orig = dirVal.Value
    pcall(function() dirVal.Value = multipliedValue end)

    controller._activeTurn = controller._activeTurn or {}
    if controller._activeTurn.dirDieConn then
        pcall(function() controller._activeTurn.dirDieConn:Disconnect() end)
    end
    controller._activeTurn.dirVal = dirVal
    controller._activeTurn.origDirectional = orig
    return true
end

local function restoreDirectionalPenalty()
    if not controller._activeTurn then return end
    local t = controller._activeTurn
    controller._activeTurn = nil
    if t and t.dirVal and t.dirVal.Parent then
        pcall(function() t.dirVal.Value = t.origDirectional end)
    end
    if t and t.dirDieConn then
        pcall(function() t.dirDieConn:Disconnect() end)
    end
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
            if info.dieConn then info.dieConn:Disconnect() end
        end)
        pcall(function()
            if humanoid then
                humanoid.AutoRotate = info.savedAutoRotate
            end
        end)
    end

    if controller._activeFace then
        local info = controller._activeFace
        controller._activeFace = nil
        pcall(function()
            if info.bg and info.bg.Parent then
                info.bg:Destroy()
            end
        end)
        pcall(function()
            if info.hbConn then info.hbConn:Disconnect() end
        end)
        pcall(function()
            if info.dieConn then info.dieConn:Disconnect() end
        end)
        pcall(function()
            if humanoid and info.savedAutoRotate ~= nil then
                humanoid.AutoRotate = info.savedAutoRotate
            end
        end)
    end

    restoreDirectionalPenalty()
end

local function buildRayParams()
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Blacklist
    params.FilterDescendantsInstances = {char}
    params.IgnoreWater = true
    return params
end

local function getCardinalDirections()
    if not hrp then return nil end
    local forward = getHorizontalUnit(hrp.CFrame.LookVector)
    local right = getHorizontalUnit(hrp.CFrame.RightVector)
    if not forward or not right then return nil end
    return {
        Forward = forward,
        Backward = -forward,
        Right = right,
        Left = -right,
    }
end

local function isDirectionBlocked(dir)
    if not hrp then return true end
    local params = buildRayParams()
    local hit = workspace:Raycast(hrp.Position, dir * DODGE_OBSTACLE_CHECK_DISTANCE, params)
    return hit ~= nil
end

local function getSurvivorFacingDir(survivor)
    local root = getModelRootPart(survivor)
    if not root then return nil end
    return getHorizontalUnit(root.CFrame.LookVector)
end

local function getSurvivorRelativeDir(survivor)
    local sPos = getModelPosition(survivor)
    if not sPos or not hrp then return nil end
    return getHorizontalUnit(sPos - hrp.Position)
end

local function scoreDodgeDirection(survivor, dir)
    local score = 0

    if isDirectionBlocked(dir) then
        score = score + 1000
    end

    local relDir = getSurvivorRelativeDir(survivor)
    local facingDir = getSurvivorFacingDir(survivor)

    if relDir then
        local towardSurvivor = relDir:Dot(dir)
        if towardSurvivor > 0 then
            score = score + towardSurvivor * 220
        else
            score = score + towardSurvivor * 20
        end
    end

    if facingDir then
        local alignment = math.abs(facingDir:Dot(dir))
        score = score + alignment * 260

        local intoFacing = facingDir:Dot(dir)
        if intoFacing > 0 then
            score = score + intoFacing * 140
        end
    end

    if relDir and facingDir then
        local positionPressure = math.max(0, relDir:Dot(dir))
        local facingPressure = math.abs(facingDir:Dot(dir))
        score = score + (positionPressure * facingPressure) * 120
    end

    return score
end

local function chooseBestAdaptiveDirection(survivor, allowedNames)
    local dirs = getCardinalDirections()
    if not dirs then return nil end

    local candidates = {}
    if allowedNames then
        for _, name in ipairs(allowedNames) do
            if dirs[name] then
                table.insert(candidates, {name = name, dir = dirs[name]})
            end
        end
    else
        for name, dir in pairs(dirs) do
            table.insert(candidates, {name = name, dir = dir})
        end
    end

    local best = nil
    local bestScore = math.huge

    for _, entry in ipairs(candidates) do
        local s = scoreDodgeDirection(survivor, entry.dir)
        if s < bestScore then
            bestScore = s
            best = entry
        end
    end

    return best
end

local function chooseBestPerpendicularDirection(survivor, primaryName)
    if primaryName == "Left" or primaryName == "Right" then
        return chooseBestAdaptiveDirection(survivor, {"Forward", "Backward"})
    elseif primaryName == "Forward" or primaryName == "Backward" then
        return chooseBestAdaptiveDirection(survivor, {"Left", "Right"})
    end
    return nil
end

local function applyPostDodgePenalty(info)
    local applied = false
    local folder = getMySpeedMultipliersFolder()
    if folder then
        local dirVal = folder:FindFirstChild("DirectionalMovement")
        if dirVal and (dirVal:IsA("NumberValue") or dirVal:IsA("IntValue")) then
            local orig = dirVal.Value or 1
            local newVal = math.max(0.01, orig * (1 - TURN_SPEED_REDUCTION))
            applied = applyDirectionalPenalty(newVal)
            if applied and info and info.dieConn then
                controller._activeTurn.dirDieConn = info.dieConn
            end
            if applied then
                delay(TURN_PENALTY_DURATION, function()
                    if controller._activeTurn and controller._activeTurn.origDirectional == orig then
                        restoreDirectionalPenalty()
                    end
                end)
            end
        end
    end

    if not applied then
        pcall(function()
            if humanoid then
                humanoid.AutoRotate = info and info.savedAutoRotate
            end
        end)
    end

    if info and info.dieConn then
        pcall(function() info.dieConn:Disconnect() end)
    end
end

local function performDirectionalDodge(moveVector, dodgeDuration)
    if not isPlayingKiller() then return end
    if not char or not hrp or not humanoid then return end

    local speed = getCurrentSpeed()
    if speed < MIN_SPEED_TO_TRIGGER then return end
    if DODGE_MAX_SPEED and type(DODGE_MAX_SPEED) == "number" then
        speed = math.min(speed, DODGE_MAX_SPEED)
    end

    local moveHoriz = getHorizontalUnit(moveVector)
    if not moveHoriz then return end

    local savedAutoRotate = humanoid.AutoRotate
    humanoid.AutoRotate = false
    humanoid.WalkSpeed = 0

    local bv = Instance.new("BodyVelocity")
    bv.Name = "AutoReflexDirectionalDodge"

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
    bv.Velocity = Vector3.new(moveHoriz.X * speed, preservedY, moveHoriz.Z * speed)
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
        dieConn = dieConn
    }

    if ENABLE_AUTO_KILL_PREVIOUS then
        killPreviousController()
    end

    delay(tonumber(dodgeDuration) or DODGE_DURATIONS.Default, function()
        if not controller then return end
        local info = controller._activeDodge
        controller._activeDodge = nil
        if info and info.bv and info.bv.Parent then
            pcall(function() info.bv:Destroy() end)
        end
        applyPostDodgePenalty(info)
    end)
end

local function performAdaptiveSingleDodge(survivor, dodgeDuration, allowedNames)
    local best = chooseBestAdaptiveDirection(survivor, allowedNames)
    if not best then return end
    performDirectionalDodge(best.dir, dodgeDuration)
end

local function performAdaptiveComboDodge(survivor, dodgeDuration)
    local primary = chooseBestAdaptiveDirection(survivor)
    if not primary then return end

    local secondary = chooseBestPerpendicularDirection(survivor, primary.name)
    if secondary then
        local combo = primary.dir + (secondary.dir * CHANCE_SECONDARY_WEIGHT)
        performDirectionalDodge(combo, dodgeDuration)
    else
        performDirectionalDodge(primary.dir, dodgeDuration)
    end
end

local function scheduleTrackedAdaptiveDodge(survivor, mode, delayTime, dodgeDuration, allowedNames)
    if not survivor then return end
    if not isPlayingKiller() then return end
    if not hrp then
        local c = LocalPlayer.Character
        if c then hrp = c:FindFirstChild("HumanoidRootPart") end
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
    controller._pendingAdaptiveDodgeToken = token

    delay(delayToUse, function()
        if not running then return end
        if controller._pendingAdaptiveDodgeToken ~= token then return end
        controller._pendingAdaptiveDodgeToken = nil

        if not survivor or not survivor.Parent then return end
        if not isPlayingKiller() then return end
        if not char or not hrp or not humanoid then return end

        local latestPos = getModelPosition(survivor)
        if not latestPos then return end
        local latestDist = (hrp.Position - latestPos).Magnitude
        if latestDist > DODGE_RANGE then return end

        if mode == "combo" then
            performAdaptiveComboDodge(survivor, durationToUse)
        else
            performAdaptiveSingleDodge(survivor, durationToUse, allowedNames)
        end
    end)
end

local function performFaceOverride(survivor)
    if not isPlayingKiller() then return end
    if tick() - lastDodgeTime < DODGE_COOLDOWN then return end
    lastDodgeTime = tick()

    if not char or not hrp or not humanoid then return end
    local sPos = getModelPosition(survivor)
    if not sPos then return end

    interruptActiveOverrides()

    local savedAutoRotate = humanoid.AutoRotate
    humanoid.AutoRotate = false

    local folder = getMySpeedMultipliersFolder()
    if folder then
        local dirVal = folder:FindFirstChild("DirectionalMovement")
        if dirVal and (dirVal:IsA("NumberValue") or dirVal:IsA("IntValue")) then
            local orig = dirVal.Value or 1
            local newVal = math.max(0.01, orig * (1 - TURN_SPEED_REDUCTION))
            applyDirectionalPenalty(newVal)
            controller._pendingFaceOrigDirectional = orig
        end
    end

    local lookPos = Vector3.new(sPos.X, hrp.Position.Y, sPos.Z)
    local targetCFrame = CFrame.new(hrp.Position, lookPos)

    pcall(function()
        hrp.CFrame = targetCFrame
        if hrp:IsA("BasePart") then
            hrp.RotVelocity = Vector3.new(0,0,0)
        end
    end)

    local bg = Instance.new("BodyGyro")
    bg.Name = "AutoReflexFaceGyro"
    bg.MaxTorque = Vector3.new(1e8, 1e8, 1e8)
    bg.P = 1e6
    bg.D = 1
    bg.CFrame = targetCFrame
    bg.Parent = hrp

    local hbConn
    hbConn = RunService.Heartbeat:Connect(function()
        if not controller._activeFace then
            if hbConn then pcall(function() hbConn:Disconnect() end) end
            return
        end
        if hrp and hrp.Parent then
            local pos = hrp.Position
            local fixed = CFrame.new(pos, lookPos)
            hrp.CFrame = fixed
        end
    end)

    local dieConn
    dieConn = humanoid.Died:Connect(function()
        if bg and bg.Parent then
            pcall(function() bg:Destroy() end)
        end
        if hbConn then
            pcall(function() hbConn:Disconnect() end)
        end
        if dieConn then
            pcall(function() dieConn:Disconnect() end)
        end
        restoreDirectionalPenalty()
    end)

    controller._activeFace = {
        bg = bg,
        hbConn = hbConn,
        savedAutoRotate = savedAutoRotate,
        dieConn = dieConn
    }

    if controller._activeTurn and controller._activeTurn.dirVal then
        controller._activeTurn.dirDieConn = dieConn
    end

    if ENABLE_AUTO_KILL_PREVIOUS then
        killPreviousController()
    end

    delay(FACE_OVERRIDE_DURATION, function()
        if not controller._activeFace then return end
        local info = controller._activeFace
        controller._activeFace = nil
        if info.bg and info.bg.Parent then
            pcall(function() info.bg:Destroy() end)
        end
        if info.hbConn then
            pcall(function() info.hbConn:Disconnect() end)
        end
        if humanoid then
            pcall(function() humanoid.AutoRotate = info.savedAutoRotate end)
        end
        if info.dieConn then
            pcall(function() info.dieConn:Disconnect() end)
        end

        if controller._activeTurn and controller._activeTurn.origDirectional then
            local orig = controller._activeTurn.origDirectional
            delay(TURN_PENALTY_DURATION, function()
                if controller._activeTurn and controller._activeTurn.origDirectional == orig then
                    restoreDirectionalPenalty()
                end
            end)
        else
            restoreDirectionalPenalty()
        end
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
        if c then hrp = c:FindFirstChild("HumanoidRootPart") end
        if not hrp then return end
    end

    local dist = (hrp.Position - sPos).Magnitude
    if dist <= DODGE_RANGE then
        if survivor.Name == "TwoTime" then
            performFaceOverride(survivor)
        elseif survivor.Name == "JaneDoe" then
            scheduleTrackedAdaptiveDodge(
                survivor,
                "single",
                DODGE_DELAYS.JaneDoe,
                getDodgeDurationForSurvivor("JaneDoe")
            )
        elseif survivor.Name == "Shedletsky" then
            scheduleTrackedAdaptiveDodge(
                survivor,
                "single",
                DODGE_DELAYS.Shedletsky,
                getDodgeDurationForSurvivor("Shedletsky"),
                {"Forward", "Backward"}
            )
        else
            performDirectionalDodge(-hrp.CFrame.LookVector, getDodgeDurationForSurvivor(survivor.Name))
        end
    end
end

local function triggerChanceShootingGunDodge(chanceSurvivor)
    if not chanceSurvivor or chanceSurvivor.Name ~= "Chance" then return end
    if not isPlayingKiller() then return end

    local sPos = getModelPosition(chanceSurvivor)
    if not sPos then return end

    if not hrp then
        local c = LocalPlayer.Character
        if c then hrp = c:FindFirstChild("HumanoidRootPart") end
        if not hrp then return end
    end

    local dist = (hrp.Position - sPos).Magnitude
    if dist <= DODGE_RANGE then
        scheduleTrackedAdaptiveDodge(
            chanceSurvivor,
            "combo",
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
        connections[#connections+1] = conn
    else
        local conn2 = chanceSurvivor.ChildAdded:Connect(function(child)
            if not running then return end
            if child.Name == "SpeedMultipliers" then
                delay(0.03, function()
                    watchChanceShootingGun(chanceSurvivor)
                end)
            end
        end)
        connections[#connections+1] = conn2
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
                connections[#connections+1] = conn
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
                        connections[#connections+1] = conn
                        onResistanceValueChanged(child)
                    end
                end
            end)
            connections[#connections+1] = conn2
        end
    else
        local c = survivor.ChildAdded:Connect(function(child)
            if not running then return end
            if child.Name == RESISTANCE_FOLDER_NAME then
                delay(0.03, function() watchSurvivor(survivor) end)
            end
        end)
        connections[#connections+1] = c
    end
end

local function scanAndWatchSurvivors()
    local survivorsFolder = findSurvivorsFolder()
    if not survivorsFolder then return end
    for _, child in ipairs(survivorsFolder:GetChildren()) do
        pcall(function() watchSurvivor(child) end)
    end
    local connAdd = survivorsFolder.ChildAdded:Connect(function(child)
        if not running then return end
        pcall(function() watchSurvivor(child) end)
    end)
    connections[#connections+1] = connAdd
end

connections[#connections+1] = UserInputService.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == KILL_HOTKEY then
        killPreviousController()
    end
end)

locateAndWatchSprintValue()
do
    local node = workspace:FindFirstChild("Players")
    if node then
        local killers = node:FindFirstChild("Killers")
        if killers then
            local conn = killers.ChildAdded:Connect(function()
                if not running then return end
                delay(0.05, locateAndWatchSprintValue)
            end)
            connections[#connections+1] = conn
        end
        local conn2 = node.ChildAdded:Connect(function()
            if not running then return end
            if node:FindFirstChild("Killers") then
                delay(0.05, locateAndWatchSprintValue)
            end
        end)
        connections[#connections+1] = conn2
    else
        local conn = workspace.ChildAdded:Connect(function(child)
            if not running then return end
            if child.Name == "Players" then
                delay(0.05, locateAndWatchSprintValue)
            end
        end)
        connections[#connections+1] = conn
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
    if not humanoid then humanoid = char:WaitForChild("Humanoid", 2) end
    if not hrp then hrp = char:WaitForChild("HumanoidRootPart", 2) end

    delay(0.05, locateAndWatchSprintValue)

    pcall(function()
        if animatorConnection then
            pcall(function() animatorConnection:Disconnect() end)
            animatorConnection = nil
        end
        local animator = humanoid:FindFirstChildOfClass("Animator") or humanoid:WaitForChild("Animator", 1)
        if animator then
            animatorConnection = animator.AnimationPlayed:Connect(onAnimationPlayed)
            connections[#connections+1] = animatorConnection
        end
    end)
end

if LocalPlayer.Character then
    onCharacterAdded(LocalPlayer.Character)
end
connections[#connections+1] = LocalPlayer.CharacterAdded:Connect(onCharacterAdded)

scanAndWatchSurvivors()

local function cleanup()
    running = false
    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end
    connections = {}

    for val, info in pairs(watchedValues) do
        if info and info.conn then
            pcall(function() info.conn:Disconnect() end)
        end
    end
    watchedValues = {}
    watchedChanceObjects = {}
    controller._pendingAdaptiveDodgeToken = nil

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
    performDirectionalDodge(-hrp.CFrame.LookVector, DODGE_DURATIONS.Default)
end

if RunService:IsStudio() then
    warn(
        "[AutoReflex_AdaptiveSeparateDurations] running. Press 'K' to kill previous controller.",
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
