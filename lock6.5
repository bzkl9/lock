-- Aim Assist: Hitbox-aware + Smoothed Velocity + Instant Snap Prediction
-- + Robust Adaptation: EWMA tendencies, oscillation detection, hit-weighting, clamped lateral offsets.
-- + Animation-detection: start recordings when target plays known Q/E cast animations (user-supplied IDs)
-- + Highlighting: red highlight (F) toggles only via F; U-locks exclusively to red-highlighted target if present
-- Highlights locked target (green) and shows per-target info. Respects windup & cooldown rules for recording.
-- Kill previous instance
if _G.AimAssistKill and type(_G.AimAssistKill) == "function" then
    pcall(_G.AimAssistKill)
end

_G.AimAssistKill = function()
    if _G.AimAssistConn then
        _G.AimAssistConn:Disconnect()
        _G.AimAssistConn = nil
    end
    if _G.AimAssistGui and _G.AimAssistGui.Parent then
        _G.AimAssistGui:Destroy()
        _G.AimAssistGui = nil
    end
    if _G.AimAssistActiveRecordConns then
        for _, c in ipairs(_G.AimAssistActiveRecordConns) do
            pcall(function() c:Disconnect() end)
        end
        _G.AimAssistActiveRecordConns = nil
    end
    if _G.AimAssistAnimConns then
        for _, c in ipairs(_G.AimAssistAnimConns) do
            pcall(function() c:Disconnect() end)
        end
        _G.AimAssistAnimConns = nil
    end
    if _G.AimAssistLockedHighlight then
        pcall(function() _G.AimAssistLockedHighlight:Destroy() end)
        _G.AimAssistLockedHighlight = nil
    end
    if _G.AimAssistLockedBillboard then
        pcall(function() _G.AimAssistLockedBillboard:Destroy() end)
        _G.AimAssistLockedBillboard = nil
    end
    if _G.AimAssistRedHighlight then
        pcall(function() _G.AimAssistRedHighlight:Destroy() end)
        _G.AimAssistRedHighlight = nil
    end
    _G.AimAssistKill = nil
end

-- Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local Camera = workspace.CurrentCamera
local Mouse = LocalPlayer:GetMouse()

-- GUI
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "AimAssistGui"
screenGui.Parent = PlayerGui
screenGui.ResetOnSpawn = false
_G.AimAssistGui = screenGui

local frame = Instance.new("Frame")
frame.Name = "MainFrame"
frame.Size = UDim2.new(0, 260, 0, 170)
frame.Position = UDim2.new(0, 20, 0, 20)
frame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
frame.Active = true
frame.Draggable = true
frame.Parent = screenGui

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 25)
title.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
title.TextColor3 = Color3.new(1, 1, 1)
title.Text = "Aim Assist (Robust)"
title.Parent = frame

local predLabel = Instance.new("TextLabel")
predLabel.Size = UDim2.new(0, 160, 0, 25)
predLabel.Position = UDim2.new(0, 10, 0, 40)
predLabel.BackgroundTransparency = 1
predLabel.TextColor3 = Color3.new(1,1,1)
predLabel.Text = "Prediction Strength (forced 5):"
predLabel.TextXAlignment = Enum.TextXAlignment.Left
predLabel.Parent = frame

local predBox = Instance.new("TextBox")
predBox.Size = UDim2.new(0, 80, 0, 25)
predBox.Position = UDim2.new(0, 175, 0, 40)
predBox.BackgroundColor3 = Color3.fromRGB(70,70,70)
predBox.TextColor3 = Color3.new(1,1,1)
predBox.Text = "5"
predBox.ClearTextOnFocus = false
predBox.Parent = frame

-- State & tuning (core)
local aimActive = false
local lockedTarget = nil
local lockedHighlight = nil
local lockedBillboard = nil

local redHighlightedTarget = nil
local redHighlight = nil

local cameraOffset = Vector3.new(0, 10, -15)
local predictionStrength = 5 -- forced

