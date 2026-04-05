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
    ["120715084586730"] = true,
    ["101438873382721"] = true,
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

