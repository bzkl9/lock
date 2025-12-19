local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = workspace

local SURVIVOR_MAX = 100
local KILLER_MAX = 110
local DEPLETION_RATE = 10.07
local REGEN_RATE = 20
local EXHAUSTED_REGEN_DELAY = 2
local REST_REGEN_DELAY = 0.21
local LOW_STAMINA_WARNING = 30

local RUN_ANIM_IDS = {
    ["136252471123500"] = true,
    ["115946474977409"] = true,
    ["71505511479171"]  = true,
    ["125869734469543"] = true,
    ["117058860640843"] = true,
    ["133312964070618"] = true,
    ["99159420513149"] = true,
    ["120313643102609"] = true,
    ["86557953969836"] = true,
    ["120715084586730,"] = true,
    ["101438873382721,"] = true,
}

local BILLBOARD_SIZE = UDim2.new(1.6, 0, 0.9, 0)
local BILLBOARD_OFFSET = Vector3.new(0, 3.0, 0)
local LABEL_TEXTSCALED = false
local LABEL_TEXTSIZE = 32
local LABEL_FONT = Enum.Font.SourceSansBold
local LABEL_TEXTSTROKE_TRANSPARENCY = 0.6
local LABEL_TEXTCOLOR = Color3.fromRGB(255,255,255)

local controllers = {}
local playerAddedConn, playerRemovingConn

if _G.StaminaTrackerController and type(_G.StaminaTrackerController.cleanup) == "function" then
    pcall(function() _G.StaminaTrackerController.cleanup() end)
end

local function isPlayerKiller(player)
    if player.Team and player.Team.Name then
        local nameLower = string.lower(player.Team.Name)
        if string.find(nameLower, "kill") then
            return true
        end
    end
    return false
end

local function createStaminaBillboard(character)
    if not character or not character.Parent then return nil end
    local adornee = character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")
    if not adornee then
        adornee = character:WaitForChild("Head", 2) or character:FindFirstChild("HumanoidRootPart")
        if not adornee then return nil end
    end
    local billboard = Instance.new("BillboardGui")
    billboard.Name = "StaminaBillboard"
    billboard.Adornee = adornee
    billboard.AlwaysOnTop = true
    billboard.Size = BILLBOARD_SIZE
    billboard.StudsOffset = BILLBOARD_OFFSET
    billboard.ClipsDescendants = false
    billboard.ResetOnSpawn = false
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(1, 0, 1, 0)
    frame.BackgroundTransparency = 1
    frame.Parent = billboard
    local label = Instance.new("TextLabel")
    label.Name = "StaminaLabel"
    label.Size = UDim2.new(1, 0, 1, 0)
    label.BackgroundTransparency = 1
    label.TextStrokeTransparency = LABEL_TEXTSTROKE_TRANSPARENCY
    label.Font = LABEL_FONT
    label.TextScaled = LABEL_TEXTSCALED
    label.TextWrapped = false
    label.Text = "100"
    if not LABEL_TEXTSCALED then
        label.TextSize = LABEL_TEXTSIZE
    end
    label.TextColor3 = LABEL_TEXTCOLOR
    label.Parent = frame
    billboard.Parent = character
    return billboard, label
end

local function cleanupAll()
    if playerAddedConn then
        pcall(function() playerAddedConn:Disconnect() end)
        playerAddedConn = nil
    end
    if playerRemovingConn then
        pcall(function() playerRemovingConn:Disconnect() end)
        playerRemovingConn = nil
    end
    for player, c in pairs(controllers) do
        if c.heartbeatConn then
            pcall(function() c.heartbeatConn:Disconnect() end)
            c.heartbeatConn = nil
        end
        if c.animPlayedConn then
            pcall(function() c.animPlayedConn:Disconnect() end)
            c.animPlayedConn = nil
        end
        if c.humanoidWaitConn then
            pcall(function() c.humanoidWaitConn:Disconnect() end)
            c.humanoidWaitConn = nil
        end
        if c.trackStopConns then
            for track, conn in pairs(c.trackStopConns) do
                if conn then pcall(function() conn:Disconnect() end) end
            end
            c.trackStopConns = nil
        end
        if c.diedConn then
            pcall(function() c.diedConn:Disconnect() end)
            c.diedConn = nil
        end
        if c.charConn then
            pcall(function() c.charConn:Disconnect() end)
            c.charConn = nil
        end
        if c.billboard and c.billboard.Parent then
            pcall(function() c.billboard:Destroy() end)
            c.billboard = nil
        end
        if player and player.Parent then
            pcall(function()
                if player:GetAttribute("Stamina") then player:SetAttribute("Stamina", nil) end
                if player:FindFirstChild("StaminaValue") then player:FindFirstChild("StaminaValue"):Destroy() end
            end)
        end
    end
    controllers = {}
    print("[StaminaTracker] cleaned up previous instance.")
end

_G.StaminaTrackerController = { cleanup = cleanupAll }

local function extractAnimationIdStr(animObj)
    if not animObj then return nil end
    local idStr = nil
    if typeof(animObj) == "Instance" then
        local ok, aid = pcall(function() return animObj.AnimationId end)
        if ok and aid then
            idStr = tostring(aid)
        end
    else
        idStr = tostring(animObj)
    end
    if not idStr then return nil end
    local digits = idStr:match("(%d+)$") or idStr:match("(%d+)")
    return digits
