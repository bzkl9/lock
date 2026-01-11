-- Stat Shower (LocalScript) - StarterPlayer > StarterPlayerScripts
-- Two columns: Killer (red) + Survivor (green)
-- TimePlayed : D:HH:MM:SS
-- NEW:
--  - Only show TEXT when within TEXT_SHOW_RADIUS studs; otherwise show background color only.
--  - Box AND ALL text shrink with distance (no weird scaling differences).
--  - Fixed offset above head (world offset).
-- Re-running kills previous instance.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local LP = Players.LocalPlayer
if not LP then return end

--========================
-- CONFIG
--========================
local UPDATE_INTERVAL = 0.5

-- Only show text when you're within this radius of the player:
local TEXT_SHOW_RADIUS = 60

-- Fixed world offset above head:
local OFFSET_Y = 10.2

-- Base pixel size (scaled down with distance):
local BASE_WIDTH_PX  = 320
local BASE_HEIGHT_PX = 180

-- Distance scaling (shrinks visuals when far away)
local REF_DISTANCE = 25        -- around this distance, scale ~= 1
local MIN_SCALE = 0.35
local MAX_SCALE = 1.00

-- Optional: hide entire box past this distance (keeps things clean in huge lobbies)
local USE_MAX_DISTANCE = true
local MAX_DISTANCE = 500

-- Text sizes (base, when close)
local TITLE_TEXT_SIZE = 28
local LINE_TEXT_SIZE = 27
local PLAYTIME_TEXT_SIZE = 35

-- Keep text readable at far distances
local MIN_TEXT_SIZE = 10

-- Transparency
local BG_TRANSPARENCY = 0.22
local STROKE_TRANSPARENCY = 0.55

-- Background tiers by DAYS:
-- [0,4) default, [4,7) green, [7,11) orange, [11,20) blue, [20,∞) white
local BG_DEFAULT = Color3.fromRGB(14, 14, 18)
local BG_GREEN   = Color3.fromRGB(24, 78, 40)
local BG_ORANGE  = Color3.fromRGB(95, 58, 22)
local BG_BLUE    = Color3.fromRGB(28, 44, 105)
local BG_WHITE   = Color3.fromRGB(235, 235, 235)

-- Dark-theme text colors
local KILLER_COLOR_DARK   = Color3.fromRGB(255, 80, 80)
local SURVIVOR_COLOR_DARK = Color3.fromRGB(120, 255, 140)
local LINE_K_DARK         = Color3.fromRGB(255, 225, 225)
local LINE_S_DARK         = Color3.fromRGB(220, 255, 230)
local PLAYTIME_DARK       = Color3.fromRGB(235, 235, 235)
local STROKE_DARK         = Color3.fromRGB(255, 255, 255)

-- Light-theme text colors (for white background tier)
local KILLER_COLOR_LIGHT   = Color3.fromRGB(160, 0, 0)
local SURVIVOR_COLOR_LIGHT = Color3.fromRGB(0, 120, 55)
local LINE_LIGHT           = Color3.fromRGB(20, 20, 20)
local PLAYTIME_LIGHT       = Color3.fromRGB(10, 10, 10)
local STROKE_LIGHT         = Color3.fromRGB(0, 0, 0)

--========================
-- KILL LAST
--========================
if _G.StatShowerController and type(_G.StatShowerController.Cleanup) == "function" then
	pcall(function() _G.StatShowerController.Cleanup() end)
end

local ctrl = {
	running = true,
	conns = {},
	perPlayer = {}, -- [player] = { charConn, billboard, ui = {...}, adornee = Instance }
	accum = 0,
}

_G.StatShowerController = ctrl

local function connect(sig, fn)
	local c = sig:Connect(fn)
	table.insert(ctrl.conns, c)
	return c
end

local function safeDisconnect(c)
	if c then pcall(function() c:Disconnect() end) end
end