local sampleWindow = 0.35
local maxSamples = 12
local baseProjectileSpeed = 18
local lateralBoost = 0.14
local targetBias = {head = 0.25, torso = 0.75}

-- Boost (Q)
local boostActive = false
local boostMultiplier = 1.0
local boostAmount = 0.40
local boostDuration = 2.0
local boostEndTime = 0

local charSamples = {} -- per-character recent sample positions

-- ======= NEW: Robust adaptation parameters =======
local EWMA_ALPHA = 0.35             -- how fast EWMA adapts (higher = faster)
local EWMA_HIT_MULT = 1.5           -- increase weight when trial produced a hit
local NORMALIZE_LATERAL = 3.5       -- studs — scale lateral displacement to [-1,1]
local OSCILLATION_SIGNCHANGE_LIMIT = 3 -- if sign changes > this during window => oscillating
local OSCILLATION_STD_MULTIPLIER = 0.9 -- relative threshold (stddev > mean*multiplier => oscillating)
local LATERAL_DELTA_THRESHOLD = 0.5  -- minimal lateral movement (studs) to be considered a direction
local MAX_LATERAL_FRACTION = 0.35    -- fraction of distance used as absolute cap for lateral offset
local MIN_EWMA_FOR_ACTION = 0.12     -- minimum absolute EWMA before we apply lateral offset

-- Adaptation data structure:
local targetProfiles = {} -- per-userid

local activeRecordConns = {}
_G.AimAssistActiveRecordConns = activeRecordConns

-- Windup & cooldown rules
local windups = { E = 0.75, Q = 1.7 }
local recordCooldowns = { E = 17.5, Q = 13.5 }
local lastPressTimes = { E = 0, Q = 0 }
-- per-target last recorded timestamp to avoid duplicate recordings from animations
local lastRecordedPerTarget = {}

-- Animation detection mapping (user-provided list; first is Q, second is E per group)
local animationToKey = {
    ["131430497821198"] = "Q", ["119181003138006"] = "E",
    ["101101433684051"] = "Q", ["116787687605496"] = "E",
    ["83685305553364"]  = "Q", ["99030950661794"]  = "E",
    ["100592913030351"] = "Q", ["81935774508746"]  = "E",
    ["109777684604906"] = "Q", ["105026134432828"] = "E",
}
local function extractAnimId(animIdString)
    if not animIdString then return nil end
    local id = tostring(animIdString):match("(%d+)")
    return id
end

-- store animation connection handles to cleanup
local animConns = {}
_G.AimAssistAnimConns = animConns

-- small helper used for charge snapping
local chargeSnapEpsilon = 0.01

-- Helper: determine whether local player is playing as Killer
-- Per your rule: if local player's Humanoid.Health is < 500 -> Survivor, otherwise Killer.
local function isPlayingAsKiller()
    local ch = LocalPlayer and LocalPlayer.Character
    if not ch then return false end
    local hum = ch:FindFirstChild("Humanoid")
    if not hum or not hum.Health then return false end
    return hum.Health >= 500
end

-- Utility: choose target parts
local function getTargetParts(character)
    if not character then return nil end
    local hrp = character:FindFirstChild("HumanoidRootPart")
    local head = character:FindFirstChild("Head")
    local upper = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
    local lower = character:FindFirstChild("LowerTorso")
    local primary = nil
    pcall(function() primary = character.PrimaryPart end)
    return { hrp = hrp, head = head, upper = upper, lower = lower, primary = primary }
end

local function computeTargetCenter(character)
    local parts = getTargetParts(character)
    if not parts then return nil end
    local torsoPart = parts.upper or parts.lower or parts.hrp or parts.primary
    local headPart = parts.head
    if torsoPart and headPart then
        return torsoPart.Position * targetBias.torso + headPart.Position * targetBias.head
    elseif torsoPart then
        return torsoPart.Position
    elseif headPart then
        return headPart.Position
    elseif parts.hrp then
        return parts.hrp.Position
    elseif parts.primary then
        return parts.primary.Position
    else
        for _, d in ipairs(character:GetChildren()) do
            if d:IsA("BasePart") then return d.Position end
        end
        return nil
    end