end

local function handleTrackStart(controller, track)
    if not controller or not track then return end
    local animInstance = nil
    local ok
    ok = pcall(function() animInstance = track.Animation end)
    if not ok or not animInstance then
        ok = pcall(function() animInstance = { AnimationId = track.AnimationId } end)
    end
    local animIdStr = extractAnimationIdStr(animInstance)
    if not animIdStr then
        animIdStr = track.Name and tostring(track.Name):match("(%d+)") or nil
    end
    if not animIdStr then return end
    if RUN_ANIM_IDS[animIdStr] then
        controller.runningTracks = controller.runningTracks or {}
        controller.runningTracks[track] = true
        controller.isRunning = true
        controller.restDelayActive = false
        controller.restDelayTimer = 0
        controller.trackStopConns = controller.trackStopConns or {}
        if controller.trackStopConns[track] then return end
        local conn
        conn = track.Stopped:Connect(function()
            if controller.runningTracks then
                controller.runningTracks[track] = nil
            end
            if controller.trackStopConns and controller.trackStopConns[track] then
                pcall(function() controller.trackStopConns[track]:Disconnect() end)
                controller.trackStopConns[track] = nil
            end
            local anyLeft = false
            if controller.runningTracks then
                for _t, _ in pairs(controller.runningTracks) do
                    anyLeft = true
                    break
                end
            end
            controller.isRunning = anyLeft
            if not controller.isRunning then
                if controller.stamina and controller.stamina > 0 then
                    controller.restDelayActive = true
                    controller.restDelayTimer = REST_REGEN_DELAY
                end
            end
        end)
        controller.trackStopConns[track] = conn
    end
end

local function scanCurrentTracks(controller)
    if not controller or not controller.humanoid then return end
    local ok, tracks = pcall(function() return controller.humanoid:GetPlayingAnimationTracks() end)
    if not ok or not tracks then return end
    for _, track in ipairs(tracks) do
        pcall(function() handleTrackStart(controller, track) end)
    end
end

local function attachAnimationWatcher(controller)
    if not controller then return end
    if controller.animPlayedConn then
        pcall(function() controller.animPlayedConn:Disconnect() end)
        controller.animPlayedConn = nil
    end
    if not controller.humanoid or not controller.humanoid.Parent then
        return
    end
    local success, conn = pcall(function()
        return controller.humanoid.AnimationPlayed:Connect(function(track)
            pcall(function() handleTrackStart(controller, track) end)
        end)
    end)
    if success and conn then
        controller.animPlayedConn = conn
        scanCurrentTracks(controller)
    else
        scanCurrentTracks(controller)
    end
end

