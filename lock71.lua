
-- Aim Assist — Post-windup only recording (FULL-FILE) — LAST-DIRECTION + FIXED LATERAL
-- Updated: ignore trivial pushes removed; robust direction detection, logging + hysteresis + temporary immediate trend + regression ensemble for short windows
--
-- Heads-up when copying this file manually:
--   • The script is ~1.5k lines long (check `wc -l lock71.lua`). Some copy/paste
--     paths silently truncate around 700–800 lines, so you may end up with a
--     partial script unless you split the copy into chunks or pull the file
--     directly from disk/version control.
--   • If your editor shows fewer than ~1,500 lines after pasting, fetch the
--     file again instead of running the truncated version; incomplete copies
--     will break the aim logic.
--   • For step-by-step approval or deployment guidance, see `APPLYING_CHANGES.md`.

local function disconnectList(list)
    if not list then return end
    for _, c in ipairs(list) do
        pcall(function()
            if c and type(c.Disconnect) == "function" then
                c:Disconnect()
            end
        end)
    end
end

-- Kill previous instance (robust)
if _G.AimAssistKill and type(_G.AimAssistKill) == "function" then
    pcall(_G.AimAssistKill)
end

_G.AimAssistKill = function()
    if _G.AimAssistConn and type(_G.AimAssistConn.Disconnect) == "function" then
        pcall(function() _G.AimAssistConn:Disconnect() end)
        _G.AimAssistConn = nil
    end

    disconnectList(_G.AimAssistAnimConns)
    disconnectList(_G.AimAssistActiveRecordConns)
    _G.AimAssistAnimConns = nil
    _G.AimAssistActiveRecordConns = nil

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

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Blacklist
rayParams.IgnoreWater = true

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

local DEBUG_LOGS_ENABLED = false
local function debugWarn(...)
    if DEBUG_LOGS_ENABLED then
        warn(...)
    end
end

-- Minimum absolute lateral dodge (studs) required for a post‑windup recording
-- to be considered significant.  Dodges smaller than this value are more
-- likely to be noise (e.g. bumping into walls or jittery movement) and will
-- not count towards adaptation.  Tune this value based on typical player
-- sidestep distances; values too small may trigger adaptation on random
-- jitter, whereas values too large may miss intentional micro‑dodges.
local MIN_DODGE_PEAK_FOR_COUNT = 0.3

-- Scale the adaptation lateral offset by the distance to the target.  When
-- a target is far away, a fixed lateral offset (e.g. ±4.5 studs) may be
-- insufficient because the forward lead is large and the lateral shift is
-- relatively small.  The factor used is (1 + distance * LATERAL_DISTANCE_SCALE).
-- For example, with a distance of 30 studs and LATERAL_DISTANCE_SCALE = 0.03,
-- the offset multiplier becomes 1 + 0.9 = 1.9, producing roughly twice the
-- lateral shift.  Tune this value based on in‑game testing.
local LATERAL_DISTANCE_SCALE = 0.03

-- NEW: robust detection tuning (tuned for shorter dodges)
local MIN_MOVE_MAG = 0.4                -- baseline minimum absolute raw window movement to count (studs) (kept for reference but not used for gating)
local DIR_THRESHOLD = 0.5
local SMALL_DELTA_THRESHOLD = 0.12      -- per-sample delta threshold for sign voting
local HYSTERESIS_REQUIRED = 2
local STALE_TREND_TIMEOUT = 4.0         -- seconds after which an old trend expires if nothing new

-- Minimum number of total post‑windup trials (across E and Q) required before
-- a stable trend is considered valid.  Without enough historical data the
-- algorithm may latch onto a direction too early (for example after only
-- one or two dodges), which can cause premature adaptation.  Increasing
-- this value delays the point at which a permanent left/right trend is set
-- in `profAll.lastTrend`, thereby preventing adaptation from engaging
-- before the target’s dodging behaviour has been sufficiently observed.
local MIN_TRIALS_FOR_TREND = 4

