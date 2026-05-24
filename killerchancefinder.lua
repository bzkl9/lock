-- LocalScript (StarterPlayer > StarterPlayerScripts)
-- KillerChance helper GUI
-- Toggle with "]"
-- Shows how much more KillerChance you need to be highest, or "enough", or "tied".

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local LP = Players.LocalPlayer
if not LP then return end

--========================
-- CLEANUP LAST RUN
--========================
local KEY = "__KILLERCHANCE_GUI_CTRL__"
if _G[KEY] and type(_G[KEY].Cleanup) == "function" then
	pcall(function() _G[KEY].Cleanup() end)
end

local ctrl = {
	conns = {},
	gui = nil,
	frame = nil,
	label = nil,
	visible = true,
	accum = 0,
}
_G[KEY] = ctrl

local function connect(sig, fn)
	local c = sig:Connect(fn)
	table.insert(ctrl.conns, c)
	return c
end

function ctrl.Cleanup()
	for _, c in ipairs(ctrl.conns) do
		pcall(function() c:Disconnect() end)
	end
	ctrl.conns = {}
	if ctrl.gui then pcall(function() ctrl.gui:Destroy() end) end
	ctrl.gui, ctrl.frame, ctrl.label = nil, nil, nil
end

--========================
-- UI
--========================
local function makeGui()
	local pg = LP:WaitForChild("PlayerGui")

	local old = pg:FindFirstChild("KillerChanceHelperGui")
	if old then old:Destroy() end

	local gui = Instance.new("ScreenGui")
	gui.Name = "KillerChanceHelperGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 999999
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = pg

	local frame = Instance.new("Frame")
	-- moved to upper-left
	frame.AnchorPoint = Vector2.new(0, 0)
	frame.Position = UDim2.new(0, 50, 0, 328)
	frame.Size = UDim2.new(0, 520, 0, 86)
	frame.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	frame.BackgroundTransparency = 0.18
	frame.BorderSizePixel = 0
	frame.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Transparency = 0.45
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Parent = frame

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.new(0, 14, 0, 8)
	title.Size = UDim2.new(1, -28, 0, 24)
	title.Font = Enum.Font.SourceSansBold
	title.TextSize = 18
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(235, 235, 235)
	title.TextStrokeTransparency = 0.75
	title.Text = "KillerChance Checker  (toggle ] )"
	title.Parent = frame

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = UDim2.new(0, 14, 0, 34)
	label.Size = UDim2.new(1, -28, 0, 44)
	label.Font = Enum.Font.SourceSansBold
	label.TextSize = 24
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextColor3 = Color3.fromRGB(255, 210, 120)
	label.TextStrokeTransparency = 0.7
	label.Text = "Loading..."
	label.Parent = frame

	return gui, frame, label
end

ctrl.gui, ctrl.frame, ctrl.label = makeGui()

local function setVisible(on)
	ctrl.visible = on
	if ctrl.gui then
		ctrl.gui.Enabled = on
	end
end

-- Toggle with ]
connect(UserInputService.InputBegan, function(input, gp)
	if gp then return end
	if input.KeyCode == Enum.KeyCode.RightBracket then
		setVisible(not ctrl.visible)
	end
end)

--========================
-- DATA: KillerChance compare
--========================
local function getKillerChanceValue(player)
	local pd = player:FindFirstChild("PlayerData")
	local stats = pd and pd:FindFirstChild("Stats")
	local general = stats and stats:FindFirstChild("General")
	local kc = general and general:FindFirstChild("KillerChance")
	if kc and (kc:IsA("NumberValue") or kc:IsA("IntValue")) then
		return kc.Value
	end
	return nil
end

local function updateText()
	if not ctrl.label then return end

	local myVal = getKillerChanceValue(LP)
	if myVal == nil then
		ctrl.label.TextColor3 = Color3.fromRGB(255, 120, 120)
		ctrl.label.Text = "KillerChance not found for you."
		return
	end

	local bestVal = myVal
	local bestPlayers = { LP }

	for _, plr in ipairs(Players:GetPlayers()) do
		local v = getKillerChanceValue(plr)
		if v ~= nil then
			if v > bestVal then
				bestVal = v
				bestPlayers = { plr }
			elseif v == bestVal then
				local exists = false
				for _, bp in ipairs(bestPlayers) do
					if bp == plr then exists = true break end
				end
				if not exists then
					table.insert(bestPlayers, plr)
				end
			end
		end
	end

	if bestVal == myVal then
		if #bestPlayers >= 2 then
			ctrl.label.TextColor3 = Color3.fromRGB(255, 210, 120)
			ctrl.label.Text = ("TIED for highest (KillerChance = %s)"):format(tostring(myVal))
		else
			ctrl.label.TextColor3 = Color3.fromRGB(120, 255, 160)
			ctrl.label.Text = ("You have enough! Highest KillerChance = %s"):format(tostring(myVal))
		end
	else
		local need = (bestVal - myVal) + 1
		ctrl.label.TextColor3 = Color3.fromRGB(255, 140, 140)
		ctrl.label.Text = ("Need +%s KillerChance to be highest (you: %s, top: %s)"):format(tostring(need), tostring(myVal), tostring(bestVal))
	end
end

-- Update loop
connect(RunService.Heartbeat, function(dt)
	ctrl.accum += dt
	if ctrl.accum < 0.35 then return end
	ctrl.accum = 0
	updateText()
end)

connect(Players.PlayerAdded, function() updateText() end)
connect(Players.PlayerRemoving, function() updateText() end)

updateText()
print("[KillerChanceHelper] Loaded. Toggle with ']'")