local function setupPlayer(player)
    if controllers[player] then return end
    local controller = {
        player = player,
        maxStamina = isPlayerKiller(player) and KILLER_MAX or SURVIVOR_MAX,
        stamina = nil,
        exhausted = false,
        exhaustedTimer = 0,
        restDelayActive = false,
        restDelayTimer = 0,
        billboard = nil,
        label = nil,
        character = nil,
        humanoid = nil,
        hrp = nil,
        heartbeatConn = nil,
        animPlayedConn = nil,
        humanoidWaitConn = nil,
        trackStopConns = nil,
        diedConn = nil,
        charConn = nil,
        runningTracks = {},
        isRunning = false,
    }
    controller.stamina = controller.maxStamina
    player:SetAttribute("MaxStamina", controller.maxStamina)
    player:SetAttribute("Stamina", controller.stamina)
    if player:FindFirstChild("StaminaValue") then player:FindFirstChild("StaminaValue"):Destroy() end
    local staminaValue = Instance.new("NumberValue")
    staminaValue.Name = "StaminaValue"
    staminaValue.Value = controller.stamina
    staminaValue.Parent = player
    controllers[player] = controller
    local function onCharacterAdded(character)
        if controller.humanoidWaitConn then
            pcall(function() controller.humanoidWaitConn:Disconnect() end)
            controller.humanoidWaitConn = nil
        end
        if controller.animPlayedConn then
            pcall(function() controller.animPlayedConn:Disconnect() end)
            controller.animPlayedConn = nil
        end
        if controller.trackStopConns then
            for t, conn in pairs(controller.trackStopConns) do
                if conn then pcall(function() conn:Disconnect() end) end
            end
            controller.trackStopConns = {}
        end
        controller.runningTracks = {}
        controller.isRunning = false
        controller.restDelayActive = false
        controller.restDelayTimer = 0
        if controller.diedConn then
            pcall(function() controller.diedConn:Disconnect() end)
            controller.diedConn = nil
        end
        if controller.billboard and controller.billboard.Parent then
            pcall(function() controller.billboard:Destroy() end)
            controller.billboard = nil
            controller.label = nil
        end
        controller.character = character
        controller.humanoid = character:FindFirstChildOfClass("Humanoid")
        controller.hrp = character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("Torso") or character:FindFirstChild("UpperTorso")
        controller.maxStamina = isPlayerKiller(player) and KILLER_MAX or SURVIVOR_MAX
        controller.stamina = controller.maxStamina
        controller.exhausted = false
        controller.exhaustedTimer = 0
        controller.restDelayActive = false
        controller.restDelayTimer = 0
        player:SetAttribute("MaxStamina", controller.maxStamina)
        player:SetAttribute("Stamina", controller.stamina)
        staminaValue.Value = controller.stamina
        local billboard, label = createStaminaBillboard(character)
        controller.billboard = billboard
        controller.label = label
        if controller.humanoid then
            controller.diedConn = controller.humanoid.Died:Connect(function()
                controller.stamina = controller.maxStamina
                controller.exhausted = false
                controller.exhaustedTimer = 0
                controller.restDelayActive = false
                controller.restDelayTimer = 0
                player:SetAttribute("Stamina", controller.stamina)
                staminaValue.Value = controller.stamina
                if controller.label then
                    controller.label.Text = tostring(math.floor(controller.stamina + 0.5))
                    controller.label.TextColor3 = LABEL_TEXTCOLOR
                end
            end)
        end
        if controller.humanoid then
            attachAnimationWatcher(controller)
        else
            local wconn
            wconn = character.ChildAdded:Connect(function(child)
                if not child then return end
                if child:IsA("Humanoid") then
                    controller.humanoid = child
                    if wconn then pcall(function() wconn:Disconnect() end) end
                    controller.humanoidWaitConn = nil
                    attachAnimationWatcher(controller)
                    if controller.diedConn then
                        pcall(function() controller.diedConn:Disconnect() end)
                        controller.diedConn = nil
                    end
                    controller.diedConn = controller.humanoid.Died:Connect(function()
                        controller.stamina = controller.maxStamina
                        controller.exhausted = false
                        controller.exhaustedTimer = 0
                        controller.restDelayActive = false
                        controller.restDelayTimer = 0
                        player:SetAttribute("Stamina", controller.stamina)
                        staminaValue.Value = controller.stamina
                        if controller.label then
                            controller.label.Text = tostring(math.floor(controller.stamina + 0.5))
                            controller.label.TextColor3 = LABEL_TEXTCOLOR
                        end
                    end)
                end
            end)
            controller.humanoidWaitConn = wconn
        end
    end
    controller.charConn = player.CharacterAdded:Connect(onCharacterAdded)
    if player.Character then onCharacterAdded(player.Character) end
    controller.heartbeatConn = RunService.Heartbeat:Connect(function(dt)
        if not player.Parent then return end
        if controller.character and (not controller.hrp or not controller.hrp.Parent) then
            controller.hrp = controller.character:FindFirstChild("HumanoidRootPart") or controller.character:FindFirstChild("Torso") or controller.character:FindFirstChild("UpperTorso")
        end
        if controller.humanoid and not controller.animPlayedConn then
            attachAnimationWatcher(controller)
        end
        local isSprinting = controller.isRunning == true
        if isSprinting then
            controller.stamina = controller.stamina - (DEPLETION_RATE * dt)
            controller.restDelayActive = false
            controller.restDelayTimer = 0
            if controller.stamina <= 0 then
                controller.stamina = 0
                if not controller.exhausted then
                    controller.exhausted = true
                    controller.exhaustedTimer = EXHAUSTED_REGEN_DELAY
                end
            end
        else
            if controller.exhausted then
                controller.exhaustedTimer = controller.exhaustedTimer - dt
                if controller.exhaustedTimer <= 0 then
                    controller.exhausted = false
                    controller.exhaustedTimer = 0
                end
            elseif controller.restDelayActive then
                controller.restDelayTimer = controller.restDelayTimer - dt
                if controller.restDelayTimer <= 0 then
                    controller.restDelayActive = false
                    controller.restDelayTimer = 0
                end
            else
                controller.stamina = controller.stamina + (REGEN_RATE * dt)
                if controller.stamina > controller.maxStamina then
                    controller.stamina = controller.maxStamina
                end
            end
        end
        local displayValue = math.floor((controller.stamina * 10) + 0.5) / 10
        player:SetAttribute("Stamina", controller.stamina)
        staminaValue.Value = controller.stamina
        if controller.label and controller.label.Parent then
            local showText
            if math.abs(displayValue - math.floor(displayValue)) < 0.001 then
                showText = tostring(math.floor(displayValue))
            else
                showText = string.format("%.1f", displayValue)
            end
            controller.label.Text = showText
            if controller.stamina < LOW_STAMINA_WARNING then
                controller.label.TextColor3 = Color3.fromRGB(255, 80, 80)
            else
                controller.label.TextColor3 = LABEL_TEXTCOLOR
            end
        end
    end)
end

for _, player in ipairs(Players:GetPlayers()) do
    setupPlayer(player)
end

playerAddedConn = Players.PlayerAdded:Connect(function(player)
    setupPlayer(player)
end)

playerRemovingConn = Players.PlayerRemoving:Connect(function(player)
    local c = controllers[player]
    if c then
        if c.heartbeatConn then pcall(function() c.heartbeatConn:Disconnect() end) c.heartbeatConn = nil end
        if c.animPlayedConn then pcall(function() c.animPlayedConn:Disconnect() end) c.animPlayedConn = nil end
        if c.humanoidWaitConn then pcall(function() c.humanoidWaitConn:Disconnect() end) c.humanoidWaitConn = nil end
        if c.trackStopConns then
            for t, conn in pairs(c.trackStopConns) do if conn then pcall(function() conn:Disconnect() end) end end
            c.trackStopConns = nil
        end
        if c.diedConn then pcall(function() c.diedConn:Disconnect() end) c.diedConn = nil end
        if c.charConn then pcall(function() c.charConn:Disconnect() end) c.charConn = nil end
        if c.billboard and c.billboard.Parent then pcall(function() c.billboard:Destroy() end) c.billboard = nil end
        controllers[player] = nil
    end
end)

