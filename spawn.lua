-- Respawn Location ESP (BoxHandleAdornment version)
-- Hardened for execution via loadstring (waits for LocalPlayer & prints debug)

local Players = game:GetService("Players")
local workspace = game:GetService("Workspace")

-- Wait for LocalPlayer (gives executors/replication a short window)
local LOCAL_PLAYER = Players.LocalPlayer
local max_wait_seconds = 5
local waited = 0
while not LOCAL_PLAYER and waited < max_wait_seconds do
    task.wait(0.05)
    waited = waited + 0.05
    LOCAL_PLAYER = Players.LocalPlayer
end

if not LOCAL_PLAYER then
    warn("[RespawnESP] No LocalPlayer found after " .. tostring(max_wait_seconds) .. "s; aborting.")
    return
end

print("[RespawnESP] Running for LocalPlayer:", LOCAL_PLAYER.Name)

local PLAYER_PREFIX = LOCAL_PLAYER.Name:lower()
local SUFFIX = "respawnlocation" -- strict suffix

local COLOR = BrickColor.new("Lime green")
local TRANSPARENCY = 0.5

local espObjects = {} -- [BasePart] = BoxHandleAdornment

local function isRespawnName(name)
    name = tostring(name or ""):lower()
    return name:sub(-#SUFFIX) == SUFFIX
end

local function addESP(part)
    if espObjects[part] then return end
    if not part or not part:IsA("BasePart") then return end

    local box = Instance.new("BoxHandleAdornment")
    box.Name = "RespawnESP"
    box.Adornee = part
    box.Size = part.Size
    box.AlwaysOnTop = true
    box.ZIndex = 0
    box.Transparency = TRANSPARENCY
    box.Color = COLOR
    -- parent to the part (this is fine for an adornment)
    box.Parent = part

    espObjects[part] = box
end

local function removeESP(part)
    local box = espObjects[part]
    if box then
        if box and box.Destroy then
            box:Destroy()
        end
        espObjects[part] = nil
    end
end

local function scan()
    for _, inst in ipairs(workspace:GetDescendants()) do
        if inst:IsA("BasePart") and isRespawnName(inst.Name) then
            addESP(inst)
        end
    end
end

-- Initial scan
scan()

-- Catch newly added parts (small wait for replication)
workspace.DescendantAdded:Connect(function(inst)
    if inst:IsA("BasePart") and isRespawnName(inst.Name) then
        task.wait() -- small wait to ensure replication
        addESP(inst)
    end
end)

-- Cleanup when parts removed
workspace.DescendantRemoving:Connect(function(inst)
    if inst:IsA("BasePart") then
        removeESP(inst)
    end
end)

print("[RespawnESP] Active for:", LOCAL_PLAYER.Name .. " + RespawnLocation")
