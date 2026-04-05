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