_G.StaminaTrackerController.cleanup = cleanupAll

print("[StaminaTracker] Server script loaded ￯﾿ﾢ￯ﾾﾀ￯ﾾﾔ animation-based detection active with rest/empty timers.")

do
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
if not player then return end

if _G.AutoWallStickController and type(_G.AutoWallStickController.Cleanup) == "function" then
    pcall(function() _G.AutoWallStickController.Cleanup() end)
    _G.AutoWallStickController = nil
end

local controller = {}
_G.AutoWallStickController = controller

local STICK_DETECT_DISTANCE = 3.5
local DESIRED_WALL_DISTANCE = 1.5
local STICK_LERP_SPEED = 23
local AGGRESSIVE_LERP_SPEED = 40
local MIN_MOVE_TO_STICK = 0.01
local WALL_NORMAL_Y_THRESHOLD = 0.82
local ALLOW_STICK_ANGLE = 0.85
local LEAVE_THRESHOLD = -0.25
local RAY_HEIGHTS = {0.6, 1.4, 2.0}
local FORWARD_OFFSETS = {-0.6, 0, 0.6}
local SIDE_SAMPLE_RADIUS = 0.35
local GRACE_KEEP_SECONDS = 0.12
local MIN_HIT_COUNT_TO_ACCEPT = 2
local SAMPLES_PER_SIDE = #RAY_HEIGHTS * #FORWARD_OFFSETS
local OBSTACLE_LOOKAHEAD_MULT = 0.7
local AVOID_SHIFT_AMOUNT = 1.2
local MAX_OBSTACLE_RETRY = 0.3
local MAX_SHIFT_PER_FRAME = 2.5

local running = true
local connections = {}
local char, hrp, humanoid
local lastWall = nil
local lastWallSeenTime = 0
local lastObstacleClearAttempt = 0

local function safeRaycast(origin, dir, params)
    local ok, res = pcall(function()
        return workspace:Raycast(origin, dir, params)
    end)
    if ok then return res else return nil end
end

local function getMoveDirection()
    if humanoid and humanoid.MoveDirection and humanoid.MoveDirection.Magnitude > 0.001 then
        return humanoid.MoveDirection.Unit
    end
    local x, z = 0, 0
    if UserInputService:IsKeyDown(Enum.KeyCode.W) then z = z - 1 end
    if UserInputService:IsKeyDown(Enum.KeyCode.S) then z = z + 1 end
    if UserInputService:IsKeyDown(Enum.KeyCode.A) then x = x - 1 end
    if UserInputService:IsKeyDown(Enum.KeyCode.D) then x = x + 1 end
    local v = Vector3.new(x, 0, z)
    if v.Magnitude > 0.001 then
        local cam = workspace.CurrentCamera
        if cam then
            local look = Vector3.new(cam.CFrame.LookVector.X, 0, cam.CFrame.LookVector.Z)
            if look.Magnitude < 0.001 then look = Vector3.new(0,0,-1) end
            look = look.Unit
            local right = Vector3.new(cam.CFrame.RightVector.X, 0, cam.CFrame.RightVector.Z)
            if right.Magnitude < 0.001 then right = Vector3.new(1,0,0) end
            right = right.Unit
            return (look * -v.Z + right * v.X).Unit
        end
        return v.Unit
    end
    return Vector3.new(0,0,0)
end

local function detectWall()
    if not hrp or not char then return nil end
    local originBase = hrp.Position
    local params = RaycastParams.new()
    params.FilterDescendantsInstances = {char}
    params.FilterType = Enum.RaycastFilterType.Blacklist
    params.IgnoreWater = true
    local rightVec = hrp.CFrame.RightVector
    local leftVec = -hrp.CFrame.RightVector
    local lookVec = hrp.CFrame.LookVector
    local function sampleSide(sideDir)
        local totalWeight = 0
        local weightedNormal = Vector3.new(0,0,0)
        local weightedPos = Vector3.new(0,0,0)
        local hitCount = 0
        local totalDist = 0
        for _, fh in ipairs(FORWARD_OFFSETS) do
            for _, h in ipairs(RAY_HEIGHTS) do
                local sampleOrigin = originBase + lookVec * fh + Vector3.new(0, h, 0)
                local offsetSide = sampleOrigin + (hrp.CFrame.RightVector * SIDE_SAMPLE_RADIUS * (sideDir == rightVec and 1 or -1))
                local dir = sideDir * STICK_DETECT_DISTANCE
                local hit = safeRaycast(offsetSide, dir, params)
                if hit and hit.Instance then
                    local dist = (hit.Position - offsetSide).Magnitude
                    local weight = 1 / math.max(dist, 0.001)
                    weightedNormal = weightedNormal + hit.Normal * weight
                    weightedPos = weightedPos + hit.Position * weight
                    totalWeight = totalWeight + weight
                    totalDist = totalDist + dist
                    hitCount = hitCount + 1
                end
            end
        end
        if hitCount < MIN_HIT_COUNT_TO_ACCEPT then return nil end
        local avgNormal = (weightedNormal / totalWeight)
        if avgNormal.Magnitude < 0.001 then return nil end
        avgNormal = avgNormal.Unit
        local avgPos = (weightedPos / totalWeight)
        local avgDist = totalDist / hitCount
        return {normal = avgNormal, position = avgPos, dist = avgDist, hits = hitCount}
    end
    local r = sampleSide(rightVec)
    local l = sampleSide(leftVec)
    local choose = nil
    if r and l then
        if r.hits > l.hits then choose = {side="Right", hit=r}
        elseif l.hits > r.hits then choose = {side="Left", hit=l}
        else choose = (r.dist <= l.dist) and {side="Right", hit=r} or {side="Left", hit=l} end
    elseif r then choose = {side="Right", hit=r}
    elseif l then choose = {side="Left", hit=l}
    end
    if not choose then return nil end
    if math.abs(choose.hit.normal.Y) > WALL_NORMAL_Y_THRESHOLD and choose.hit.hits < (SAMPLES_PER_SIDE * 0.6) then
        return nil
    end
    return {
        side = choose.side,
        normal = choose.hit.normal,
        position = choose.hit.position,
        avgDist = choose.hit.dist,
        hitCount = choose.hit.hits,
        timestamp = tick()
    }