local function destroyBillboard(pp)
	if not pp then return end
	if pp.billboard then
		pcall(function() pp.billboard:Destroy() end)
	end
	pp.billboard = nil
	pp.ui = nil
	pp.adornee = nil
end

function ctrl.Cleanup()
	ctrl.running = false
	for _, c in ipairs(ctrl.conns) do safeDisconnect(c) end
	ctrl.conns = {}

	for plr, pp in pairs(ctrl.perPlayer) do
		if pp.charConn then safeDisconnect(pp.charConn) end
		destroyBillboard(pp)
		ctrl.perPlayer[plr] = nil
	end
end

--========================
-- DATA HELPERS
--========================
local function getValue(obj)
	if not obj then return nil end
	if obj:IsA("NumberValue") or obj:IsA("IntValue") then
		return obj.Value
	end
	return nil
end

local function getStats(player)
	local pd = player:FindFirstChild("PlayerData")
	local stats = pd and pd:FindFirstChild("Stats")

	local killerStats = stats and stats:FindFirstChild("KillerStats")
	local survivorStats = stats and stats:FindFirstChild("SurvivorStats")
	local generalStats = stats and stats:FindFirstChild("General")

	local kWins = getValue(killerStats and killerStats:FindFirstChild("KillerWins"))
	local kLoss = getValue(killerStats and killerStats:FindFirstChild("KillerLosses"))

	local sWins = getValue(survivorStats and survivorStats:FindFirstChild("SurvivorWins"))
	local sLoss = getValue(survivorStats and survivorStats:FindFirstChild("SurvivorLosses"))

	local tPlayed = getValue(generalStats and generalStats:FindFirstChild("TimePlayed")) -- seconds

	return kWins, kLoss, sWins, sLoss, tPlayed
end

local function toStr(v)
	return (v ~= nil) and tostring(v) or "?"
end

local function secondsToDHMS(seconds)
	seconds = tonumber(seconds) or 0
	if seconds < 0 then seconds = 0 end

	local days = math.floor(seconds / 86400)
	local rem = seconds - days * 86400

	local hours = math.floor(rem / 3600)
	rem = rem - hours * 3600

	local mins = math.floor(rem / 60)
	rem = rem - mins * 60

	local secs = math.floor(rem)
	return days, hours, mins, secs
end

local function formatDHMS(days, hours, mins, secs)
	return string.format("%d:%02d:%02d:%02d", days, hours, mins, secs)
end

local function pickBgForDays(days)
	if days < 4 then
		return BG_DEFAULT, false
	elseif days < 7 then
		return BG_GREEN, false
	elseif days < 11 then
		return BG_ORANGE, false
	elseif days < 20 then
		return BG_BLUE, false
	else
		return BG_WHITE, true
	end
end

--========================
-- THEME / VISIBILITY / SCALE
--========================
local function applyTheme(ui, bgColor, useLightText)
	ui.frame.BackgroundColor3 = bgColor

	if useLightText then
		ui.stroke.Color = STROKE_LIGHT
		ui.stroke.Transparency = STROKE_TRANSPARENCY

		ui.kTitle.TextColor3 = KILLER_COLOR_LIGHT
		ui.sTitle.TextColor3 = SURVIVOR_COLOR_LIGHT

		ui.kWins.TextColor3 = LINE_LIGHT
		ui.kLoss.TextColor3 = LINE_LIGHT
		ui.sWins.TextColor3 = LINE_LIGHT
		ui.sLoss.TextColor3 = LINE_LIGHT

		ui.playtime.TextColor3 = PLAYTIME_LIGHT
	else
		ui.stroke.Color = STROKE_DARK
		ui.stroke.Transparency = STROKE_TRANSPARENCY

		ui.kTitle.TextColor3 = KILLER_COLOR_DARK
		ui.sTitle.TextColor3 = SURVIVOR_COLOR_DARK

		ui.kWins.TextColor3 = LINE_K_DARK
		ui.kLoss.TextColor3 = LINE_K_DARK
		ui.sWins.TextColor3 = LINE_S_DARK
		ui.sLoss.TextColor3 = LINE_S_DARK

		ui.playtime.TextColor3 = PLAYTIME_DARK
	end