end

-- Sampling recent positions for smoothed velocity
local function sampleAllCharacters(dt)
    local now = tick()
    for _, pl in ipairs(Players:GetPlayers()) do
        if pl ~= LocalPlayer and pl.Character then
            local c = pl.Character
            local center = computeTargetCenter(c)
            if center then
                charSamples[c] = charSamples[c] or {}
                local arr = charSamples[c]
                table.insert(arr, 1, {pos = center, t = now})
                local i = #arr
                while i > 0 do
                    if now - arr[i].t > sampleWindow or #arr > maxSamples then
                        table.remove(arr, i)
                    end
                    i = i - 1
                end
            end
        end
    end
end

local function getSmoothedVelocity(character)
    local arr = charSamples[character]
    if not arr or #arr < 2 then return Vector3.new(0,0,0) end
    local newest = arr[1]
    local oldest = arr[#arr]
    local dt = newest.t - oldest.t
    if dt <= 0 then return Vector3.new(0,0,0) end
    local vel = (newest.pos - oldest.pos) / dt
    if vel.Magnitude < 0.05 then return Vector3.new(0,0,0) end
    return vel
end

local function findNearestTarget()
    local closest, dist = nil, math.huge
    for _, v in ipairs(Players:GetPlayers()) do
        if v ~= LocalPlayer and v.Character then
            local center = computeTargetCenter(v.Character)
            if center then
                local screenPos, onScreen = Camera:WorldToViewportPoint(center)
                if onScreen then
                    local mag = (Vector2.new(Mouse.X, Mouse.Y) - Vector2.new(screenPos.X, screenPos.Y)).Magnitude
                    if mag < dist then
                        dist = mag
                        closest = v.Character
                    end
                end
            end
        end
    end
    return closest
end

-- Helper: get character model from an instance (robust climb)
local function getCharacterFromInstance(inst)
    local cur = inst
    while cur and typeof(cur) == "Instance" do
        if cur:FindFirstChild("Humanoid") and cur:IsA("Model") then
            return cur
        end
        cur = cur.Parent
    end
    return nil
end

-- Visuals: locked (green) highlight + billboard
local function setLockedTargetVisuals(targetChar)
    -- remove previous locked visuals
    if lockedHighlight then pcall(function() lockedHighlight:Destroy() end) end
    if lockedBillboard then pcall(function() lockedBillboard:Destroy() end) end
    lockedHighlight = nil
    lockedBillboard = nil
    _G.AimAssistLockedHighlight = nil
    _G.AimAssistLockedBillboard = nil

    if not targetChar or not targetChar.Parent then return end

    local ok, highlight = pcall(function()
        local h = Instance.new("Highlight")
        h.Parent = workspace
        h.Adornee = targetChar
        h.FillTransparency = 1
        h.OutlineTransparency = 0
        h.OutlineColor = Color3.new(0,1,0)
        return h
    end)
    if ok then lockedHighlight = highlight; _G.AimAssistLockedHighlight = highlight end

    local attachPart = targetChar:FindFirstChild("Head") or targetChar:FindFirstChild("HumanoidRootPart")
    if attachPart then
        local bb = Instance.new("BillboardGui")
        bb.Size = UDim2.new(0,220,0,96)
        bb.Adornee = attachPart
        bb.AlwaysOnTop = true
        bb.StudsOffset = Vector3.new(0,2.8,0)
        bb.Parent = targetChar

        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(1, -6, 1, -6)
        label.Position = UDim2.new(0, 3, 0, 3)
        label.BackgroundTransparency = 0.5
        label.BackgroundColor3 = Color3.fromRGB(20,20,20)
        label.TextColor3 = Color3.new(1,1,1)
        label.TextWrapped = true
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.TextYAlignment = Enum.TextYAlignment.Top
        label.Font = Enum.Font.SourceSans
        label.TextSize = 12
        label.Parent = bb

        lockedBillboard = bb
        _G.AimAssistLockedBillboard = bb
    end
end

local function clearLockedTargetVisuals()
    if lockedHighlight then pcall(function() lockedHighlight:Destroy() end) end
    if lockedBillboard then pcall(function() lockedBillboard:Destroy() end) end
    lockedHighlight = nil
    lockedBillboard = nil
    _G.AimAssistLockedHighlight = nil
    _G.AimAssistLockedBillboard = nil
end

-- Red-highlighter visuals (for F)
local function setRedHighlight(targetChar)
    if redHighlight then pcall(function() redHighlight:Destroy() end) end
    redHighlight = nil
    redHighlightedTarget = nil
    _G.AimAssistRedHighlight = nil

    if not targetChar or not targetChar.Parent then return end
    local ok, h = pcall(function()
        local hlt = Instance.new("Highlight")
        hlt.Parent = workspace
        hlt.Adornee = targetChar
        hlt.FillTransparency = 1
        hlt.OutlineTransparency = 0
        hlt.OutlineColor = Color3.new(1,0,0)
        return hlt
    end)
    if ok then
        redHighlight = h
        redHighlightedTarget = targetChar
        _G.AimAssistRedHighlight = h
    end
end

local function clearRedHighlight()
    if redHighlight then pcall(function() redHighlight:Destroy() end) end
    redHighlight = nil
    redHighlightedTarget = nil
    _G.AimAssistRedHighlight = nil
end

-- Robust recorder: sample many lateral positions + health; compute stats; update EWMA
local function startRecordingFor(targetChar, key)
    if not targetChar or not targetChar.Parent then return end
    if not (key == "E" or key == "Q") then return end
    local pl = Players:GetPlayerFromCharacter(targetChar)
    if not pl then return end
    local uid = pl.UserId
    targetProfiles[uid] = targetProfiles[uid] or {
        E = {ewma = 0, trials = 0, hits = 0, oscillation = false},
        Q = {ewma = 0, trials = 0, hits = 0, oscillation = false}
    }
    local profile = targetProfiles[uid][key]

    -- per-target lastRecorded guard
    lastRecordedPerTarget[uid] = lastRecordedPerTarget[uid] or { E = 0, Q = 0 }
    local now = tick()
    if now - (lastRecordedPerTarget[uid][key] or 0) < (recordCooldowns[key] or 0) then
        return
    end
    lastRecordedPerTarget[uid][key] = now

    -- prepare sampling
    local tHRP = targetChar:FindFirstChild("HumanoidRootPart")
    local humanoidStart = targetChar:FindFirstChild("Humanoid")
    if not tHRP then return end

    local rightVec = Vector3.new(tHRP.CFrame.RightVector.X, 0, tHRP.CFrame.RightVector.Z)
    if rightVec.Magnitude < 0.001 then rightVec = Vector3.new(1,0,0) end
    rightVec = rightVec.Unit

    local samples = {}
    local healthStart = humanoidStart and humanoidStart.Health or nil
    local startT = tick()

    local conn
    conn = RunService.Heartbeat:Connect(function()
        if not targetChar or not targetChar.Parent then
            pcall(function() conn:Disconnect() end)
            return
        end
        local now = tick()
        local hrp = targetChar:FindFirstChild("HumanoidRootPart")
        local humanoidNow = targetChar:FindFirstChild("Humanoid")
        if hrp then
            local lateralCoord = hrp.Position:Dot(rightVec)
            table.insert(samples, lateralCoord)
            -- keep sample cap to reasonable number (avoid memory explosion)
            if #samples > 300 then table.remove(samples, 1) end
        end
        -- if player died/left mid-recording, still finish early based on what we have
        if now - startT >= 5 or (humanoidNow and humanoidNow.Health <= 0) then
            pcall(function() conn:Disconnect() end)
            -- compute statistics
            if #samples == 0 then
                -- no positional data -> treat as None
                profile.trials = profile.trials + 1
                return
            end
            -- compute mean delta (end - start) and stats
            local first = samples[1]
            local last = samples[#samples]
            local delta = last - first
            -- compute mean and stddev over samples
            local sum = 0
            for _, v in ipairs(samples) do sum = sum + v end
            local mean = sum / #samples
            local varSum = 0
            for _, v in ipairs(samples) do varSum = varSum + (v - mean)*(v - mean) end
            local stddev = math.sqrt(varSum / #samples)
            -- compute sign-changes across adjacent diffs
            local signChanges = 0
            local prevDiff = nil
            for i = 2, #samples do
                local d = samples[i] - samples[i-1]
                local sd = 0
                if d > 0.001 then sd = 1 elseif d < -0.001 then sd = -1 else sd = 0 end
                if prevDiff and sd ~= 0 and prevDiff ~= 0 and sd ~= prevDiff then
                    signChanges = signChanges + 1
                end
                if sd ~= 0 then prevDiff = sd end
            end

            -- determine direction trend based on delta and threshold
            local trend = "None"
            if delta > LATERAL_DELTA_THRESHOLD then trend = "Right"
            elseif delta < -LATERAL_DELTA_THRESHOLD then trend = "Left"
            else trend = "None" end

            -- oscillation detection: if many sign changes OR stddev large relative to mean displacement
            local oscillation = false
            if signChanges >= OSCILLATION_SIGNCHANGE_LIMIT then
                oscillation = true
            else
                if math.abs(delta) < 0.5 and stddev > math.abs(delta) * OSCILLATION_STD_MULTIPLIER + 0.15 then
                    oscillation = true
                end
            end

            -- hit detection
            local humanoidEnd = targetChar:FindFirstChild("Humanoid")
            local healthEnd = humanoidEnd and humanoidEnd.Health or healthStart
            local isHit = false
            if healthStart and healthEnd and (healthStart - healthEnd) >= 5 then isHit = true end

            -- update profile EWMA and counters
            local normalized = math.clamp(delta / NORMALIZE_LATERAL, -1, 1) -- -1..1
            local alpha = EWMA_ALPHA
            if isHit then
                alpha = math.clamp(EWMA_ALPHA * EWMA_HIT_MULT, 0, 0.95)
            end
            if oscillation then
                profile.ewma = profile.ewma * 0.92
            end
            profile.ewma = alpha * normalized + (1 - alpha) * (profile.ewma or 0)
            profile.trials = (profile.trials or 0) + 1
            if isHit then profile.hits = (profile.hits or 0) + 1 end
            profile.oscillation = oscillation

            return
        end
    end)
    table.insert(activeRecordConns, conn)
end

-- Prediction with EWMA usage and oscillation guarding
local function predictedAimPoint(myPos, targetChar, chargeKey)
    if not targetChar then return nil end
    local center = computeTargetCenter(targetChar)
    if not center then return nil end

    local vel = getSmoothedVelocity(targetChar)
    local relPos = center - myPos
    local distance = relPos.Magnitude
    local targetSpeed = vel.Magnitude

    local s = 1.0

    if targetSpeed < 0.4 or s <= 0 then
        return center
    end

    local projectileSpeed = baseProjectileSpeed * (0.5 + 9.5 * s)

    -- Quadratic intercept
    local a = vel:Dot(vel) - projectileSpeed * projectileSpeed
    local b = 2 * relPos:Dot(vel)
    local c = relPos:Dot(relPos)
    local t = nil
    local epsilon = 1e-6
    local discr = b*b - 4*a*c
    if discr >= 0 and math.abs(a) > epsilon then
        local sqrtD = math.sqrt(discr)
        local t1 = (-b - sqrtD) / (2*a)
        local t2 = (-b + sqrtD) / (2*a)
        local cand = {}
        if t1 > 0 then table.insert(cand, t1) end
        if t2 > 0 then table.insert(cand, t2) end
        if #cand > 0 then t = math.min(unpack(cand)) end
    end

    if not t or t <= 0 then
        local line = relPos.Magnitude > 0 and relPos.Unit or Vector3.new(0,0,1)
        local forwardComp = vel:Dot(line)
        local lateralVel = vel - forwardComp * line
        local lateralSpeed = lateralVel.Magnitude
        if lateralSpeed > 0.5 then
            t = math.clamp(distance / math.max(projectileSpeed, 1), 0.02, 3) + (distance / math.max(lateralSpeed * 15, 1)) * 0.2
        else
            t = distance / math.max(projectileSpeed, 1)
        end
        t = math.clamp(t, 0.02, 4)
    end

    local effectiveBoost = boostActive and boostMultiplier or 1.0
    local predicted = center + vel * t * effectiveBoost

    local line = relPos.Magnitude > 0 and relPos.Unit or Vector3.new(0,0,1)
    local lateralVel = vel - vel:Dot(line) * line
    predicted = predicted + lateralVel * lateralBoost * s

    -- ADAPTATION: use EWMA unless oscillation or too small EWMA
    if chargeKey and (chargeKey == "E" or chargeKey == "Q") then
        local owner = Players:GetPlayerFromCharacter(targetChar)
        if owner then
            local prof = targetProfiles[owner.UserId]
            if prof and prof[chargeKey] then
                local ewma = prof[chargeKey].ewma or 0
                local oscill = prof[chargeKey].oscillation
                if not oscill and math.abs(ewma) >= MIN_EWMA_FOR_ACTION then
                    local sign = (ewma > 0) and 1 or -1
                    local baseLat = math.abs(ewma) * (targetSpeed * t * 0.5 + (distance / 20))
                    local cap = distance * MAX_LATERAL_FRACTION
                    local lateralAmount = math.clamp(baseLat, 0, cap)
                    if targetChar:FindFirstChild("HumanoidRootPart") then
                        local tHRP = targetChar.HumanoidRootPart
                        local rightVec = Vector3.new(tHRP.CFrame.RightVector.X, 0, tHRP.CFrame.RightVector.Z)
                        if rightVec.Magnitude > 0.001 then
                            rightVec = rightVec.Unit
                            predicted = predicted + rightVec * sign * lateralAmount
                        end
                    end
                else
                    -- oscillation or tiny ewma -> aim toward center (do nothing)
                end
            end
        end
    end

    -- Blend between center and predicted by strength
    local blended = center:Lerp(predicted, s)
    return blended
end

-- ANIMATION DETECTION: attach AnimationPlayed listeners to characters to trigger recording
local function onCharacterAnimationPlayed(character)
    if not character or not character.Parent then return end
    local hum = character:FindFirstChild("Humanoid")
    if not hum then return end
    local conn = hum.AnimationPlayed:Connect(function(track)
        if not track or not track.Animation then return end
        local animId = extractAnimId(track.Animation.AnimationId)
        if not animId then return end
        local key = animationToKey[animId]
        if not key then return end
        -- key is "E" or "Q"; only record if local player is killer and cooldown per-target allows
        if not isPlayingAsKiller() then return end
        local owner = Players:GetPlayerFromCharacter(character)
        if not owner then return end
        local uid = owner.UserId
        lastRecordedPerTarget[uid] = lastRecordedPerTarget[uid] or {E = 0, Q = 0}
        local now = tick()
        if now - (lastRecordedPerTarget[uid][key] or 0) < (recordCooldowns[key] or 0) then
            return
        end
        -- mark now to prevent double recordings
        lastRecordedPerTarget[uid][key] = now
        -- start recording (fire-and-forget)
        pcall(function() startRecordingFor(character, key) end)
    end)
    table.insert(animConns, conn)
    _G.AimAssistAnimConns = animConns
end

-- attach to existing players' characters and to PlayerAdded/CharacterAdded
for _, pl in ipairs(Players:GetPlayers()) do
    if pl.Character then onCharacterAnimationPlayed(pl.Character) end
    pl.CharacterAdded:Connect(function(ch) onCharacterAnimationPlayed(ch) end)
end
Players.PlayerAdded:Connect(function(pl)
    pl.CharacterAdded:Connect(function(ch) onCharacterAnimationPlayed(ch) end)
end)

-- Input handling: toggles and E/Q (local presses still allowed to start recordings if you're Killer)
UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.P then
        screenGui.Enabled = not screenGui.Enabled
    end

    -- U: lock behavior — NOW ONLY acts when a red-highlighted target exists; otherwise does nothing
    if input.KeyCode == Enum.KeyCode.U then
        if redHighlightedTarget and redHighlightedTarget.Parent then
            -- toggle lock on red target only
            if aimActive and lockedTarget == redHighlightedTarget then
                aimActive = false
                lockedTarget = nil
                clearLockedTargetVisuals()
            else
                lockedTarget = redHighlightedTarget
                aimActive = true
                setLockedTargetVisuals(lockedTarget)
            end
        end
        -- if no red-highlighted target exists, do nothing
        return
    end

    -- E/Q starts recording (local input) — only record if playing as killer
    if input.KeyCode == Enum.KeyCode.E or input.KeyCode == Enum.KeyCode.Q then
        local keyStr = (input.KeyCode == Enum.KeyCode.E) and "E" or "Q"
        local now = tick()
        local prev = lastPressTimes[keyStr] or 0
        local canRecord = (now - prev) >= (recordCooldowns[keyStr] or 9999)
        lastPressTimes[keyStr] = now

        -- local-press recording gated by playing-as-killer as before
        if aimActive and lockedTarget and canRecord and isPlayingAsKiller() then
            pcall(function() startRecordingFor(lockedTarget, keyStr) end)
        end

        charging = true
        chargeKey = input.KeyCode
        chargeStart = tick()
        chargeDuration = windups[keyStr] or 0.75
        chargeSnapAt = chargeStart + chargeDuration - chargeSnapEpsilon

        if input.KeyCode == Enum.KeyCode.Q then
            boostActive = true
            boostMultiplier = 1.0 + boostAmount
            boostEndTime = tick() + boostDuration
        end
        return
    end

    -- F: toggle red-highlight on the player under the mouse (or nearest if none)
    if input.KeyCode == Enum.KeyCode.F then
        local targetChar = nil
        if Mouse and Mouse.Target then
            targetChar = getCharacterFromInstance(Mouse.Target)
        end
        if not targetChar then
            -- fallback to nearest on-screen
            targetChar = findNearestTarget()
        end
        if targetChar and targetChar.Parent then
            -- if already red-highlighted, clear; else set new red highlight
            if redHighlightedTarget == targetChar then
                clearRedHighlight()
                -- if we were locked to them, clear lock too
                if lockedTarget == targetChar then
                    aimActive = false
                    lockedTarget = nil
                    clearLockedTargetVisuals()
                end
            else
                -- highlight this one, and if there was a previous red, clear it first
                clearRedHighlight()
                setRedHighlight(targetChar)
                -- do NOT auto-lock here; U will lock explicitly
            end
        end
        return
    end

    if input.KeyCode == Enum.KeyCode.W then
        moveForward = true
    end
end)

UIS.InputEnded:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.W then
        moveForward = false
        local ch = LocalPlayer.Character
        if ch and ch:FindFirstChild("Humanoid") then ch.Humanoid:Move(Vector3.new(0,0,0), false) end
    end
end)

predBox.FocusLost:Connect(function()
    predBox.Text = "5"
    predictionStrength = 5
end)

local function buildTargetInfoText(targetChar)
    if not targetChar then return "" end
    local pl = Players:GetPlayerFromCharacter(targetChar)
    local uid = pl and pl.UserId or -1
    local prof = targetProfiles[uid] or { E = {ewma = 0, trials = 0, hits = 0, oscillation = false}, Q = {ewma = 0, trials = 0, hits = 0, oscillation = false} }
    local eTrials = prof.E.trials or 0
    local qTrials = prof.Q.trials or 0
    local eHits = prof.E.hits or 0
    local qHits = prof.Q.hits or 0
    local eEWMA = string.format("%.2f", prof.E.ewma or 0)
    local qEWMA = string.format("%.2f", prof.Q.ewma or 0)
    local eOsc = prof.E.oscillation and "Yes" or "No"
    local qOsc = prof.Q.oscillation and "Yes" or "No"
    local now = tick()
    local eCooldownLeft = math.max(0, (recordCooldowns.E - (now - (lastPressTimes.E or 0))))
    local qCooldownLeft = math.max(0, (recordCooldowns.Q - (now - (lastPressTimes.Q or 0))))
    local eRecordable = eCooldownLeft <= 0 and "Yes" or string.format("No(%.1fs)", eCooldownLeft)
    local qRecordable = qCooldownLeft <= 0 and "Yes" or string.format("No(%.1fs)", qCooldownLeft)

    local txt = ("E: ewma=%s trials=%d hits=%d osc=%s\nQ: ewma=%s trials=%d hits=%d osc=%s\nE rec: %s  Q rec: %s")
        :format(eEWMA, eTrials, eHits, eOsc, qEWMA, qTrials, qHits, qOsc, eRecordable, qRecordable)
    return txt
end

-- Main loop
_G.AimAssistConn = RunService.RenderStepped:Connect(function(dt)
    if boostActive and tick() > boostEndTime then
        boostActive = false
        boostMultiplier = 1.0
    end

    sampleAllCharacters(dt)

    -- update locked billboard text
    if lockedBillboard and lockedBillboard.Parent then
        local label = lockedBillboard:FindFirstChildOfClass("TextLabel")
        if label then label.Text = buildTargetInfoText(lockedBillboard.Parent) end
    end

    if aimActive and lockedTarget and lockedTarget.Parent then
        local myChar = LocalPlayer.Character
        if myChar and myChar:FindFirstChild("HumanoidRootPart") then
            local myHRP = myChar.HumanoidRootPart

            local aimPoint
            if charging and chargeKey then
                local keyStr = (chargeKey == Enum.KeyCode.E) and "E" or "Q"
                aimPoint = predictedAimPoint(myHRP.Position, lockedTarget, keyStr)
                    or (lockedTarget:FindFirstChild("HumanoidRootPart") and lockedTarget.HumanoidRootPart.Position)
            else
                aimPoint = predictedAimPoint(myHRP.Position, lockedTarget)
                    or (lockedTarget:FindFirstChild("HumanoidRootPart") and lockedTarget.HumanoidRootPart.Position)
            end

            if not aimPoint then return end
            local dirVector = aimPoint - myHRP.Position
            if dirVector.Magnitude < 0.001 then
                dirVector = (lockedTarget:FindFirstChild("HumanoidRootPart") and (lockedTarget.HumanoidRootPart.Position - myHRP.Position)) or Vector3.new(0,0,1)
                if dirVector.Magnitude < 0.001 then dirVector = Vector3.new(0,0,1) end
            end

            local dir = dirVector.Unit
            local camPos = myHRP.Position - dir * math.abs(cameraOffset.Z)
            camPos = camPos + Vector3.new(0, cameraOffset.Y, 0)
            Camera.CFrame = CFrame.new(camPos, aimPoint)
        end
    end

    -- auto-complete charge
    if charging then
        local now = tick()
        if chargeStart > 0 and now >= (chargeStart + chargeDuration) then
            charging = false
            chargeKey = nil
            chargeStart = 0
            chargeDuration = 0
            chargeSnapAt = 0
        end
    end
end)

-- Studio debug
if RunService:IsStudio() then
    warn("[AimAssist] Robust adaptation + animation detection + red-highlighter (F-only toggle) loaded.")
end