end

local function pathBlocked(a, b)
    local dir = b - a
    local dist = dir.Magnitude
    if dist < 0.0001 then return false, nil end
    local params = RaycastParams.new()
    params.FilterDescendantsInstances = {char}
    params.FilterType = Enum.RaycastFilterType.Blacklist
    params.IgnoreWater = true
    local hit = safeRaycast(a, dir.Unit * dist, params)
    if hit and hit.Instance then
        return true, hit
    end
    return false, nil
end

local function computeAlternateMove(hrpPos, targetPos, lastWall, playerMoveDir, allowedMoveDist)
    local tangent = lastWall.normal:Cross(Vector3.new(0,1,0))
    if tangent.Magnitude > 0.001 then tangent = tangent.Unit end
    local sign = 1
    if playerMoveDir.Magnitude > 0.001 then
        if playerMoveDir:Dot(tangent) < 0 then sign = -1 end
    end
    local slideDir = tangent * sign
    slideDir = Vector3.new(slideDir.X, 0, slideDir.Z)
    if slideDir.Magnitude > 0.001 then slideDir = slideDir.Unit end
    local slideTarget = hrpPos + slideDir * math.min(AVOID_SHIFT_AMOUNT, allowedMoveDist)
    local blocked, hit = pathBlocked(hrpPos, slideTarget)
    if not blocked then return slideTarget end
    local oppSlide = hrpPos - slideDir * math.min(AVOID_SHIFT_AMOUNT, allowedMoveDist)
    local blocked2, hit2 = pathBlocked(hrpPos, oppSlide)
    if not blocked2 then return oppSlide end
    local otherDetected = detectWall()
    if otherDetected and otherDetected.side ~= lastWall.side then
        local lateralVec = hrpPos - otherDetected.position
        local lateralDist = lateralVec:Dot(otherDetected.normal)
        local altTarget = hrpPos - otherDetected.normal * (lateralDist - DESIRED_WALL_DISTANCE)
        altTarget = Vector3.new(altTarget.X, hrpPos.Y, altTarget.Z)
        local blocked3, _ = pathBlocked(hrpPos, altTarget)
        if not blocked3 then return altTarget end
    end
    local backPos = hrpPos - playerMoveDir * math.min(allowedMoveDist, 0.4)
    local blocked4, _ = pathBlocked(hrpPos, backPos)
    if not blocked4 then return backPos end
    return nil
end

local function cleanup()
    running = false
    for _, c in ipairs(connections) do
        pcall(function() c:Disconnect() end)
    end
    connections = {}
    if controller then controller.Cleanup = nil end
    if _G.AutoWallStickController == controller then _G.AutoWallStickController = nil end
end
controller.Cleanup = cleanup

local function onCharacterAdded(c)
    char = c
    humanoid = char:WaitForChild("Humanoid", 5)
    hrp = char:WaitForChild("HumanoidRootPart", 5)
    lastWall = nil
