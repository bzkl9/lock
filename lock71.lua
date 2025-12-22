-- Aim Assist — Post-windup only recording (FULL-FILE) — LAST-DIRECTION + FIXED LATERAL
-- Updated: ignore trivial pushes removed; robust direction detection, logging + hysteresis + temporary immediate trend + regression ensemble for short windows

-- Kill previous instance (robust)
if _G.AimAssistKill and type(_G.AimAssistKill) == "function" then
    pcall(_G.AimAssistKill)
end

_G.AimAssistKill = function()
    if _G.AimAssistConn and type(_G.AimAssistConn.Disconnect) == "function" then
        pcall(function() _G.AimAssistConn:Disconnect() end)
        _G.AimAssistConn = nil
    end
    if _G.AimAssistAnimConns then
        for _,c in ipairs(_G.AimAssistAnimConns) do
            pcall(function() if c and type(c.Disconnect) == "function" then c:Disconnect() end end)
        end
        _G.AimAssistAnimConns = nil
    end
    if _G.AimAssistActiveRecordConns then
        for _,c in ipairs(_G.AimAssistActiveRecordConns) do
            pcall(function() if c and type(c.Disconnect) == "function" then c:Disconnect() end end)
        end
        _G.AimAssistActiveRecordConns = nil
    end
    if _G.AimAssistGui and _G.AimAssistGui.Parent then
        pcall(function() _G.AimAssistGui:Destroy() end)
        _G.AimAssistGui = nil
    end
    pcall(function()
        for _,inst in ipairs(workspace:GetDescendants()) do
            if inst and inst.Name and (inst.Name == "AimAssistLockedHighlight" or inst.Name == "AimAssistRedHighlight" or inst.Name == "AimAssistLockedBillboard") then
                pcall(function() inst:Destroy() end)
            end
        end
    end)
    pcall(function()
        local pl = game:GetService("Players").LocalPlayer
        if pl and pl:FindFirstChild("PlayerGui") then
            local sg = pl.PlayerGui:FindFirstChild("AimAssistGui")
            if sg then pcall(function() sg:Destroy() end) end
        end
    end)
    _G.AimAssistLockedHighlight = nil
    _G.AimAssistLockedBillboard = nil
    _G.AimAssistRedHighlight = nil
    _G.AimAssistActiveRecordConns = nil
    _G.AimAssistAnimConns = nil
    _G.AimAssistGui = nil
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

-- GUI (small)
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "AimAssistGui"
screenGui.Parent = PlayerGui
screenGui.ResetOnSpawn = false
_G.AimAssistGui = screenGui

local frame = Instance.new("Frame")
frame.Name = "MainFrame"
frame.Size = UDim2.new(0, 320, 0, 180)
frame.Position = UDim2.new(0, 12, 0, 12)
frame.BackgroundColor3 = Color3.fromRGB(30,30,30)
frame.Active = true
frame.Draggable = true
frame.Parent = screenGui

local title = Instance.new("TextLabel")
title.Name = "AimAssistTitle"
title.Size = UDim2.new(1,0,0,26)
title.Position = UDim2.new(0,0,0,0)
title.Text = "AimAssist — Input-driven adaptation (fixed)"
title.TextColor3 = Color3.new(1,1,1)
title.Font = Enum.Font.SourceSansBold
title.TextSize = 14
title.BackgroundColor3 = Color3.fromRGB(50,50,50)
title.Parent = frame

local predLabel = Instance.new("TextLabel")
predLabel.Name = "PredLabel"
predLabel.Size = UDim2.new(0,160,0,20)
predLabel.Position = UDim2.new(0,10,0,40)
predLabel.BackgroundTransparency = 1
predLabel.TextColor3 = Color3.new(1,1,1)
predLabel.Text = "Prediction Strength (1-9):"
predLabel.TextXAlignment = Enum.TextXAlignment.Left
predLabel.Parent = frame

local predBox = Instance.new("TextBox")
predBox.Name = "PredBox"
predBox.Size = UDim2.new(0,80,0,20)
predBox.Position = UDim2.new(0,200,0,40)
predBox.BackgroundColor3 = Color3.fromRGB(70,70,70)
predBox.TextColor3 = Color3.new(1,1,1)
predBox.Text = "5"
predBox.ClearTextOnFocus = false
predBox.TextXAlignment = Enum.TextXAlignment.Center
predBox.Parent = frame

-- params
local cameraOffset = Vector3.new(0,10,-15)
local predictionStrength = 5

local sampleWindow = 0.35
local maxSamples = 12
local baseProjectileSpeed = 18
local lateralBoost = 0.14
local targetBias = {head = 0.25, torso = 0.75}

-- recording/adaptation params
local RECORD_MAX_DISTANCE = 60
local RECENT_HISTORY_KEEP = 24

local ADAPT_MIN_TRIALS = 7
local ADAPT_EARLY_SAME = 3
local ADAPT_MIN_AVG_DELTA = 0.6
local ADAPT_MIN_LATERAL = 0.5
local MAX_LATERAL_FRACTION = 0.35

local PRE_RELEASE_MARGIN = 0.25 -- unused for animation gating now

-- NEW: post-windup record & fixed-lateral settings
local POST_RECORD_DURATION = 0.8        -- seconds post windup (adjust as needed)
local MAX_DODGE_DISTANCE = 6.0
local FIXED_LATERAL = 4.5
local POST_EDGE_WINDOW = 0.18
local EWMA_ALPHA = 0.25
local PRE_RECORD_WINDOW = 0.18
local VEL_DIR_THRESHOLD = 0.6

-- NEW: robust detection tuning (tuned for shorter dodges)
local MIN_MOVE_MAG = 0.4                -- baseline minimum absolute raw window movement to count (studs) (kept for reference but not used for gating)
local DIR_THRESHOLD = 0.5
local SMALL_DELTA_THRESHOLD = 0.12      -- per-sample delta threshold for sign voting
local HYSTERESIS_REQUIRED = 2
local STALE_TREND_TIMEOUT = 4.0         -- seconds after which an old trend expires if nothing new

-- NEW: temporary/immediate trend tuning (helps very short post-record windows)
local IMMEDIATE_TREND_MIN_PEAK = 0.9     -- peak (studs) required to instantly apply a temporary trend
local TEMPORARY_TREND_DURATION = 1.2     -- seconds the temporary trend remains active

-- NEW: windup surprise/snap settings (added)
local PRE_SNAP_TIME = 0.10               -- seconds before windup end to force-snap to predicted side (user requested ~0.1s)