-- NEW: height difference threshold.  If the shooter and target are on
-- different vertical levels (for example when fighting on different floors),
-- post‑windup trials that miss should not be treated as dodges.  When the
-- absolute difference in Y‑coordinate between the shooter and target
-- exceeds this threshold and the shot misses, the trial will be ignored
-- (not counted, no adaptation update).  Tune this based on your map
-- vertical spacing; a value of 7 studs is used here to better tolerate
-- mild elevation differences while still filtering out large height gaps.
local VERTICAL_HEIGHT_THRESHOLD = 7

-- Minimum number of recorded post‑windup trials (across both E and Q) before
-- the pre‑windup pattern recognition for Q is allowed to adjust the aim.  When
-- this value is greater than zero, the aim assist will not immediately
-- snap to the opposite side on the very first Q cast simply because the
-- target was running in one direction during the windup.  Instead, it will
-- require that at least a handful of trials (hits or misses) have been
-- recorded beforehand, ensuring that premature adaptation does not occur.
-- You can tune this value; a value of 1 means at least one trial must
-- exist before the pre‑windup pattern is used.  A larger number makes the
-- system even more conservative.
local MIN_TRIALS_FOR_PREWINDUP = 1

-- NEW: list of animation IDs that indicate the player is sprinting.  When
-- one of these animations plays we mark the player as running and allow
-- the normal velocity sampling to update `runSpeed`.  We do not set
-- `runSpeed` to a fixed value here because a player's speed may change
-- due to hits or speed boosts.  The IDs below were supplied by the
-- game developer; update or extend this list to match any additional
-- running animations in your game.
local RUN_ANIMATION_IDS = {
    ["136252471123500"] = true,
    ["115946474977409"] = true,
    ["71505511479171"]  = true,
    ["125869734469543"] = true,
    ["117058860640843"] = true,
    ["133312964070618"] = true,
    ["99159420513149"]  = true,
    ["120313643102609"] = true,
    ["86557953969836"]  = true,
    ["120715084586730"] = true,
    ["101438873382721"] = true,
}