end
if player.Character then onCharacterAdded(player.Character) end
connections[#connections+1] = player.CharacterAdded:Connect(onCharacterAdded)

connections[#connections+1] = RunService.RenderStepped:Connect(function(dt)
    if not running then return end
    if not char or not hrp or not humanoid then return end
    if humanoid.Health <= 0 then return end
    local moveDir = getMoveDirection()
    local moveMag = moveDir.Magnitude
    local walkSpeed = math.max(0.1, humanoid.WalkSpeed or 16)
    local detected = detectWall()
    if detected then
        lastWall = detected
        lastWallSeenTime = tick()
    else
        if lastWall and (tick() - lastWallSeenTime) < GRACE_KEEP_SECONDS then
        else
            lastWall = nil
        end
    end
    if lastWall then
        local lateralVec = hrp.Position - lastWall.position
        local lateralDist = lateralVec:Dot(lastWall.normal)
        local movingAwayDot = 0
        if moveMag > 0.001 then movingAwayDot = moveDir:Dot(-lastWall.normal) end
        local wallTangent = lastWall.normal:Cross(Vector3.new(0,1,0))
        if wallTangent.Magnitude > 0.001 then wallTangent = wallTangent.Unit end
        local wallTangentParallel = 0
        if moveMag > 0.001 and wallTangent.Magnitude > 0.001 then
            wallTangentParallel = math.abs(moveDir:Dot(wallTangent))
        end
        local shouldStick = false
        if moveMag > MIN_MOVE_TO_STICK then
            if wallTangentParallel >= ALLOW_STICK_ANGLE then shouldStick = true end
            if movingAwayDot > 0.2 then shouldStick = true end
            if lateralDist < (DESIRED_WALL_DISTANCE + 0.8) then shouldStick = true end
            if movingAwayDot < LEAVE_THRESHOLD then shouldStick = false end
        else
            if lateralDist < (DESIRED_WALL_DISTANCE + 0.5) then shouldStick = true end
        end
        if shouldStick then
            local desiredTarget = hrp.Position - lastWall.normal * (lateralDist - DESIRED_WALL_DISTANCE)
            desiredTarget = Vector3.new(desiredTarget.X, hrp.Position.Y, desiredTarget.Z)
            local intendedSpeed = walkSpeed
            if moveMag > 0.001 then
                intendedSpeed = walkSpeed * math.clamp(moveMag, 0, 1)
            end
            local allowedMoveDist = math.min(intendedSpeed * dt, MAX_SHIFT_PER_FRAME)
            local toTarget = Vector3.new(desiredTarget.X - hrp.Position.X, 0, desiredTarget.Z - hrp.Position.Z)
            local distToTarget = toTarget.Magnitude
            if distToTarget > 0.001 then
                local lateralShift = toTarget
                if moveMag > 0.001 then
                    local forwardProj = moveDir * (toTarget:Dot(moveDir))
                    lateralShift = toTarget - forwardProj
                end
                if moveMag <= 0.001 then lateralShift = toTarget end
                local lateralMag = lateralShift.Magnitude
                local candidatePos = hrp.Position
                if lateralMag > 0.001 then
                    local lateralDir = lateralShift.Unit
                    local lateralMove = math.min(lateralMag, allowedMoveDist)
                    candidatePos = hrp.Position + lateralDir * lateralMove
                else
                    candidatePos = hrp.Position
                end
                local blocked, hit = pathBlocked(hrp.Position, candidatePos)
                if blocked then
                    local alt = computeAlternateMove(hrp.Position, desiredTarget, lastWall, moveDir, allowedMoveDist)
                    if alt then candidatePos = alt else candidatePos = hrp.Position end
                end
                local lerpSpeed = STICK_LERP_SPEED
                if distToTarget < 0.45 then lerpSpeed = AGGRESSIVE_LERP_SPEED end
                local lerpFactor = math.clamp(1 - math.exp(-lerpSpeed * dt), 0, 1)
                local newPos = hrp.Position:Lerp(candidatePos, lerpFactor)
                if (newPos - hrp.Position).Magnitude > 0.0007 then
                    local look = hrp.CFrame.LookVector
                    local newCf = CFrame.new(newPos, newPos + Vector3.new(look.X, 0, look.Z))
                    hrp.CFrame = newCf
                end
            end
        else
            if lastWall and (tick() - lastWallSeenTime) >= GRACE_KEEP_SECONDS then
                lastWall = nil
            end
        end
    end
end)

controller.Cleanup = cleanup

if RunService:IsStudio() then
    warn("[AutoWallStick_PersistAcrossRespawn] running. Re-run kills previous instance. Persists across respawn.")
end
end

do
local RunService = game:GetService("RunService")
local PlayersService = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local workspace = workspace

local LocalPlayer = PlayersService.LocalPlayer
if not LocalPlayer then return end

local SURVIVORS_PATH = {"Players", "Survivors"}
local TARGET_NAMES = { Guest1337 = true, Shedletsky = true, TwoTime = true }
local RESISTANCE_FOLDER_NAME = "ResistanceMultipliers"
local RESISTANCE_VALUE_NAME = "ResistanceStatus"
local TRIGGER_VALUES = { [20] = true, [40] = true }

local DODGE_OVERRIDE_DURATION = 0.35
local DODGE_COOLDOWN = 0.5
local DODGE_RANGE = 20
local MIN_SPEED_TO_TRIGGER = 0.2
local DODGE_FORCE_P = 1e4
local DODGE_FORCE_MAX = Vector3.new(1e5, 1e5, 1e5)
local DODGE_MAX_SPEED = 19

-- Face duration (0.5s requested)
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
}

local running = true
local connections = {}
local watchedValues = {}
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

local function getModelPosition(model)
    if not model then return nil end
    if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then
        return model.PrimaryPart.Position
    end
    local candidates = {"HumanoidRootPart", "Torso", "UpperTorso", "LowerTorso"}
    for _, name in ipairs(candidates) do
        local p = model:FindFirstChild(name)
        if p and p:IsA("BasePart") then
            return p.Position
        end
    end
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

-- Interrupt and cleanup any active overrides (dodge or face)
local function interruptActiveOverrides()
    -- active dodge cleanup
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
                humanoid.WalkSpeed = info.savedWalkSpeed or 16
                humanoid.AutoRotate = info.savedAutoRotate
            end
        end)
    end

    -- active face cleanup
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
end

-- Add these two config constants near the other constants at the top:
local TURN_SPEED_REDUCTION = 0.30      -- 30% slower while recovering from a forced turn
local TURN_PENALTY_DURATION = 0.5     -- how long (seconds) the penalty lasts