-- NEW: prediction lead limiting (added per request)
local MAX_LEAD_ABS = 1000000                 -- absolute cap for forward lead (studs)
local MAX_LEAD_FRACTION = 1.0          -- alternative cap = distance * this fraction; effective cap = min(MAX_LEAD_ABS, distance*MAX_LEAD_FRACTION)

-- state
local charSamples = {}
local targetProfiles = {}
local activeRecordConns = {}
_G.AimAssistActiveRecordConns = activeRecordConns
local animConns = {}
_G.AimAssistAnimConns = animConns
local lastPredictions = {}

-- input/charge state
local aimActive = false
local lockedTarget = nil
local charging = false
local chargeKey = nil
local chargeStart = 0
local chargeExpires = 0
local windups = { E = 0.75, Q = 1.7 }

-- animation id => key map (user-supplied)
local animationToKey = {
    ["131430497821198"] = "Q", ["119181003138006"] = "E",
    ["101101433684051"] = "Q", ["116787687605496"] = "E",
    ["83685305553364"]  = "Q", ["99030950661794"]  = "E",
    ["100592913030351"] = "Q", ["81935774508746"]  = "E",
    ["109777684604906"] = "Q", ["105026134432828"] = "E",
}

-- helpers
local function extractAnimId(animIdString)
    if not animIdString then return nil end
    local id = tostring(animIdString):match("(%d+)")
    return id
end

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
        for _,d in ipairs(character:GetChildren()) do
            if d:IsA("BasePart") then return d.Position end
        end
    end
    return nil
end