end

local function setTextVisible(ui, on)
	for _, lbl in ipairs(ui.allLabels) do
		lbl.Visible = on
	end
end

local function applyTextScale(ui, scale)
	-- scale the pixel font sizes so all text shrinks with distance
	local function sized(base)
		return math.max(MIN_TEXT_SIZE, math.floor(base * scale + 0.5))
	end
	ui.kTitle.TextSize = sized(TITLE_TEXT_SIZE)
	ui.sTitle.TextSize = sized(TITLE_TEXT_SIZE)

	ui.kWins.TextSize  = sized(LINE_TEXT_SIZE)
	ui.kLoss.TextSize  = sized(LINE_TEXT_SIZE)
	ui.sWins.TextSize  = sized(LINE_TEXT_SIZE)
	ui.sLoss.TextSize  = sized(LINE_TEXT_SIZE)

	ui.playtime.TextSize = sized(PLAYTIME_TEXT_SIZE)
end

local function computeScaleFromDistance(dist)
	local scale = REF_DISTANCE / math.max(dist, 1e-3)
	return math.clamp(scale, MIN_SCALE, MAX_SCALE)
end

local function applyDistanceScale(pp)
	if not pp.billboard or not pp.adornee or not pp.adornee.Parent then return end
	local bb = pp.billboard

	local cam = workspace.CurrentCamera
	if not cam then return end

	local dist = (cam.CFrame.Position - pp.adornee.Position).Magnitude

	if USE_MAX_DISTANCE and dist > MAX_DISTANCE then
		bb.Enabled = false
		return
	end
	bb.Enabled = true

	local scale = computeScaleFromDistance(dist)

	bb.Size = UDim2.new(
		0, math.floor(BASE_WIDTH_PX * scale + 0.5),
		0, math.floor(BASE_HEIGHT_PX * scale + 0.5)
	)

	if pp.ui then
		applyTextScale(pp.ui, scale)
	end
end

local function getLocalHRP()
	local char = LP.Character
	if not char then return nil end
	return char:FindFirstChild("HumanoidRootPart")
end

local function withinTextRadius(pp)
	local myHRP = getLocalHRP()
	if not myHRP or not pp.adornee then
		-- fallback to camera if HRP missing
		local cam = workspace.CurrentCamera
		if not cam or not pp.adornee then return false end
		return (cam.CFrame.Position - pp.adornee.Position).Magnitude <= TEXT_SHOW_RADIUS
	end
	return (myHRP.Position - pp.adornee.Position).Magnitude <= TEXT_SHOW_RADIUS
end

--========================
-- UI CREATION
--========================
local function makeLabel(parent, text, size, color, alignX, bold)
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Text = text or ""
	lbl.Font = bold and Enum.Font.SourceSansBold or Enum.Font.SourceSans
	lbl.TextSize = size
	lbl.TextColor3 = color
	lbl.TextStrokeTransparency = 0.65
	lbl.TextXAlignment = alignX or Enum.TextXAlignment.Left
	lbl.TextYAlignment = Enum.TextYAlignment.Top
	lbl.TextWrapped = false
	lbl.Parent = parent
	return lbl
end