-- internal helper: clear any active turn penalty and restore WalkSpeed
local function clearTurnPenalty()
    if controller._activeTurn then
        local tinfo = controller._activeTurn
        controller._activeTurn = nil
        pcall(function()
            if humanoid and tinfo.savedWalkSpeed then
                humanoid.WalkSpeed = tinfo.savedWalkSpeed
            end
        end)
        if tinfo.dieConn then
            pcall(function() tinfo.dieConn:Disconnect() end)
        end
    end
end

-- Interrupt and cleanup any active overrides (dodge or face) and turn penalties
local function interruptActiveOverrides()
    -- active dodge cleanup
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
                humanoid.WalkSpeed = info.savedWalkSpeed or 16
                humanoid.AutoRotate = info.savedAutoRotate
            end
        end)
    end

    -- active face cleanup
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

    -- clear any turn penalty (restores walk speed)
    clearTurnPenalty()
end

-- TURN penalty config (keep near other config if already defined)
local TURN_SPEED_REDUCTION = 0.30      -- 30% slower while recovering from a forced turn
local TURN_PENALTY_DURATION = 0.5     -- how long (seconds) the penalty lasts

-- Helper: locate SpeedMultipliers folder for the local killer entry
local function getMySpeedMultipliersFolder()
    local playersNode = workspace:FindFirstChild("Players")
    if not playersNode then return nil end
    local killersFolder = playersNode:FindFirstChild("Killers")
    if not killersFolder then return nil end
    local myEntry = killersFolder:FindFirstChild(LocalPlayer.Name)
    if not myEntry then return nil end
    local speedMultFolder = myEntry:FindFirstChild("SpeedMultipliers")
    return speedMultFolder
end

-- Helper: apply directional multiplier penalty (stores original so we can restore)
local function applyDirectionalPenalty(multipliedValue)
    local folder = getMySpeedMultipliersFolder()
    if not folder then return false end
    local dirVal = folder:FindFirstChild("DirectionalMovement")
    if not dirVal or not (dirVal:IsA("NumberValue") or dirVal:IsA("IntValue")) then return false end

    -- store original so we can restore
    local orig = dirVal.Value
    -- set the reduced value
    pcall(function() dirVal.Value = multipliedValue end)

    -- store in controller state so interrupts/cleanup can restore
    controller._activeTurn = controller._activeTurn or {}
    -- disconnect any previous dieConn we replaced
    if controller._activeTurn.dirDieConn then
        pcall(function() controller._activeTurn.dirDieConn:Disconnect() end)
    end
    controller._activeTurn.dirVal = dirVal
    controller._activeTurn.origDirectional = orig

    return true
end

-- Helper: restore directional multiplier if we previously changed it
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

-- Interrupt and cleanup any active overrides (dodge or face) and turn penalties
local function interruptActiveOverrides()
    -- active dodge cleanup (unchanged behavior for BV)
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

    -- active face cleanup (unchanged orientation cleanup)
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

    -- restore any directional multiplier penalty we applied
    restoreDirectionalPenalty()
end

-- Back dodge with BodyVelocity; after the dodge we apply a short directional penalty
local function performBackDodgeOverride()
    if not isPlayingKiller() then return end
    if tick() - lastDodgeTime < DODGE_COOLDOWN then return end
    lastDodgeTime = tick()
    if not char or not hrp or not humanoid then return end
    local speed = getCurrentSpeed()
    if speed < MIN_SPEED_TO_TRIGGER then return end
    if DODGE_MAX_SPEED and type(DODGE_MAX_SPEED) == "number" then
        speed = math.min(speed, DODGE_MAX_SPEED)
    end
    local back = -hrp.CFrame.LookVector
    local backHoriz = Vector3.new(back.X, 0, back.Z)
    if backHoriz.Magnitude < 0.001 then return end
    backHoriz = backHoriz.Unit
    local savedAutoRotate = humanoid.AutoRotate

    -- disable autorotate and zero walk speed so BV carries motion externally
    humanoid.AutoRotate = false
    humanoid.WalkSpeed = 0

    local bv = Instance.new("BodyVelocity")
    bv.Name = "AutoReflexBackDodge"
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
    bv.Velocity = Vector3.new(backHoriz.X * speed, preservedY, backHoriz.Z * speed)
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

    -- after the dodge duration: destroy BV and apply directional penalty
    delay(DODGE_OVERRIDE_DURATION, function()
        if not controller then return end
        local info = controller._activeDodge
        controller._activeDodge = nil
        if info and info.bv and info.bv.Parent then
            pcall(function() info.bv:Destroy() end)
        end

        -- Attempt to apply directional multiplier penalty based on current DirectionalMovement
        local applied = false
        local folder = getMySpeedMultipliersFolder()
        if folder then
            local dirVal = folder:FindFirstChild("DirectionalMovement")
            if dirVal and (dirVal:IsA("NumberValue") or dirVal:IsA("IntValue")) then
                local orig = dirVal.Value or 1
                local newVal = math.max(0.01, orig * (1 - TURN_SPEED_REDUCTION))
                applied = applyDirectionalPenalty(newVal)
                -- register character death to restore if necessary
                if applied and info and info.dieConn then
                    -- store dieConn so restore can disconnect it on death
                    controller._activeTurn.dirDieConn = info.dieConn
                end
                -- schedule full restore after the penalty duration
                if applied then
                    delay(TURN_PENALTY_DURATION, function()
                        -- only restore if still the same penalty we applied
                        if controller._activeTurn and controller._activeTurn.origDirectional == orig then
                            restoreDirectionalPenalty()
                        end
                    end)
                end
            end
        end

        -- If we failed to apply via DirectionalMovement, fallback to restoring AutoRotate immediately
        if not applied then
            pcall(function() if humanoid then humanoid.AutoRotate = info and info.savedAutoRotate end end)
        end

        if info and info.dieConn then
            pcall(function() info.dieConn:Disconnect() end)
        end
    end)
