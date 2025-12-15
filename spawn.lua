-- Respawn Location ESP (BoxHandleAdornment) - loadstring-ready
-- Hardened: waits for LocalPlayer, guarded with pcall, updates when parts resize.

local success, err = pcall(function()
    local Players = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local Workspace = game:GetService("Workspace")

    -- Wait for LocalPlayer (short timeout so loadstring doesn't hang forever)
    local LOCAL_PLAYER
    local max_wait_seconds = 5
    local waited = 0
    while not Players.LocalPlayer and waited < max_wait_seconds do
        task.wait(0.05)
        waited = waited + 0.05
    end
    LOCAL_PLAYER = Players.LocalPlayer

    if not LOCAL_PLAYER then
        warn("[RespawnESP] No LocalPlayer found after " .. tostring(max_wait_seconds) .. "s; aborting.")
        return
    end

    print("[RespawnESP] Running for LocalPlayer:", LOCAL_PLAYER.Name)

    local PLAYER_PREFIX = LOCAL_PLAYER.Name:lower()
    local SUFFIX = "respawnlocation" -- strict suffix match

    local COLOR = BrickColor.new("Lime green")
    local TRANSPARENCY = 0.5

    -- Maps: part -> { adornment = BoxHandleAdornment, sizeConn = RBXScriptConnection }
    local espObjects = {}

    local function isRespawnName(name)
        name = tostring(name or ""):lower()
        if #name < #SUFFIX then return false end
        return name:sub(-#SUFFIX) == SUFFIX
    end

    local function cleanupPartRecord(part)
        local data = espObjects[part]
        if not data then return end
        if data.adornment and data.adornment.Destroy then
            pcall(function() data.adornment:Destroy() end)
        end
        if data.sizeConn and data.sizeConn.Disconnect then
            pcall(function() data.sizeConn:Disconnect() end)
        end
        espObjects[part] = nil
    end

    local function addESP(part)
        if not part or not part:IsA("BasePart") then return end
        if espObjects[part] then return end

        local ok, box = pcall(function()
            local b = Instance.new("BoxHandleAdornment")
            b.Name = "RespawnESP"
            b.Adornee = part
            -- initialize size to part size; we will keep this updated below
            b.Size = part.Size
            b.AlwaysOnTop = true
            b.ZIndex = 0
            b.Transparency = TRANSPARENCY
            b.Color = COLOR
            -- parent to the part (works for Adornments)
            b.Parent = part
            return b
        end)

        if not ok or not box then
            warn("[RespawnESP] Failed to create adornment for part:", part, box)
            return
        end

        -- keep the box sized to the part if it changes size
        local sizeConn
        sizeConn = part:GetPropertyChangedSignal("Size"):Connect(function()
            if box and box.Parent then
                -- protect with pcall in case part is being destroyed concurrently
                pcall(function() box.Size = part.Size end)
            else
                -- if the box was removed/destroyed, clean up this record
                cleanupPartRecord(part)
                if sizeConn and sizeConn.Disconnect then
                    pcall(function() sizeConn:Disconnect() end)
                end
            end
        end)

        espObjects[part] = {
            adornment = box,
            sizeConn = sizeConn,
        }
    end

    local function removeESP(part)
        cleanupPartRecord(part)
    end

    -- Initial scan (small short delay to allow replication on slower runtimes)
    task.spawn(function()
        task.wait(0.05)
        for _, inst in ipairs(Workspace:GetDescendants()) do
            if inst:IsA("BasePart") and isRespawnName(inst.Name) then
                pcall(addESP, inst)
            end
        end
    end)

    -- Listen for newly added descendants
    local descendantAddedConn = Workspace.DescendantAdded:Connect(function(inst)
        -- small wait to reduce race with replication
        task.wait()
        if inst and inst:IsA("BasePart") and isRespawnName(inst.Name) then
            pcall(addESP, inst)
        end
    end)

    -- Cleanup when parts are removed/destroyed
    local descendantRemovingConn = Workspace.DescendantRemoving:Connect(function(inst)
        if inst and inst:IsA("BasePart") then
            pcall(removeESP, inst)
        end
    end)

    -- Optional periodic sweep: remove any stale entries (in case of weird replication)
    local sweepConn = RunService.Heartbeat:Connect(function()
        for part, data in pairs(espObjects) do
            if not part or not part:IsDescendantOf(Workspace) then
                cleanupPartRecord(part)
            end
        end
    end)

    print("[RespawnESP] Active for:", LOCAL_PLAYER.Name .. " + RespawnLocation")

    -- Keep references so garbage collector doesn't remove connections while script is running.
    -- If someone wants to kill this script, they can simply disconnect the connections created above:
    -- descendantAddedConn:Disconnect(); descendantRemovingConn:Disconnect(); sweepConn:Disconnect()
    -- (We don't auto-destroy them here because this script is intended to run client-side for the session.)

end)

if not success then
    warn("[RespawnESP] Error during execution:", err)
end