local function createBillboard(character)
	if not character then return nil, nil, nil end

	local adornee = character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")
	if not adornee then
		adornee = character:WaitForChild("Head", 2) or character:FindFirstChild("HumanoidRootPart")
	end
	if not adornee then return nil, nil, nil end

	local bb = Instance.new("BillboardGui")
	bb.Name = "StatShowerBillboard"
	bb.AlwaysOnTop = true
	bb.Adornee = adornee
	bb.ResetOnSpawn = false
	bb.Size = UDim2.new(0, BASE_WIDTH_PX, 0, BASE_HEIGHT_PX)

	-- fixed world-space offset above head
	local ok = pcall(function()
		bb.StudsOffsetWorldSpace = Vector3.new(0, OFFSET_Y, 0)
	end)
	if not ok then
		bb.StudsOffset = Vector3.new(0, OFFSET_Y, 0)
	end

	if USE_MAX_DISTANCE then
		bb.MaxDistance = MAX_DISTANCE
	end

	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, 0, 1, 0)
	frame.BackgroundColor3 = BG_DEFAULT
	frame.BackgroundTransparency = BG_TRANSPARENCY
	frame.BorderSizePixel = 0
	frame.Parent = bb

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = STROKE_DARK
	stroke.Transparency = STROKE_TRANSPARENCY
	stroke.Parent = frame

	-- Layout sizing
	local colPad = 14
	local topPad = 10
	local playH = 60
	local playBottomPad = 8

	local cols = Instance.new("Frame")
	cols.BackgroundTransparency = 1
	cols.Position = UDim2.new(0, colPad, 0, topPad)
	cols.Size = UDim2.new(1, -colPad*2, 1, -(topPad + playH + playBottomPad))
	cols.Parent = frame

	local left = Instance.new("Frame")
	left.BackgroundTransparency = 1
	left.Position = UDim2.new(0, 0, 0, 0)
	left.Size = UDim2.new(0.5, -10, 1, 0)
	left.Parent = cols

	local right = Instance.new("Frame")
	right.BackgroundTransparency = 1
	right.Position = UDim2.new(0.5, 10, 0, 0)
	right.Size = UDim2.new(0.5, -10, 1, 0)
	right.Parent = cols

	-- Killer
	local kTitle = makeLabel(left, "Killer:", TITLE_TEXT_SIZE, KILLER_COLOR_DARK, Enum.TextXAlignment.Left, true)
	kTitle.Position = UDim2.new(0, 0, 0, 0)
	kTitle.Size = UDim2.new(1, 0, 0, TITLE_TEXT_SIZE + 6)

	local kWins = makeLabel(left, "Wins: ?", LINE_TEXT_SIZE, LINE_K_DARK, Enum.TextXAlignment.Left, true)
	kWins.Position = UDim2.new(0, 0, 0, TITLE_TEXT_SIZE + 10)
	kWins.Size = UDim2.new(1, 0, 0, LINE_TEXT_SIZE + 6)

	local kLoss = makeLabel(left, "Losses: ?", LINE_TEXT_SIZE, LINE_K_DARK, Enum.TextXAlignment.Left, true)
	kLoss.Position = UDim2.new(0, 0, 0, TITLE_TEXT_SIZE + LINE_TEXT_SIZE + 18)
	kLoss.Size = UDim2.new(1, 0, 0, LINE_TEXT_SIZE + 6)

	-- Survivor
	local sTitle = makeLabel(right, "Survivor:", TITLE_TEXT_SIZE, SURVIVOR_COLOR_DARK, Enum.TextXAlignment.Left, true)
	sTitle.Position = UDim2.new(0, 0, 0, 0)
	sTitle.Size = UDim2.new(1, 0, 0, TITLE_TEXT_SIZE + 6)

	local sWins = makeLabel(right, "Wins: ?", LINE_TEXT_SIZE, LINE_S_DARK, Enum.TextXAlignment.Left, true)
	sWins.Position = UDim2.new(0, 0, 0, TITLE_TEXT_SIZE + 10)
	sWins.Size = UDim2.new(1, 0, 0, LINE_TEXT_SIZE + 6)

	local sLoss = makeLabel(right, "Losses: ?", LINE_TEXT_SIZE, LINE_S_DARK, Enum.TextXAlignment.Left, true)
	sLoss.Position = UDim2.new(0, 0, 0, TITLE_TEXT_SIZE + LINE_TEXT_SIZE + 18)
	sLoss.Size = UDim2.new(1, 0, 0, LINE_TEXT_SIZE + 6)

	-- TimePlayed single line, anchored bottom
	local playtime = makeLabel(frame, "TimePlayed : ?", PLAYTIME_TEXT_SIZE, PLAYTIME_DARK, Enum.TextXAlignment.Center, true)
	playtime.AnchorPoint = Vector2.new(0.5, 1)
	playtime.Position = UDim2.new(0.5, 0, 1, -playBottomPad)
	playtime.Size = UDim2.new(1, -20, 0, playH)
	playtime.TextYAlignment = Enum.TextYAlignment.Center
	playtime.TextWrapped = false

	bb.Parent = character

	local ui = {
		frame = frame,
		stroke = stroke,
		kTitle = kTitle, kWins = kWins, kLoss = kLoss,
		sTitle = sTitle, sWins = sWins, sLoss = sLoss,
		playtime = playtime,
	}
	ui.allLabels = { kTitle, kWins, kLoss, sTitle, sWins, sLoss, playtime }

	return bb, adornee, ui