end

-- Face override: snap to survivor, hold orientation, and apply directional penalty immediately
local function performFaceOverride(survivor)
    if not isPlayingKiller() then return end
    if tick() - lastDodgeTime < DODGE_COOLDOWN then return end
    lastDodgeTime = tick()
    if not char or not hrp or not humanoid then return end
    local sPos = getModelPosition(survivor)
    if not sPos then return end

    -- Cleanup any active override first
    interruptActiveOverrides()

    -- Save and disable AutoRotate
    local savedAutoRotate = humanoid.AutoRotate
    humanoid.AutoRotate = false

    -- Attempt to apply a directional multiplier penalty immediately (based on current value)
    local applied = false
    local folder = getMySpeedMultipliersFolder()
    if folder then
        local dirVal = folder:FindFirstChild("DirectionalMovement")
        if dirVal and (dirVal:IsA("NumberValue") or dirVal:IsA("IntValue")) then
            local orig = dirVal.Value or 1
            local newVal = math.max(0.01, orig * (1 - TURN_SPEED_REDUCTION))
            applied = applyDirectionalPenalty(newVal)
            -- register dieConn so we can restore on death
            if applied and controller._activeTurn and controller._activeTurn.dirVal then
                -- we'll reuse the face dieConn below to disconnect
            end
        end
    end

    -- Compute look CFrame (preserve hrp Y for level look)
    local lookPos = Vector3.new(sPos.X, hrp.Position.Y, sPos.Z)
    local targetCFrame = CFrame.new(hrp.Position, lookPos)

    -- Instant snap and zero RotVelocity
    pcall(function()
        hrp.CFrame = targetCFrame
        if hrp:IsA("BasePart") then
            hrp.RotVelocity = Vector3.new(0,0,0)
        end
    end)

    -- Backup BodyGyro (not relied on for snapping)
    local bg = Instance.new("BodyGyro")
    bg.Name = "AutoReflexFaceGyro"
    bg.MaxTorque = Vector3.new(1e8, 1e8, 1e8)
    bg.P = 1e6
    bg.D = 1
    bg.CFrame = targetCFrame
    bg.Parent = hrp

    -- Heartbeat forcing to hold exact orientation
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
        -- restore directional multiplier on death
        restoreDirectionalPenalty()
    end)

    controller._activeFace = {
        bg = bg,
        hbConn = hbConn,
        savedAutoRotate = savedAutoRotate,
        dieConn = dieConn
    }

    -- If we applied a directional penalty, attach dieConn reference so it gets restored on death
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

        -- schedule restore of the directional multiplier (if we changed it)
        if controller._activeTurn and controller._activeTurn.origDirectional then
            local orig = controller._activeTurn.origDirectional
            delay(TURN_PENALTY_DURATION, function()
                if controller._activeTurn and controller._activeTurn.origDirectional == orig then
                    restoreDirectionalPenalty()
                end
            end)
        else
            -- nothing to restore via directional multiplier
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
    if not survivor then
        return
    end
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
        else
            performBackDodgeOverride()
        end
    end
end

local function watchSurvivor(survivor)
    if not survivor or not TARGET_NAMES[survivor.Name] then return end
    local folder = survivor:FindFirstChild(RESISTANCE_FOLDER_NAME)
    if folder then
        local val = folder:FindFirstChild(RESISTANCE_VALUE_NAME)
        if val and (val:IsA("IntValue") or val:IsA("NumberValue")) then
            if not watchedValues[val] then
                local conn = val:GetPropertyChangedSignal("Value"):Connect(function() onResistanceValueChanged(val) end)
                watchedValues[val] = { conn = conn, survivor = survivor }
                connections[#connections+1] = conn
                onResistanceValueChanged(val)
            end
        else
            local conn2 = folder.ChildAdded:Connect(function(child)
                if not running then return end
                if child.Name == RESISTANCE_VALUE_NAME and (child:IsA("IntValue") or child:IsA("NumberValue")) then
                    if not watchedValues[child] then
                        local conn = child:GetPropertyChangedSignal("Value"):Connect(function() onResistanceValueChanged(child) end)
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
if LocalPlayer.Character then onCharacterAdded(LocalPlayer.Character) end
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
    if _G.AutoReflexController == controller then _G.AutoReflexController = nil end
    controller.Cleanup = nil
end
controller.Cleanup = cleanup

function controller.KillPrevious()
    killPreviousController()
end
function controller.TriggerDodgeNow()
    performBackDodgeOverride()
end

if RunService:IsStudio() then
    warn("[AutoReflex_SpeedAware_0.14sOverride_Range] running. Press 'K' to kill previous controller. Dodge override duration:", DODGE_OVERRIDE_DURATION, "Range:", DODGE_RANGE)
end
end
