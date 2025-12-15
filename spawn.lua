-- Respawn Location ESP (BoxHandleAdornment version)
-- LocalScript (place in StarterPlayerScripts)

local Players = game:GetService("Players")
local workspace = game:GetService("Workspace")

local LOCAL_PLAYER = Players.LocalPlayer
if not LOCAL_PLAYER then
    warn("[RespawnESP] No LocalPlayer; aborting.")
    return
end

local PLAYER_PREFIX = LOCAL_PLAYER.Name:lower()
local SUFFIX = "respawnlocation" -- strict suffix

local COLOR = BrickColor.new("Lime green")
local TRANSPARENCY = 0.5

local espObjects = {} -- [BasePart] = BoxHandleAdornment

local function isRespawnName(name)
    name = tostring(name or ""):lower()
    return name:sub(-15) == "respawnlocation"
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
    box.Parent = part

    espObjects[part] = box
end

local function removeESP(part)
    local box = espObjects[part]
    if box then
        box:Destroy()
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
        task.wait()
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