end

--========================
-- UPDATE UI TEXT/THEME
--========================
local function updateUIForPlayer(plr, ui)
	local kW, kL, sW, sL, t = getStats(plr)

	ui.kWins.Text = "Wins: " .. toStr(kW)
	ui.kLoss.Text = "Losses: " .. toStr(kL)

	ui.sWins.Text = "Wins: " .. toStr(sW)
	ui.sLoss.Text = "Losses: " .. toStr(sL)

	if t ~= nil then
		local d, h, m, s = secondsToDHMS(t)
		local timeStr = formatDHMS(d, h, m, s)
		ui.playtime.Text = "TimePlayed : " .. timeStr

		local bg, light = pickBgForDays(d)
		applyTheme(ui, bg, light)
	else
		ui.playtime.Text = "TimePlayed : ?"
		applyTheme(ui, BG_DEFAULT, false)
	end
end

--========================
-- PLAYER TRACKING
--========================
local function ensurePlayer(player)
	if player == LP then return end
	if ctrl.perPlayer[player] then return end

	local pp = { player = player, charConn = nil, billboard = nil, ui = nil, adornee = nil }
	ctrl.perPlayer[player] = pp

	local function onChar(char)
		destroyBillboard(pp)
		local bb, adornee, ui = createBillboard(char)
		pp.billboard, pp.adornee, pp.ui = bb, adornee, ui

		if pp.ui then
			updateUIForPlayer(player, pp.ui)
			-- start hidden until radius check runs
			setTextVisible(pp.ui, false)
		end

		applyDistanceScale(pp)
	end

	pp.charConn = player.CharacterAdded:Connect(onChar)
	if player.Character then
		onChar(player.Character)
	end
end

local function removePlayer(player)
	local pp = ctrl.perPlayer[player]
	if not pp then return end
	safeDisconnect(pp.charConn)
	destroyBillboard(pp)
	ctrl.perPlayer[player] = nil
end

--========================
-- INIT
--========================
for _, plr in ipairs(Players:GetPlayers()) do
	ensurePlayer(plr)
end

connect(Players.PlayerAdded, ensurePlayer)
connect(Players.PlayerRemoving, removePlayer)

--========================
-- MAIN LOOP
--========================
connect(RunService.Heartbeat, function(dt)
	if not ctrl.running then return end

	-- per-frame: distance scaling + text visibility radius
	for _, pp in pairs(ctrl.perPlayer) do
		if pp.billboard and pp.ui and pp.adornee then
			applyDistanceScale(pp)

			local showText = withinTextRadius(pp)
			setTextVisible(pp.ui, showText)
		end
	end

	-- interval: update stats text + background tiers
	ctrl.accum += dt
	if ctrl.accum < UPDATE_INTERVAL then return end
	ctrl.accum = 0

	for plr, pp in pairs(ctrl.perPlayer) do
		if pp.ui and plr.Parent then
			updateUIForPlayer(plr, pp.ui)
		end
	end
end)

print("[StatShower] Loaded. Text shows within 60 studs; background-only outside. Box+text shrink with distance.")