local function getSmoothedVelocity(character)
    local arr = charSamples[character]
    if not arr or #arr < 2 then return Vector3.new(0,0,0) end
    local newest = arr[1]; local oldest = arr[#arr]
    local dt = newest.t - oldest.t
    if dt <= 0 then return Vector3.new(0,0,0) end
    local vel = (newest.pos - oldest.pos) / dt
    -- suppress tiny motions like in 6.5 to reduce jitter:
    if vel.Magnitude < 0.05 then return Vector3.new(0,0,0) end
    return vel
end

local function sampleAllCharacters(dt)
    local now = tick()
    for _,pl in ipairs(Players:GetPlayers()) do
        if pl and pl.Character and pl.Character.Parent then
            local c = pl.Character
            local center = computeTargetCenter(c)
            if center then
                charSamples[c] = charSamples[c] or {}
                local arr = charSamples[c]
                table.insert(arr,1,{pos = center, t = now})
                local j = #arr
                while j > 0 do
                    if now - arr[j].t > sampleWindow or #arr > maxSamples then
                        table.remove(arr,j)
                    end
                    j = j - 1
                end
                local prof = targetProfiles[pl.UserId]
                if prof and #arr >= 2 then
                    local newest = arr[1]; local oldest = arr[#arr]
                    local dtv = newest.t - oldest.t
                    if dtv > 0 then
                        local mag = ((newest.pos - oldest.pos)/dtv).Magnitude
                        prof.runSpeed = (prof.runSpeed or 25) * 0.88 + math.clamp(mag,0,200) * 0.12
                    end
                end
            end
        end
    end
end

local function findNearestTarget()
    local closest, dist = nil, math.huge
    for _,v in ipairs(Players:GetPlayers()) do
        if v ~= LocalPlayer and v.Character and v.Character.Parent then
            local center = computeTargetCenter(v.Character)
            if center then
                local screenPos, onScreen = Camera:WorldToViewportPoint(center)
                if onScreen then
                    local mag = (Vector2.new(Mouse.X,Mouse.Y) - Vector2.new(screenPos.X,screenPos.Y)).Magnitude
                    if mag < dist then dist = mag; closest = v.Character end
                end
            end
        end
    end
    return closest
end

local function getCharacterFromInstance(inst)
    local cur = inst
    while cur and typeof(cur) == "Instance" do
        if cur:IsA("Model") and cur:FindFirstChild("Humanoid") then return cur end
        cur = cur.Parent
    end
    return nil
end

-- visuals
local lockedHighlight, lockedBillboard, redHighlight, redHighlightedTarget
local function setLockedTargetVisuals(targetChar)
    if lockedHighlight then pcall(function() lockedHighlight:Destroy() end) end
    if lockedBillboard then pcall(function() lockedBillboard:Destroy() end) end
    lockedHighlight = nil; lockedBillboard = nil; _G.AimAssistLockedHighlight = nil; _G.AimAssistLockedBillboard = nil
    if not targetChar or not targetChar.Parent then return end
    local ok, h = pcall(function()
        local hi = Instance.new("Highlight")
        hi.Name = "AimAssistLockedHighlight"
        hi.Adornee = targetChar
        hi.Parent = workspace
        hi.FillTransparency = 1
        hi.OutlineTransparency = 0
        hi.OutlineColor = Color3.new(0,1,0)
        return hi
    end)
    if ok then lockedHighlight = h; _G.AimAssistLockedHighlight = h end
    local attachPart = targetChar:FindFirstChild("Head") or targetChar:FindFirstChild("HumanoidRootPart")
    if attachPart then
        local bb = Instance.new("BillboardGui")
        bb.Name = "AimAssistLockedBillboard"
        bb.Adornee = attachPart
        bb.Size = UDim2.new(0,220,0,80)
        bb.AlwaysOnTop = true
        bb.StudsOffset = Vector3.new(0,2.8,0)
        bb.Parent = targetChar
        local label = Instance.new("TextLabel")
        label.Name = "AimAssistLockedLabel"
        label.Size = UDim2.new(1,-6,1,-6)
        label.Position = UDim2.new(0,3,0,3)
        label.BackgroundTransparency = 0.5
        label.BackgroundColor3 = Color3.fromRGB(20,20,20)
        label.TextColor3 = Color3.new(1,1,1)
        label.Font = Enum.Font.SourceSans
        label.TextSize = 12
        label.Parent = bb
        lockedBillboard = bb; _G.AimAssistLockedBillboard = bb
    end
end

local function clearLockedTargetVisuals()
    if lockedHighlight then pcall(function() lockedHighlight:Destroy() end) end
    if lockedBillboard then pcall(function() lockedBillboard:Destroy() end) end
    lockedHighlight = nil; lockedBillboard = nil; _G.AimAssistLockedHighlight = nil; _G.AimAssistLockedBillboard = nil
end

local function setRedHighlight(targetChar)
    if redHighlight then pcall(function() redHighlight:Destroy() end) end
    redHighlight = nil; redHighlightedTarget = nil; _G.AimAssistRedHighlight = nil
    if not targetChar or not targetChar.Parent then return end
    local ok, h = pcall(function()
        local hi = Instance.new("Highlight")
        hi.Name = "AimAssistRedHighlight"
        hi.Adornee = targetChar
        hi.Parent = workspace
        hi.FillTransparency = 1
        hi.OutlineTransparency = 0
        hi.OutlineColor = Color3.new(1,0,0)
        return hi
    end)
    if ok then redHighlight = h; redHighlightedTarget = targetChar; _G.AimAssistRedHighlight = h end
end

local function clearRedHighlight()
    if redHighlight then pcall(function() redHighlight:Destroy() end) end
    redHighlight = nil; redHighlightedTarget = nil; _G.AimAssistRedHighlight = nil
end

-- NEW: start a post-windup recording immediately (no pre-windup samples).
-- Robust detection:
--  - compute a baseline (first-window average)
--  - find peak extreme (min / max) across the whole recording
--  - decide direction based on ensemble: peak, regression slope, last-window delta
--  - fallback to voting if ensemble weak
--  - allow immediate temporary trend application for short windows when the peak/slope is strong
-- NOTE: minimal-movement gating removed — any non-zero finalDecision is counted now
local function startPostWindupRecording(targetChar, key)
    if not targetChar or not targetChar.Parent then return end
    if not (key == "E" or key == "Q") then return end
    local pl = Players:GetPlayerFromCharacter(targetChar)
    if not pl then return end
    local uid = pl.UserId
    targetProfiles[uid] = targetProfiles[uid] or {
        E = {history = {}, trials = 0, hits = 0},
        Q = {history = {}, trials = 0, hits = 0},
        allHistory = {},
        runSpeed = 25,
        lastCast = nil,
        isCasting = false,
        ewmaDelta = nil,
        lastTrend = nil,
        trendStableCount = 0,
        lastTrendTime = nil,
        temporaryTrend = nil,
        temporaryTrendExpiry = nil
    }
    local prof = targetProfiles[uid][key]

    local tHRP = targetChar:FindFirstChild("HumanoidRootPart")
    if not tHRP then return end

    -- discard if shooter is far away
    local shooterHRP = LocalPlayer and LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") or nil
    if shooterHRP and (shooterHRP.Position - tHRP.Position).Magnitude > RECORD_MAX_DISTANCE then
        return
    end

    local shooterPos = shooterHRP and shooterHRP.Position or nil

    -- UNIFY rightDir with prediction path: direction pointing to target's RIGHT relative to shooter.
    local rightDir = nil
    if shooterHRP and tHRP then
        local rel = shooterHRP.Position - tHRP.Position
        local flat = Vector3.new(rel.X,0,rel.Z)
        if flat.Magnitude < 0.001 then
            rightDir = Vector3.new(tHRP.CFrame.RightVector.X,0,tHRP.CFrame.RightVector.Z)
            if rightDir.Magnitude < 0.001 then rightDir = Vector3.new(1,0,0) else rightDir = rightDir.Unit end
        else
            rightDir = Vector3.new(-flat.Z,0,flat.X)
            if rightDir.Magnitude < 0.001 then rightDir = Vector3.new(1,0,0) else rightDir = rightDir.Unit end
        end
    else
        rightDir = Vector3.new(tHRP.CFrame.RightVector.X,0,tHRP.CFrame.RightVector.Z)
        if rightDir.Magnitude < 0.001 then rightDir = Vector3.new(1,0,0) else rightDir = rightDir.Unit end
    end

    local samples = {}
    local startT = tick()
    local endT = startT + POST_RECORD_DURATION
    local hitDetected = false
    local startHealth = targetChar:FindFirstChild("Humanoid") and targetChar.Humanoid.Health or nil

    task.spawn(function()
        task.delay(POST_RECORD_DURATION, function()
            if not targetChar or not targetChar.Parent then return end
            local hum = targetChar:FindFirstChild("Humanoid")
            if hum and startHealth and (startHealth - hum.Health) >= 10 then
                hitDetected = true
                targetProfiles[uid][key].hits = (targetProfiles[uid][key].hits or 0) + 1
            end
        end)
    end)

    local conn
    conn = RunService.Heartbeat:Connect(function()
        if not targetChar or not targetChar.Parent then pcall(function() conn:Disconnect() end) return end
        local now = tick()
        local hrp = targetChar:FindFirstChild("HumanoidRootPart")
        if hrp then
            local ref = shooterPos or tHRP.Position
            local lateral = (hrp.Position - ref):Dot(rightDir)
            table.insert(samples,1,{val = lateral, t = now})
            -- prune outside window
            while #samples > 0 and (now - samples[#samples].t) > (POST_RECORD_DURATION + 0.05) do
                table.remove(samples,#samples)
            end
            if #samples > 2000 then table.remove(samples,#samples) end
        end

        if now >= endT or (targetChar:FindFirstChild("Humanoid") and targetChar.Humanoid.Health <= 0) then
            pcall(function() conn:Disconnect() end)
            for i=#activeRecordConns,1,-1 do if activeRecordConns[i] == conn then table.remove(activeRecordConns,i) end end

            if #samples == 0 then
                warn(("[AimAssist] post-record EMPTY uid=%d key=%s"):format(uid,key))
                return
            end

            -- compute first-window baseline average (earliest samples)
            local M = #samples
            local earliestTime = samples[M].t
            local latestTime = samples[1].t
            local totalSpan = math.max(1e-4, latestTime - earliestTime)

            -- make the edge window a little more generous for very short spans
            local windowLen = math.min(POST_EDGE_WINDOW, math.max(0.06, totalSpan * 0.25))
            local firstWindowEnd = earliestTime + windowLen
            if firstWindowEnd < earliestTime then firstWindowEnd = earliestTime end

            local firstSum, firstCnt = 0, 0
            local lastSum, lastCnt = 0, 0
            local minVal, maxVal = math.huge, -math.huge
            for i = 1, M do
                local s = samples[i]
                if s.t <= firstWindowEnd then
                    firstSum = firstSum + s.val; firstCnt = firstCnt + 1
                end
                if s.t >= (latestTime - windowLen) then
                    lastSum = lastSum + s.val; lastCnt = lastCnt + 1
                end
                if s.val < minVal then minVal = s.val end
                if s.val > maxVal then maxVal = s.val end
            end

            -- fallback baseline if first window empty: average the oldest up to 3 samples
            local baseline
            if firstCnt > 0 then
                baseline = firstSum / firstCnt
            else
                local k = math.min(3, M)
                local ssum = 0
                for ii = M, math.max(1, M - k + 1), -1 do
                    ssum = ssum + samples[ii].val
                end
                baseline = ssum / math.max(1, k)
            end
            local lastAvg = (lastCnt > 0) and (lastSum / lastCnt) or samples[1].val

            -- peak-based delta: which extreme (min or max) deviates more from baseline?
            local peakUp = maxVal - baseline
            local peakDown = minVal - baseline
            local peakDelta = 0
            local peakSign = 0
            if math.abs(peakUp) >= math.abs(peakDown) then
                peakDelta = peakUp
                peakSign = (peakUp > 0) and 1 or ((peakUp < 0) and -1 or 0)
            else
                peakDelta = peakDown
                peakSign = (peakDown > 0) and 1 or ((peakDown < 0) and -1 or 0)
            end

            -- raw last-window delta (fallback / additional signal)
            local rawDelta = lastAvg - baseline
            local rawSign = (rawDelta > 0) and 1 or ((rawDelta < 0) and -1 or 0)

            -- per-sample delta voting (newest -> older)
            local posCount, negCount, significantCount = 0,0,0
            for i = 1, M-1 do
                local d = samples[i].val - samples[i+1].val
                if math.abs(d) >= SMALL_DELTA_THRESHOLD then
                    significantCount = significantCount + 1
                    if d > 0 then posCount = posCount + 1 else negCount = negCount + 1 end
                end
            end

            local voteDecision = 0
            if significantCount > 0 then
                if posCount > negCount then voteDecision = 1
                elseif negCount > posCount then voteDecision = -1
                else voteDecision = 0 end
            end

            -- compute regression slope (least squares) over samples (time relative to earliestTime)
            local meanT, meanV = 0, 0
            for i = 1, M do
                local s = samples[i]
                meanT = meanT + (s.t - earliestTime)
                meanV = meanV + s.val
            end
            meanT = meanT / M
            meanV = meanV / M
            local num, den = 0, 0
            for i = 1, M do
                local s = samples[i]
                local x = (s.t - earliestTime) - meanT
                local y = s.val - meanV
                num = num + x * y
                den = den + x * x
            end
            local slope = 0
            if den > 0 then slope = num / den else slope = 0 end
            -- slopeUnits studs per second; convert to total-studs across the recording for comparison
            local slopeTotal = math.abs(slope) * totalSpan
            local slopeSign = (slope > 0) and 1 or ((slope < 0) and -1 or 0)

            -- Ensemble scoring: combine peak, slope, raw into a weighted score
            local w_peak, w_slope, w_raw = 1.0, 1.15, 0.6
            local peakScore = math.abs(peakDelta)
            local rawScore = math.abs(rawDelta)
            local slopeScore = slopeTotal
            local combinedScore = (w_peak * (peakSign) * peakScore) + (w_slope * (slopeSign) * slopeScore) + (w_raw * (rawSign) * rawScore)

            local finalDecision = 0
            if math.abs(combinedScore) >= DIR_THRESHOLD then
                finalDecision = (combinedScore > 0) and 1 or -1
            else
                -- fallback to previous voting rules if ensemble weak
                if math.abs(peakDelta) >= DIR_THRESHOLD then
                    finalDecision = (peakDelta > 0) and 1 or -1
                else
                    if math.abs(rawDelta) >= DIR_THRESHOLD then
                        finalDecision = (rawDelta > 0) and 1 or -1
                    else
                        if voteDecision ~= 0 and (math.abs(posCount - negCount) >= math.max(2, math.floor(significantCount*0.5))) then
                            finalDecision = voteDecision
                        else
                            finalDecision = 0
                        end
                    end
                end
            end

            -- determine if this should *count* as a dodge
            -- MINIMUM-MOVE GATING REMOVED: any non-zero finalDecision counts now
            local counted = false
            if finalDecision ~= 0 then
                counted = true
            end

            -- Hysteresis: update stored lastTrend only when counts agree for consecutive recorded detections
            local profAll = targetProfiles[uid]
            local prevTrend = profAll.lastTrend
            local prevCount = profAll.trendStableCount or 0
            local newTrendName = (finalDecision > 0) and "Right" or (finalDecision < 0) and "Left" or "None"

            -- Immediate temporary trend: if this single detection is strong, allow a temporary immediate trend
            local durationScale = math.clamp((POST_RECORD_DURATION / 1.5), 0.5, 1.0)
            local immediateThreshold = math.max(IMMEDIATE_TREND_MIN_PEAK * durationScale, 0.5)
            if counted and (math.abs(peakDelta) >= immediateThreshold or slopeScore >= immediateThreshold) then
                profAll.temporaryTrend = newTrendName
                profAll.temporaryTrendExpiry = tick() + TEMPORARY_TREND_DURATION
                warn(("[AimAssist] TEMP TREND uid=%d key=%s trend=%s peak=%.2f slope=%.2f expiry=%.2f"):format(uid, key, newTrendName, peakDelta, slopeTotal, profAll.temporaryTrendExpiry))
            end

            if finalDecision ~= 0 and counted then
                if prevTrend == newTrendName then
                    profAll.trendStableCount = (profAll.trendStableCount or 0) + 1
                else
                    profAll.trendStableCount = 1
                end
                if profAll.trendStableCount >= HYSTERESIS_REQUIRED then
                    profAll.lastTrend = newTrendName
                    profAll.lastTrendTime = tick()
                end
            else
                profAll.trendStableCount = 0
                if profAll.lastTrend and profAll.lastTrendTime and (tick() - profAll.lastTrendTime) > STALE_TREND_TIMEOUT then
                    profAll.lastTrend = nil
                    profAll.lastTrendTime = nil
                end
            end

            -- expire temporary trend if needed (safety)
            if profAll.temporaryTrend and profAll.temporaryTrendExpiry and tick() > profAll.temporaryTrendExpiry then
                profAll.temporaryTrend = nil
                profAll.temporaryTrendExpiry = nil
            end

            -- record history only if counted
            if counted then
                prof.trials = (prof.trials or 0) + 1
                if hitDetected then prof.hits = (prof.hits or 0) + 1 end

                local clampedDelta = math.clamp(peakDelta, -MAX_DODGE_DISTANCE, MAX_DODGE_DISTANCE)
                local trial = {
                    delta = clampedDelta,
                    normalized = (MAX_DODGE_DISTANCE > 0) and (clampedDelta / MAX_DODGE_DISTANCE) or 0,
                    hit = hitDetected,
                    trend = newTrendName,
                    duration = totalSpan,
                    t = tick(),
                    firstAvg = baseline,
                    lastAvg = lastAvg,
                    rawDelta = rawDelta,
                    postSamples = M,
                    posCount = posCount,
                    negCount = negCount,
                    significantCount = significantCount,
                    peakVal = (peakDelta >= 0) and maxVal or minVal,
                    slopeTotal = slopeTotal
                }
                table.insert(prof.history,1,trial)
                while #prof.history > RECENT_HISTORY_KEEP do table.remove(prof.history) end

                local all = targetProfiles[uid].allHistory
                table.insert(all,1,trial)
                while #all > RECENT_HISTORY_KEEP do table.remove(all) end

                -- update EWMA smoothing for avg delta
                local prev = profAll.ewmaDelta or 0
                profAll.ewmaDelta = EWMA_ALPHA * (trial.delta or 0) + (1 - EWMA_ALPHA) * prev
            end

            -- Diagnostic/log line — VERY detailed so you can see what's happening
            do
                local decidedStr = (finalDecision == 1 and "Right" or (finalDecision == -1 and "Left" or "None"))
                local countedStr = counted and "YES" or "NO"
                local prevTrendStr = prevTrend or "nil"
                local afterTrendStr = profAll.lastTrend or "nil"
                warn(("[AimAssist][DET] uid=%d key=%s baseline=%.3f peakDelta=%.3f raw=%.3f slope=%.3f last=%.3f pos=%d neg=%d sig=%d vote=%s combined=%.3f decided=%s counted=%s prevTrend=%s->%s stable=%d")
                    :format(uid, key, baseline, peakDelta, rawDelta, slopeTotal, lastAvg, posCount, negCount, significantCount,
                        (voteDecision==1 and "Right" or (voteDecision==-1 and "Left" or "None")),
                        combinedScore, decidedStr, countedStr, prevTrendStr, afterTrendStr, profAll.trendStableCount or 0))
            end

            return
        end
    end)

    table.insert(activeRecordConns, conn)
end

-- helper: schedule post-windup recording (will start after `expires` time)
local function schedulePostWindupRecording(targetChar, key, expires)
    if not targetChar or not targetChar.Parent then return end
    if not expires then
        startPostWindupRecording(targetChar, key)
        return
    end
    local waitTime = expires - tick()
    if waitTime <= 0 then
        startPostWindupRecording(targetChar, key)
        return
    end
    task.spawn(function()
        task.delay(waitTime, function()
            if not targetChar or not targetChar.Parent then return end
            startPostWindupRecording(targetChar, key)
        end)
    end)
end

-- adaptation decision (unchanged)
local function computeAdaptDecisionForPlayer(pl)
    if not pl then return { adapt = false } end
    local uid = pl.UserId
    local profAll = targetProfiles[uid]
    if not profAll then return { adapt = false } end

    local history = profAll.allHistory or {}
    if #history == 0 then return { adapt = false } end

    local leftCount, rightCount, noneCount = 0,0,0
    local sumDelta, sumAbsDelta, sumDur, nDelta = 0,0,0,0
    for i = 1, math.min(#history, RECENT_HISTORY_KEEP) do
        local t = history[i]
        if t then
            if t.trend == "Left" then leftCount = leftCount + 1
            elseif t.trend == "Right" then rightCount = rightCount + 1
            else noneCount = noneCount + 1 end
            if t.delta and math.abs(t.delta) > 0.01 then
                sumDelta = sumDelta + t.delta
                sumAbsDelta = sumAbsDelta + math.abs(t.delta)
                sumDur = sumDur + (t.duration or 0)
                nDelta = nDelta + 1
            end
        end
    end

    local rawAvgDelta = (nDelta > 0) and (sumDelta / nDelta) or 0
    local avgAbsDelta = (nDelta > 0) and (sumAbsDelta / nDelta) or 0
    local avgDur = (nDelta > 0) and (sumDur / nDelta) or 0
    local totalTrials = ((profAll.E and profAll.E.trials) or 0) + ((profAll.Q and profAll.Q.trials) or 0)
    local totalHits = ((profAll.E and profAll.E.hits) or 0) + ((profAll.Q and profAll.Q.hits) or 0)

    local avgDelta = profAll.ewmaDelta or rawAvgDelta

    local preferred = "None"
    if leftCount > rightCount then preferred = "Left"
    elseif rightCount > leftCount then preferred = "Right" end

    local function lastNSame(n)
        if #history < n then return false end
        local trend = history[1].trend
        if trend == "None" then return false end
        for i = 2, n do
            if history[i].trend ~= trend then return false end
        end
        return true, trend
    end
    local sameOK, sameTrend = lastNSame(ADAPT_EARLY_SAME)

    local adapt = false
    if totalTrials >= ADAPT_MIN_TRIALS then adapt = true end
    if sameOK then adapt = true end
    if math.abs(avgDelta) >= ADAPT_MIN_AVG_DELTA and totalTrials >= 3 then adapt = true end

    return {
        adapt = adapt,
        preferred = preferred,
        avgDelta = avgDelta,
        avgAbsDelta = avgAbsDelta,
        avgDur = avgDur,
        leftCount = leftCount,
        rightCount = rightCount,
        totalTrials = totalTrials,
        totalHits = totalHits,
        recentCount = nDelta
    }
end

-- computeLateralStuds (kept for diagnostics but prediction uses FIXED_LATERAL now)
local function computeLateralStuds(info, runSpeed, distance, t)
    if not info or not info.adapt then return 0 end
    local baseObs = math.abs(info.avgAbsDelta or 0)
    if baseObs < ADAPT_MIN_LATERAL then
        return 0
    end
    local durFactor = 1.0
    if info.avgDur and info.avgDur > 0 then
        durFactor = math.clamp(info.avgDur / 0.5, 0.45, 1.25)
    end
    local lateral = baseObs * durFactor
    local cap = distance * MAX_LATERAL_FRACTION
    lateral = math.clamp(lateral, ADAPT_MIN_LATERAL, cap)
    if info.avgDelta and info.avgDelta < 0 then lateral = -lateral end
    return lateral
end

-- prediction + adaptation
local boostActive = false
local boostMultiplier = 1.0

-- predictedAimPoint: uses FIXED_LATERAL when adapt allowed and lastTrend (or temporaryTrend) is available.
-- predictedAimPoint (REPLACEMENT)
local function predictedAimPoint(myPos, targetChar, chargeKey, forceSnap, allowAdapt)
    if not targetChar then return nil end
    local center = computeTargetCenter(targetChar)
    if not center then return nil end

    local sUI = tonumber(predBox.Text) or predictionStrength or 5
    predictionStrength = math.clamp(sUI,1,9)
    local s = predictionStrength / 5

    local vel = getSmoothedVelocity(targetChar)
    local relPos = center - myPos
    local distance = relPos.Magnitude
    local targetSpeed = vel.Magnitude

    -- compute rightDir early so we can apply lateral after blending
    local tHRP = targetChar:FindFirstChild("HumanoidRootPart")
    local shooterHRP = LocalPlayer and LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") or nil
    local rightDir
    if shooterHRP and tHRP then
        local rel = shooterHRP.Position - tHRP.Position
        local flat = Vector3.new(rel.X,0,rel.Z)
        if flat.Magnitude < 0.001 then
            rightDir = Vector3.new(tHRP.CFrame.RightVector.X,0,tHRP.CFrame.RightVector.Z)
            if rightDir.Magnitude < 0.001 then rightDir = Vector3.new(1,0,0) else rightDir = rightDir.Unit end
        else
            rightDir = Vector3.new(-flat.Z,0,flat.X)
            if rightDir.Magnitude < 0.001 then rightDir = Vector3.new(1,0,0) else rightDir = rightDir.Unit end
        end
    elseif tHRP then
        rightDir = Vector3.new(tHRP.CFrame.RightVector.X,0,tHRP.CFrame.RightVector.Z)
        if rightDir.Magnitude < 0.001 then rightDir = Vector3.new(1,0,0) else rightDir = rightDir.Unit end
    else
        rightDir = Vector3.new(1,0,0)
    end

    local projectileSpeed = baseProjectileSpeed * math.clamp((0.5 + 9.5 * s), 0.1, 200)
    local a = vel:Dot(vel) - projectileSpeed * projectileSpeed
    local b = 2 * relPos:Dot(vel)
    local c = relPos:Dot(relPos)
    local t = nil
    local eps = 1e-6
    local discr = b*b - 4*a*c
    if discr >= 0 and math.abs(a) > eps then
        local sqrtD = math.sqrt(discr)
        local t1 = (-b - sqrtD) / (2*a)
        local t2 = (-b + sqrtD) / (2*a)
        local cand = {}
        if t1 > 0 then table.insert(cand, t1) end
        if t2 > 0 then table.insert(cand, t2) end
        if #cand > 0 then t = math.min(unpack(cand)) end
    else
        if projectileSpeed > 0 then t = distance / projectileSpeed else t = 0.5 end
    end
    if not t or t <= 0 or t ~= t then t = math.clamp(distance / math.max(projectileSpeed,1), 0.02, 4) end
    t = math.clamp(t, 0.02, 4)

    local effectiveBoost = boostActive and boostMultiplier or 1.0

    -- base prediction: center + forward lead (CLAMPED to prevent over-reaching)
    local rawLead = vel * t * effectiveBoost
    local maxLead = math.min(MAX_LEAD_ABS, distance * MAX_LEAD_FRACTION)
    if rawLead.Magnitude > maxLead and rawLead.Magnitude > 0 then
        rawLead = rawLead.Unit * maxLead
        if RunService:IsStudio() then
            warn(("[AimAssist] lead clamped owner=%s distance=%.2f rawLead=%.2f maxLead=%.2f"):format(tostring(Players:GetPlayerFromCharacter(targetChar) and Players:GetPlayerFromCharacter(targetChar).Name or "nil"), distance, (vel * t * effectiveBoost).Magnitude, maxLead))
        end
    end
    local predicted = center + rawLead

    -- lateral velocity-based small nudge only when NOT adapting
    local line = relPos.Magnitude > 0 and relPos.Unit or Vector3.new(0,0,1)
    local lateralVel = vel - vel:Dot(line) * line

    local owner = Players:GetPlayerFromCharacter(targetChar)
    local profAll = owner and targetProfiles[owner.UserId] or nil
    local adaptInfo = owner and computeAdaptDecisionForPlayer(owner) or nil

    -- adaptAllowed if caller asked OR if we already have a learned trend (apply FIXED_LATERAL outside windup)
    local adaptAllowed = false
    if forceSnap then adaptAllowed = true end
    if allowAdapt then adaptAllowed = true end
    if profAll and (profAll.lastTrend or profAll.temporaryTrend) then adaptAllowed = true end

    if targetSpeed < 0.01 and not adaptAllowed then
        return center
    end

    -- compute lateralApplied but DO NOT add it to predicted until after blending
    local lateralApplied = 0
    if adaptAllowed and profAll then
        -- Use temporary high-confidence trend first (if still valid), then lastTrend, then fallback
        if profAll.temporaryTrend and profAll.temporaryTrendExpiry and tick() <= profAll.temporaryTrendExpiry then
            if profAll.temporaryTrend == "Right" then lateralApplied = FIXED_LATERAL
            elseif profAll.temporaryTrend == "Left" then lateralApplied = -FIXED_LATERAL end
            if owner then warn(("[AimAssist] USING TEMP TREND uid=%d trend=%s expiry=%.2f"):format(owner.UserId, profAll.temporaryTrend, profAll.temporaryTrendExpiry)) end
        elseif profAll.lastTrend == "Right" then
            lateralApplied = FIXED_LATERAL
        elseif profAll.lastTrend == "Left" then
            lateralApplied = -FIXED_LATERAL
        else
            -- fallback: if historical adaptation flagged true, use computed lateral; otherwise use no lateral
            if adaptInfo and adaptInfo.adapt then
                local runSpeed = (profAll and profAll.runSpeed) or math.max(targetSpeed,6)
                lateralApplied = computeLateralStuds(adaptInfo, runSpeed, distance, t)
            end
        end
    else
        -- non-adapt path: keep the small lateral velocity nudge (this is small by design)
        predicted = predicted + lateralVel * lateralBoost * s
    end

    -- windup opposite-then-snap logic (based on your charge/windup)
    if chargeKey and profAll and (profAll.lastTrend or profAll.temporaryTrend or (adaptInfo and adaptInfo.adapt)) then
        local timeLeft = (chargeExpires or 0) - tick()
        -- If we are still early in the windup, aim to the OPPOSITE side to 'surprise' the target.
        if timeLeft > PRE_SNAP_TIME then
            if math.abs(lateralApplied) > 0 then
                lateralApplied = -lateralApplied
                if owner then warn(("[AimAssist] WINDUP OPPOSITE uid=%d lateral=%.2f timeLeft=%.3f"):format(owner.UserId, lateralApplied, timeLeft)) end
            else
                -- if we computed zero lateral but have historical adapt, try small computed lateral flip
                if adaptInfo and adaptInfo.adapt then
                    local runSpeed = (profAll and profAll.runSpeed) or math.max(targetSpeed,6)
                    local comp = computeLateralStuds(adaptInfo, runSpeed, distance, t)
                    if math.abs(comp) > 0 then
                        lateralApplied = -comp
                        if owner then warn(("[AimAssist] WINDUP OPPOSITE fallback uid=%d comp=%.2f timeLeft=%.3f"):format(owner.UserId, lateralApplied, timeLeft)) end
                    end
                end
            end
        else
            -- within PRE_SNAP_TIME: force-snap to the predicted side (apply lateral immediately and return)
            if math.abs(lateralApplied) > 0 then
                predicted = predicted + rightDir * lateralApplied
                if owner then warn(("[AimAssist] WINDUP SNAP uid=%d lateral=%.2f timeLeft=%.3f"):format(owner.UserId, lateralApplied, timeLeft)) end
            end
            return predicted
        end
    end

    if forceSnap then
        -- apply lateral immediately for snap
        if math.abs(lateralApplied) > 0 then predicted = predicted + rightDir * lateralApplied end
        return predicted
    end

    -- forward blending (keep as before)
    local blended = center:Lerp(predicted, math.clamp(s,0.1,1.0))

    -- **apply the FIXED lateral AFTER blending** so it isn't averaged away
    if math.abs(lateralApplied) > 0 then
        blended = blended + rightDir * lateralApplied
        if owner then
            warn(("[AimAssist] ADAPT APPLY uid=%d lateral=%.2f lastTrend=%s"):format(owner.UserId, lateralApplied, (profAll.lastTrend or "nil")) )
        end
    end

    -- stronger smoothing so changes are visible but still smooth (was 0.55, now 0.85)
    if targetChar then
        lastPredictions[targetChar] = lastPredictions[targetChar] or blended
        lastPredictions[targetChar] = lastPredictions[targetChar]:Lerp(blended, 0.85)
        return lastPredictions[targetChar]
    end

    return blended
end


-- on AnimationPlayed: schedule post-windup recording (do not record during windup)
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

        local owner = Players:GetPlayerFromCharacter(character)
        if not owner then return end

        local duration = nil
        pcall(function() duration = track.Length end)
        if not duration then
            pcall(function() duration = track.TimeLength end)
        end
        if not duration then
            duration = (key == "E") and 0.75 or 1.7
        end

        targetProfiles[owner.UserId] = targetProfiles[owner.UserId] or { E = {history = {}, trials = 0, hits = 0}, Q = {history = {}, trials = 0, hits = 0}, allHistory = {}, runSpeed = 25, lastCast = nil, isCasting = false, ewmaDelta = nil, lastTrend = nil, temporaryTrend = nil, temporaryTrendExpiry = nil }
        local profAll = targetProfiles[owner.UserId]
        profAll.lastCast = { key = key, t = tick(), expires = tick() + duration + PRE_RELEASE_MARGIN }
        profAll.isCasting = true

        task.spawn(function()
            task.delay(duration + PRE_RELEASE_MARGIN + 0.01, function()
                local p = targetProfiles[owner.UserId]
                if p and p.lastCast and p.lastCast.t == profAll.lastCast.t then
                    p.isCasting = false
                    p.lastCast = nil
                    warn(("[AimAssist] lastCast cleared uid=%d key=%s"):format(owner.UserId, key))
                end
            end)
        end)

        -- schedule the post-windup recording AFTER the cast/windup expires (no in-windup samples)
        schedulePostWindupRecording(character, key, profAll.lastCast.expires)

        warn(("[AimAssist] noted animation uid=%d key=%s duration=%.2f expires=%.2f (post-record scheduled)"):format(owner.UserId, key, duration, profAll.lastCast.expires))
    end)
    table.insert(animConns, conn); _G.AimAssistAnimConns = animConns
end

-- attach to players (store CharacterAdded conns so we can clean them up)
for _,pl in ipairs(Players:GetPlayers()) do
    if pl.Character then onCharacterAnimationPlayed(pl.Character) end
    local cconn = pl.CharacterAdded:Connect(function(ch) onCharacterAnimationPlayed(ch) end)
    table.insert(animConns, cconn)
end
local playerAddedConn = Players.PlayerAdded:Connect(function(pl)
    local cconn = pl.CharacterAdded:Connect(function(ch) onCharacterAnimationPlayed(ch) end)
    table.insert(animConns, cconn)
end)
table.insert(animConns, playerAddedConn)
_G.AimAssistAnimConns = animConns

-- monitor playing tracks each frame (helps with strange edge cases)
local function monitorAnimationStates()
    for _,pl in ipairs(Players:GetPlayers()) do
        if pl and pl.Character and pl.Character.Parent then
            local char = pl.Character
            local hum = char:FindFirstChild("Humanoid")
            if hum then
                local playing = hum:GetPlayingAnimationTracks()
                local found = false
                for _, track in ipairs(playing) do
                    local ok, animId = pcall(function() return extractAnimId(track.Animation and track.Animation.AnimationId) end)
                    if ok and animId and animationToKey[animId] then
                        found = true
                        local key = animationToKey[animId]
                        targetProfiles[pl.UserId] = targetProfiles[pl.UserId] or { E = {history = {}, trials = 0, hits = 0}, Q = {history = {}, trials = 0, hits = 0}, allHistory = {}, runSpeed = 25, lastCast = nil, isCasting = false, ewmaDelta = nil, lastTrend = nil, temporaryTrend = nil, temporaryTrendExpiry = nil }
                        local prof = targetProfiles[pl.UserId]
                        local duration = nil
                        pcall(function() duration = track.Length end)
                        if not duration then duration = (key == "E") and 0.75 or 1.7 end
                        prof.lastCast = { key = key, t = tick(), expires = tick() + duration + PRE_RELEASE_MARGIN }
                        prof.isCasting = true
                        break
                    end
                end
                if not found and targetProfiles[pl.UserId] then
                    local prof = targetProfiles[pl.UserId]
                    if prof.lastCast and prof.lastCast.expires and tick() <= prof.lastCast.expires then
                        prof.isCasting = true
                    else
                        prof.isCasting = false
                        prof.lastCast = nil
                    end
                end
            end
        end
    end
end

-- INPUT: schedule post-windup recording when player presses E/Q (do not record during windup)
local inputBeganConn = UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.P then screenGui.Enabled = not screenGui.Enabled end

    if input.KeyCode == Enum.KeyCode.U then
        if redHighlightedTarget and redHighlightedTarget.Parent then
            if aimActive and lockedTarget == redHighlightedTarget then
                aimActive = false; lockedTarget = nil; clearLockedTargetVisuals()
            else
                lockedTarget = redHighlightedTarget; aimActive = true; setLockedTargetVisuals(lockedTarget)
            end
        end
        return
    end

    if input.KeyCode == Enum.KeyCode.E or input.KeyCode == Enum.KeyCode.Q then
        local keyStr = (input.KeyCode == Enum.KeyCode.E) and "E" or "Q"
        -- schedule post-windup recording for the locked target (if any)
        if aimActive and lockedTarget then
            local expires = tick() + (windups[keyStr] or 0.75) + PRE_RELEASE_MARGIN
            schedulePostWindupRecording(lockedTarget, keyStr, expires)
        end
        charging = true
        chargeKey = input.KeyCode
        chargeStart = tick()
        chargeExpires = tick() + (windups[keyStr] or 0.75) -- used for local logic
        if input.KeyCode == Enum.KeyCode.Q then boostActive = true; boostMultiplier = 1.0 + 0.4; boostEnd = tick() + 2.0 end
        return
    end

    if input.KeyCode == Enum.KeyCode.F then
        local targetChar = nil
        if Mouse and Mouse.Target then targetChar = getCharacterFromInstance(Mouse.Target) end
        if not targetChar then targetChar = findNearestTarget() end
        if targetChar and targetChar.Parent then
            if redHighlightedTarget == targetChar then
                clearRedHighlight()
                if lockedTarget == targetChar then aimActive = false; lockedTarget = nil; clearLockedTargetVisuals() end
            else
                clearRedHighlight(); setRedHighlight(targetChar)
            end
        end
        return
    end
end)
table.insert(animConns, inputBeganConn)

local inputEndedConn = UIS.InputEnded:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.E or input.KeyCode == Enum.KeyCode.Q then
        charging = false
        chargeKey = input.KeyCode -- keep this so main loop can infer which key caused expiry window
        chargeStart = chargeStart
        -- DO NOT clear chargeExpires here; adaptation remains active until expiry if needed
    end
end)
table.insert(animConns, inputEndedConn)

local predBoxConn = predBox.FocusLost:Connect(function()
    local v = tonumber(predBox.Text) or 5; predBox.Text = tostring(math.clamp(v,1,9)); predictionStrength = tonumber(predBox.Text)
end)
table.insert(animConns, predBoxConn)

_G.AimAssistAnimConns = animConns

local function buildTargetInfoText(targetChar)
    if not targetChar then return "" end
    local pl = Players:GetPlayerFromCharacter(targetChar)
    if not pl then return "" end
    local uid = pl.UserId
    local prof = targetProfiles[uid] or { E = {trials=0,hits=0}, Q = {trials=0,hits=0}, runSpeed = 25, lastCast = nil, isCasting = false, ewmaDelta = nil, lastTrend = nil }
    local eT = prof.E.trials or 0; local qT = prof.Q.trials or 0
    local eH = prof.E.hits or 0; local qH = prof.Q.hits or 0
    local lastCast = prof.lastCast and (prof.lastCast.key .. "@" .. tostring(math.floor((tick()-prof.lastCast.t)*100)/100) .. "s") or "none"
    local castingStr = prof.isCasting and "YES" or "no"
    local adaptInfo = computeAdaptDecisionForPlayer(pl)
    local avgDodge = adaptInfo and adaptInfo.avgAbsDelta or 0
    local lastTrend = prof.lastTrend or "none"
    local text = ("trials: E=%d Q=%d | hits: E=%d Q=%d | avgDodge=%.2f | lastTrend=%s | lastCast=%s | casting=%s | ewma=%.2f")
        :format(eT,qT,eH,qH,avgDodge,lastTrend,lastCast,castingStr, (prof.ewmaDelta or 0))
    return text
end

-- main loop
_G.AimAssistConn = RunService.RenderStepped:Connect(function(dt)
    if boostActive and tick() > (boostEnd or 0) then boostActive = false; boostMultiplier = 1.0 end
    sampleAllCharacters(dt)

    monitorAnimationStates()

    if lockedBillboard and lockedBillboard.Parent then
        local label = lockedBillboard:FindFirstChildOfClass("TextLabel") or lockedBillboard:FindFirstChild("AimAssistLockedLabel")
        if label then label.Text = buildTargetInfoText(lockedBillboard.Parent) end
    end

    if aimActive and lockedTarget and lockedTarget.Parent then
        local myChar = LocalPlayer.Character
        if myChar and myChar:FindFirstChild("HumanoidRootPart") then
            local myHRP = myChar.HumanoidRootPart
            local aimPoint = nil

            -- chargingActive is true while within the windup window (so press -> lasts full windup even if released)
            local chargingActive = (chargeExpires and tick() <= chargeExpires)

            if chargingActive and chargeKey then
                local keyStr = (chargeKey == Enum.KeyCode.E) and "E" or "Q"
                aimPoint = predictedAimPoint(myHRP.Position, lockedTarget, keyStr, false, true)
            else
                aimPoint = predictedAimPoint(myHRP.Position, lockedTarget, nil, false, false)
            end

            if not aimPoint then return end
            local dirVector = aimPoint - myHRP.Position
            if dirVector.Magnitude < 0.001 then dirVector = (lockedTarget:FindFirstChild("HumanoidRootPart") and (lockedTarget.HumanoidRootPart.Position - myHRP.Position)) or Vector3.new(0,0,1) end
            local dir = dirVector.Unit
            local camPos = myHRP.Position - dir * math.abs(cameraOffset.Z)
            camPos = camPos + Vector3.new(0,cameraOffset.Y,0)
            Camera.CFrame = CFrame.new(camPos, aimPoint)
        end
    end
end)

-- debug
if RunService:IsStudio() then
    warn("[AimAssist] Post-windup recording loaded. POST_RECORD_DURATION="..tostring(POST_RECORD_DURATION).." FIXED_LATERAL="..tostring(FIXED_LATERAL).." POST_EDGE_WINDOW="..tostring(POST_EDGE_WINDOW))
    warn(("[AimAssist] DETUNING: MIN_MOVE_MAG=%.2f DIR_THRESHOLD=%.2f SMALL_DELTA_THRESHOLD=%.2f HYST=%d STALE=%.1fs")
         :format(MIN_MOVE_MAG, DIR_THRESHOLD, SMALL_DELTA_THRESHOLD, HYSTERESIS_REQUIRED, STALE_TREND_TIMEOUT))
    warn(("[AimAssist] TEMP TREND CONFIG: IMMEDIATE_MIN_PEAK=%.2f DURATION=%.2fs PRE_SNAP_TIME=%.2fs MAX_LEAD_ABS=%.2f MAX_LEAD_FRAC=%.2f"):format(IMMEDIATE_TREND_MIN_PEAK, TEMPORARY_TREND_DURATION, PRE_SNAP_TIME, MAX_LEAD_ABS, MAX_LEAD_FRACTION))
end
