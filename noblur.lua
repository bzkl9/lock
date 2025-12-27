--[[
	WARNING: Heads up! This script has not been verified by ScriptBlox. Use at your own risk!
]]
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local FastBlurRemover = {
    _effects = {},
    _connections = {}
}

function FastBlurRemover:Init()
    self:ScanAndDestroy()

    table.insert(self._connections, Lighting.ChildAdded:Connect(function(child)
        self:ProcessEffect(child)
    end))

    local PlayerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
    table.insert(self._connections, PlayerGui.DescendantAdded:Connect(function(descendant)
        self:ProcessEffect(descendant)
    end))

    table.insert(self._connections, RunService.Heartbeat:Connect(function()
        self:FastScan()
    end))
end

function FastBlurRemover:ProcessEffect(obj)
    if obj:IsA("BlurEffect") or obj:IsA("DepthOfFieldEffect") or obj:IsA("SunRaysEffect") then
        if not self._effects[obj] then
            self._effects[obj] = true
            obj.Enabled = false
            task.spawn(function()
                for _ = 1, 3 do
                    pcall(function() obj:Destroy() end)
                    if not obj.Parent then break end
                    task.wait(0.01)
                end
            end)
        end
    end
end

function FastBlurRemover:ScanAndDestroy()
    for _, child in ipairs(Lighting:GetChildren()) do
        self:ProcessEffect(child)
    end
    
    local PlayerGui = Players.LocalPlayer:FindFirstChild("PlayerGui")
    if PlayerGui then
        for _, descendant in ipairs(PlayerGui:GetDescendants()) do
            self:ProcessEffect(descendant)
        end
    end
end

function FastBlurRemover:FastScan()
    for _, effect in ipairs(Lighting:GetChildren()) do
        if (effect:IsA("BlurEffect") or effect:IsA("DepthOfFieldEffect")) and effect.Enabled then
            self:ProcessEffect(effect)
        end
    end
end

FastBlurRemover:Init()