-- NEW: speed threshold to detect a player stuck against an obstacle while
-- running.  When a run animation is active but the measured velocity is
-- below this value (studs per second), the player is likely dragging on a
-- wall.  In this case the prediction should not apply forward lead; the
-- aim will be directed to the target's current position instead.  Tune
-- based on typical run speeds in your game.
local STUCK_SPEED_THRESHOLD = 3.0

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
    local mousePos = Vector2.new(Mouse.X, Mouse.Y)
    local camPos = Camera.CFrame.Position
    for _,v in ipairs(Players:GetPlayers()) do
        if v ~= LocalPlayer and v.Character and v.Character.Parent then
            local character = v.Character
            local hrp = character:FindFirstChild("HumanoidRootPart")
            local hum = character:FindFirstChild("Humanoid")
            if hrp and hum and hum.Health > 0 then
                local center = computeTargetCenter(character)
                if center then
                    local screenPos, onScreen = Camera:WorldToViewportPoint(center)
                    if onScreen then
                        local ignoreList = {character}
                        local lpChar = LocalPlayer.Character
                        if lpChar then table.insert(ignoreList, lpChar) end
                        rayParams.FilterDescendantsInstances = ignoreList
                        local dir = center - camPos
                        local hit = workspace:Raycast(camPos, dir, rayParams)
                        if not hit or (hit.Instance and hit.Instance:IsDescendantOf(character)) then
                            local mag = (mousePos - Vector2.new(screenPos.X, screenPos.Y)).Magnitude
                            if mag < dist then dist = mag; closest = character end
                        end
                    end
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
        consecutiveDodges = 0,
        isRunning = false,
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
                debugWarn(("[AimAssist] post-record EMPTY uid=%d key=%s"):format(uid,key))
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
            -- Only count when a direction was decided AND the absolute peak
            -- lateral delta exceeds a minimum threshold.  This prevents
            -- spurious tiny movements (for example, sliding against a wall)
            -- from polluting the adaptation history.
            local counted = false
            if finalDecision ~= 0 and math.abs(peakDelta) >= MIN_DODGE_PEAK_FOR_COUNT then
                counted = true
            end

            -- vertical difference gating: if the shot missed and the target is on a very
            -- different vertical level from the shooter, do not count this trial.  This
            -- prevents adaptation from reacting to misses caused by height differences
            -- rather than dodging.  We assume shooterPos was captured at the start of
            -- the post‑windup window.
            if counted and not hitDetected then
                local verticalDiff = nil
                pcall(function()
                    local shooterY = nil
                    -- prefer shooterPos captured outside; fallback to current shooter HRP
                    if shooterPos then shooterY = shooterPos.Y end
                    local curShooter = LocalPlayer and LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") or nil
                    if not shooterY and curShooter then shooterY = curShooter.Position.Y end
                    if shooterY and hrp and hrp.Position then
                        verticalDiff = math.abs(shooterY - hrp.Position.Y)
                    end
                end)
                if verticalDiff and verticalDiff >= VERTICAL_HEIGHT_THRESHOLD then
                    counted = false
                end
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
                debugWarn(("[AimAssist] TEMP TREND uid=%d key=%s trend=%s peak=%.2f slope=%.2f expiry=%.2f"):format(uid, key, newTrendName, peakDelta, slopeTotal, profAll.temporaryTrendExpiry))
            end

            if finalDecision ~= 0 and counted then
                if prevTrend == newTrendName then
                    profAll.trendStableCount = (profAll.trendStableCount or 0) + 1
                else
                    profAll.trendStableCount = 1
                end
                if profAll.trendStableCount >= HYSTERESIS_REQUIRED then
                    -- Only accept a stable trend when the target has dodged
                    -- consecutively at least twice OR when enough trials have
                    -- accumulated across E and Q.  This prevents premature
                    -- adaptation for players who get hit consistently.
                    local ok, totalTrials = pcall(function()
                        return ((profAll.E and profAll.E.trials) or 0) + ((profAll.Q and profAll.Q.trials) or 0)
                    end)
                    if not ok then totalTrials = 0 end
                    if (profAll.consecutiveDodges or 0) >= 2 or (totalTrials >= MIN_TRIALS_FOR_TREND) then
                        profAll.lastTrend = newTrendName
                        profAll.lastTrendTime = tick()
                    end
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

            -- update consecutive dodge counter.  If this trial was counted and a
            -- direction (Left or Right) was decided and the shot did not hit
            -- the target, increment the consecutive dodge count.  Otherwise
            -- reset the counter.  This ensures that adaptation will only be
            -- enabled after a player has dodged multiple times in a row.  A
            -- miss caused by dodging increments the count; a hit resets it.
            do
                if counted and finalDecision ~= 0 and not hitDetected then
                    profAll.consecutiveDodges = (profAll.consecutiveDodges or 0) + 1
                else
                    profAll.consecutiveDodges = 0
                end
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
                debugWarn(("[AimAssist][DET] uid=%d key=%s baseline=%.3f peakDelta=%.3f raw=%.3f slope=%.3f last=%.3f pos=%d neg=%d sig=%d vote=%s combined=%.3f decided=%s counted=%s prevTrend=%s->%s stable=%d")
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

    -- Detect quick alternating dodges (e.g. left then right) which should
    -- disable adaptation.  Look at the most recent few trials and see if the
    -- last two non‑"None" trends differ.  If so, we consider the player to
    -- be zig‑zagging unpredictably and refrain from adapting.
    local patternAlternate = false
    do
        local found1, trend1, found2, trend2 = false, nil, false, nil
        for i = 1, math.min(#history, 3) do
            local t = history[i]
            if t and t.trend and t.trend ~= "None" then
                if not found1 then
                    found1 = true; trend1 = t.trend
                elseif not found2 then
                    found2 = true; trend2 = t.trend
                    break
                end
            end
        end
        if found1 and found2 and trend1 ~= trend2 then
            patternAlternate = true
        end
    end

    -- Determine whether adaptation should be enabled.  Require at least two
    -- consecutive dodges and no alternating zig‑zag pattern.  This ensures
    -- adaptation is only applied when the target consistently dodges in
    -- one direction and has not recently switched sides.
    local adapt = false
    if not patternAlternate then
        if (profAll.consecutiveDodges or 0) >= 2 then
            adapt = true
        end
    end

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

    -- Early detection of a stuck running player.  If the player is running
    -- (based on animation state) but their velocity is below a small
    -- threshold, they are likely dragging against a wall or obstacle.
    -- In this situation we bypass prediction entirely and aim directly
    -- at the target's current center.  We compute the player profile here
    -- to access the `isRunning` flag without waiting for later logic.
    do
        local ownerEarly = Players:GetPlayerFromCharacter(targetChar)
        if ownerEarly then
            local profEarly = targetProfiles[ownerEarly.UserId]
            if profEarly and profEarly.isRunning and targetSpeed <= STUCK_SPEED_THRESHOLD then
                return center
            end
        end
    end


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
            debugWarn(("[AimAssist] lead clamped owner=%s distance=%.2f rawLead=%.2f maxLead=%.2f"):format(tostring(Players:GetPlayerFromCharacter(targetChar) and Players:GetPlayerFromCharacter(targetChar).Name or "nil"), distance, (vel * t * effectiveBoost).Magnitude, maxLead))
        end
    end
    local predicted = center + rawLead

    -- lateral velocity-based small nudge only when NOT adapting
    local line = relPos.Magnitude > 0 and relPos.Unit or Vector3.new(0,0,1)
    local lateralVel = vel - vel:Dot(line) * line

    local owner = Players:GetPlayerFromCharacter(targetChar)
    local profAll = owner and targetProfiles[owner.UserId] or nil
    local adaptInfo = owner and computeAdaptDecisionForPlayer(owner) or nil

    -- Track the predominant lateral movement direction during the windup for Q.
    -- Many players will run in one direction during the windup and then dodge
    -- in the opposite direction just before release.  We accumulate the sign
    -- of the lateral velocity (dot with rightDir) for Q casts so that we can
    -- infer this pattern.  We only store significant movement (beyond a small
    -- threshold) and reset the accumulator when the player is not charging Q.
    if profAll then
        if chargeKey and chargeKey == Enum.KeyCode.Q then
            local sign = 0
            local dotLR = lateralVel:Dot(rightDir)
            if dotLR > 0.05 then
                sign = 1
            elseif dotLR < -0.05 then
                sign = -1
            end
            profAll.preWindupDirSumQ = (profAll.preWindupDirSumQ or 0) + sign
            -- Only count frames where movement was significant
            if sign ~= 0 then
                profAll.preWindupDirCountQ = (profAll.preWindupDirCountQ or 0) + 1
            end
        else
            -- Clear prewindup memory when not in Q windup
            if profAll.preWindupDirSumQ or profAll.preWindupDirCountQ then
                profAll.preWindupDirSumQ = nil
                profAll.preWindupDirCountQ = nil
            end
        end
    end

    -- Determine whether adaptation logic should be allowed for this shot.
    -- Historically, the script allowed adaptation whenever a lastTrend or
    -- temporaryTrend existed.  This meant adaptation could kick in after
    -- only a couple of recorded dodges, which often led to mis‑aimed shots.
    -- Here we remove direct dependence on lastTrend and instead rely on
    -- `computeAdaptDecisionForPlayer` to signal when enough evidence has
    -- accumulated (e.g. after MIN_TRIALS_FOR_TREND trials) to justify
    -- adaptation.  forceSnap and allowAdapt still override this decision.
    local adaptAllowed = false
    if forceSnap or allowAdapt then
        adaptAllowed = true
    else
        adaptAllowed = false
    end

    if targetSpeed < 0.01 and not adaptAllowed then
        return center
    end

    -- Determine if we have enough dodges to activate adaptation.  We require
    -- at least two consecutive dodges before considering lastTrend or
    -- temporaryTrend.  Without this gate, adaptation can kick in as soon as
    -- a temporary trend is set, leading to premature left/right offsets.
    local enoughDodges = false
    if profAll and (profAll.consecutiveDodges or 0) >= 2 then
        enoughDodges = true
    end

    -- Determine the predominant pre‑windup direction for Q casts.  If the
    -- player has been moving predominantly in one direction during the
    -- windup (based on accumulated lateral velocity signs), we anticipate
    -- that they may dodge in the opposite direction.  To avoid premature
    -- adaptation on the very first cast, this pattern recognition is only
    -- enabled once a minimum number of post‑windup trials have been
    -- recorded (controlled by MIN_TRIALS_FOR_PREWINDUP).
    local dominantPreDir = nil
    do
        -- Only attempt to use pre‑windup data if the profile exists and
        -- enough trials have been recorded overall.  Without at least a
        -- couple of trials the aim assist will not snap to the opposite side
        -- simply because the target ran in one direction during the windup.
        if profAll then
            local totalTrialsPQ = ((profAll.E and profAll.E.trials) or 0) + ((profAll.Q and profAll.Q.trials) or 0)
            if totalTrialsPQ >= MIN_TRIALS_FOR_PREWINDUP then
                if profAll.preWindupDirCountQ and profAll.preWindupDirCountQ >= 3 then
                    local total = profAll.preWindupDirCountQ
                    local sum = profAll.preWindupDirSumQ or 0
                    if math.abs(sum) >= 0.6 * total then
                        dominantPreDir = (sum > 0) and 1 or -1
                    end
                end
            end
        end
    end

    -- compute lateralApplied but DO NOT add it to predicted until after blending
    -- When adaptAllowed is true, we consider three cases:
    --   1. Enough dodges: use temporaryTrend or lastTrend (or computed lateral) as before.
    --   2. Not enough dodges but Q windup with a dominant pre‑windup run direction: aim opposite.
    --   3. Otherwise, do not apply adaptation and use a small velocity nudge.
    local lateralApplied = 0
    if adaptAllowed and profAll then
        if enoughDodges then
            if profAll.temporaryTrend and profAll.temporaryTrendExpiry and tick() <= profAll.temporaryTrendExpiry then
                if profAll.temporaryTrend == "Right" then
                    lateralApplied = FIXED_LATERAL
                elseif profAll.temporaryTrend == "Left" then
                    lateralApplied = -FIXED_LATERAL
                end
                if owner then
                    debugWarn(("[AimAssist] USING TEMP TREND uid=%d trend=%s expiry=%.2f"):format(owner.UserId, profAll.temporaryTrend, profAll.temporaryTrendExpiry))
                end
            elseif profAll.lastTrend == "Right" then
                lateralApplied = FIXED_LATERAL
            elseif profAll.lastTrend == "Left" then
                lateralApplied = -FIXED_LATERAL
            else
                -- fallback: if adaptation decision is true, use computed lateral
                if adaptInfo and adaptInfo.adapt then
                    local runSpeed = (profAll and profAll.runSpeed) or math.max(targetSpeed,6)
                    lateralApplied = computeLateralStuds(adaptInfo, runSpeed, distance, t)
                end
            end
        elseif chargeKey and chargeKey == Enum.KeyCode.Q and dominantPreDir then
            -- Not enough dodges yet; anticipate an opposite dodge based on
            -- pre‑windup movement.  If the player ran to the right (dominant
            -- positive), we aim left, and vice versa.
            lateralApplied = -dominantPreDir * FIXED_LATERAL
            if owner then
                debugWarn(("[AimAssist] PREWINDUP Q PATTERN uid=%d dominantDir=%s applied lateral=%.2f"):format(owner.UserId, tostring(dominantPreDir), lateralApplied))
            end
        else
            -- non-adapt path: keep the small lateral velocity nudge (this is small by design)
            predicted = predicted + lateralVel * lateralBoost * s
        end
    else
        -- adapt not allowed: apply small lateral nudge as before
        predicted = predicted + lateralVel * lateralBoost * s
    end

    -- Apply windup opposite logic: invert lateralApplied during the early part of a windup.
    -- This modification is applied before scaling so that the sign is taken into account.

    -- Precompute a scale factor for the lateral offset.  When adaptation is
    -- allowed this scales the lateral shift by distance to compensate for
    -- large forward leads.  Otherwise the factor is 1 (no scaling).
    local scaleFactor = 1
    if adaptAllowed then
        scaleFactor = 1 + distance * LATERAL_DISTANCE_SCALE
    end

    -- windup opposite-then-snap logic (based on your charge/windup)
    if chargeKey and profAll and adaptAllowed and (profAll.lastTrend or profAll.temporaryTrend or (adaptInfo and adaptInfo.adapt) or dominantPreDir) then
        local timeLeft = (chargeExpires or 0) - tick()
        -- If we are still early in the windup, aim to the OPPOSITE side to 'surprise' the target.
        if timeLeft > PRE_SNAP_TIME then
            -- Early in the windup: invert the lateral offset to "trick" the
            -- opponent.  Do not apply the offset yet; scaling will be
            -- computed when the offset is actually applied.
            if math.abs(lateralApplied) > 0 then
                lateralApplied = -lateralApplied
                if owner then
                    debugWarn(("[AimAssist] WINDUP OPPOSITE uid=%d lateralRaw=%.2f timeLeft=%.3f"):format(owner.UserId, lateralApplied, timeLeft))
                end
            else
                -- if we computed zero lateral but have historical adapt, try
                -- small computed lateral flip
                if adaptInfo and adaptInfo.adapt then
                    local runSpeed = (profAll and profAll.runSpeed) or math.max(targetSpeed,6)
                    local comp = computeLateralStuds(adaptInfo, runSpeed, distance, t)
                    if math.abs(comp) > 0 then
                        lateralApplied = -comp
                        if owner then
                            debugWarn(("[AimAssist] WINDUP OPPOSITE fallback uid=%d comp=%.2f timeLeft=%.3f"):format(owner.UserId, lateralApplied, timeLeft))
                        end
                    end
                end
            end
        else
            -- within PRE_SNAP_TIME: force-snap to the predicted side and
            -- apply the lateral offset immediately with scaling.  Since
            -- pre-snap occurs near the end of the windup, we apply the
            -- computed lateralApplied (which may have been inverted) scaled by
            -- the distance factor.
            if math.abs(lateralApplied) > 0 then
                predicted = predicted + rightDir * (lateralApplied * scaleFactor)
                if owner then
                    debugWarn(("[AimAssist] WINDUP SNAP uid=%d lateral=%.2f (scaled=%.2f) timeLeft=%.3f"):format(owner.UserId, lateralApplied, (lateralApplied * scaleFactor), timeLeft))
                end
            end
            return predicted
        end
    end

    if forceSnap then
        -- apply lateral immediately for snap.  Use scaled lateral if adaptation
        -- is allowed, otherwise apply the raw lateral offset.
        if math.abs(lateralApplied) > 0 then
            predicted = predicted + rightDir * (lateralApplied * scaleFactor)
        end
        return predicted
    end

    -- forward blending (keep as before)
    local blended = center:Lerp(predicted, math.clamp(s,0.1,1.0))

    -- **apply the lateral AFTER blending** so it isn't averaged away.  Use
    -- scaleFactor to enlarge the offset at longer distances.
    if math.abs(lateralApplied) > 0 then
        blended = blended + rightDir * (lateralApplied * scaleFactor)
        if owner then
            debugWarn(("[AimAssist] ADAPT APPLY uid=%d lateral=%.2f scaled=%.2f lastTrend=%s"):format(owner.UserId, lateralApplied, (lateralApplied * scaleFactor), (profAll.lastTrend or "nil")))
        end
    end

    -- adaptive smoothing: prioritize reactivity for fast/far targets while keeping
    -- slow targets steady.  Faster targets get higher alpha (closer to predicted),
    -- slower ones keep more smoothing.
    if targetChar then
        lastPredictions[targetChar] = lastPredictions[targetChar] or blended
        local speedFactor = math.clamp(targetSpeed / 30, 0, 1)
        local distanceFactor = math.clamp(distance / 80, 0, 1)
        local smoothingAlpha = math.clamp(0.55 + 0.35 * math.max(speedFactor, distanceFactor), 0.55, 0.95)
        lastPredictions[targetChar] = lastPredictions[targetChar]:Lerp(blended, smoothingAlpha)
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
        -- detect running animations.  When the target plays a running animation
        -- (sprint), update their runSpeed to the maximum sprint speed and do
        -- not treat this as a cast event.  This prevents the post‑windup
        -- recording logic from erroneously interpreting running as a dodge
        -- and instead simply updates the internal speed estimate.
        if RUN_ANIMATION_IDS[animId] then
            local owner = Players:GetPlayerFromCharacter(character)
            if owner then
                targetProfiles[owner.UserId] = targetProfiles[owner.UserId] or {
                    E = {history = {}, trials = 0, hits = 0},
                    Q = {history = {}, trials = 0, hits = 0},
                    allHistory = {},
                    runSpeed = 25,
                    consecutiveDodges = 0,
                    lastCast = nil,
                    isCasting = false,
                    ewmaDelta = nil,
                    lastTrend = nil,
                    temporaryTrend = nil,
                    temporaryTrendExpiry = nil
                }
                -- We no longer set isRunning here; running state is tracked
                -- each frame in monitorAnimationStates.
            end
            return
        end
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

        targetProfiles[owner.UserId] = targetProfiles[owner.UserId] or {
            E = {history = {}, trials = 0, hits = 0},
            Q = {history = {}, trials = 0, hits = 0},
            allHistory = {},
            runSpeed = 25,
            consecutiveDodges = 0,
            isRunning = false,
            lastCast = nil,
            isCasting = false,
            ewmaDelta = nil,
            lastTrend = nil,
            temporaryTrend = nil,
            temporaryTrendExpiry = nil
        }
        local profAll = targetProfiles[owner.UserId]
        profAll.lastCast = { key = key, t = tick(), expires = tick() + duration + PRE_RELEASE_MARGIN }
        profAll.isCasting = true

        task.spawn(function()
            task.delay(duration + PRE_RELEASE_MARGIN + 0.01, function()
                local p = targetProfiles[owner.UserId]
                if p and p.lastCast and p.lastCast.t == profAll.lastCast.t then
                    p.isCasting = false
                    p.lastCast = nil
                    debugWarn(("[AimAssist] lastCast cleared uid=%d key=%s"):format(owner.UserId, key))
                end
            end)
        end)

        -- schedule the post-windup recording AFTER the cast/windup expires (no in-windup samples)
        schedulePostWindupRecording(character, key, profAll.lastCast.expires)

        debugWarn(("[AimAssist] noted animation uid=%d key=%s duration=%.2f expires=%.2f (post-record scheduled)"):format(owner.UserId, key, duration, profAll.lastCast.expires))
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
                -- ensure the profile exists and reset running flag for this tick
                targetProfiles[pl.UserId] = targetProfiles[pl.UserId] or {
                    E = {history = {}, trials = 0, hits = 0},
                    Q = {history = {}, trials = 0, hits = 0},
                    allHistory = {},
                    runSpeed = 25,
                    consecutiveDodges = 0,
                    isRunning = false,
                    lastCast = nil,
                    isCasting = false,
                    ewmaDelta = nil,
                    lastTrend = nil,
                    temporaryTrend = nil,
                    temporaryTrendExpiry = nil
                }
                local prof = targetProfiles[pl.UserId]
                prof.isRunning = false
                for _, track in ipairs(playing) do
                    local ok, animId = pcall(function() return extractAnimId(track.Animation and track.Animation.AnimationId) end)
                    if ok and animId then
                        -- mark running state
                        if RUN_ANIMATION_IDS[animId] then
                            prof.isRunning = true
                        end
                        -- handle cast animations (E/Q)
                        if animationToKey[animId] then
                            found = true
                            local key = animationToKey[animId]
                            local duration = nil
                            pcall(function() duration = track.Length end)
                            if not duration then duration = (key == "E") and 0.75 or 1.7 end
                            prof.lastCast = { key = key, t = tick(), expires = tick() + duration + PRE_RELEASE_MARGIN }
                            prof.isCasting = true
                            break
                        end
                    end
                end
                if not found then
                    -- no cast animation found; update casting and lastCast based on expiry
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
        -- schedule post-windup recording for the current target.  If a target
        -- is locked on (aimActive) schedule for that target.  Otherwise, if
        -- a target is highlighted (red highlight) schedule for that target
        -- instead.  This allows collecting dodge data even when you choose
        -- not to lock on immediately during a windup.
        if aimActive and lockedTarget then
            local expires = tick() + (windups[keyStr] or 0.75) + PRE_RELEASE_MARGIN
            schedulePostWindupRecording(lockedTarget, keyStr, expires)
        elseif redHighlightedTarget and redHighlightedTarget.Parent then
            local expires = tick() + (windups[keyStr] or 0.75) + PRE_RELEASE_MARGIN
            schedulePostWindupRecording(redHighlightedTarget, keyStr, expires)
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
    local prof = targetProfiles[uid] or {
        E = {trials=0,hits=0},
        Q = {trials=0,hits=0},
        runSpeed = 25,
        consecutiveDodges = 0,
        lastCast = nil,
        isCasting = false,
        ewmaDelta = nil,
        lastTrend = nil
    }
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
    debugWarn("[AimAssist] Post-windup recording loaded. POST_RECORD_DURATION="..tostring(POST_RECORD_DURATION).." FIXED_LATERAL="..tostring(FIXED_LATERAL).." POST_EDGE_WINDOW="..tostring(POST_EDGE_WINDOW))
    debugWarn(("[AimAssist] DETUNING: MIN_MOVE_MAG=%.2f DIR_THRESHOLD=%.2f SMALL_DELTA_THRESHOLD=%.2f HYST=%d STALE=%.1fs")
        :format(MIN_MOVE_MAG, DIR_THRESHOLD, SMALL_DELTA_THRESHOLD, HYSTERESIS_REQUIRED, STALE_TREND_TIMEOUT))
    debugWarn(("[AimAssist] TEMP TREND CONFIG: IMMEDIATE_MIN_PEAK=%.2f DURATION=%.2fs PRE_SNAP_TIME=%.2fs MAX_LEAD_ABS=%.2f MAX_LEAD_FRAC=%.2f"):format(IMMEDIATE_TREND_MIN_PEAK, TEMPORARY_TREND_DURATION, PRE_SNAP_TIME, MAX_LEAD_ABS, MAX_LEAD_FRACTION))
end
