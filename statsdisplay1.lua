-- LocalScript (StarterPlayer > StarterPlayerScripts)
-- Lobby: show full billboard stats
-- Ingame: show ONLY a down arrow colored by playtime tier, with SurvivorWins inside
-- Text only visible within 60 studs (lobby only)
-- Kills last instance
-- Only runs in placeId 18687417158

--========================
-- PLACE CHECK
--========================
if game.PlaceId ~= 18687417158 then
	return
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local LP = Players.LocalPlayer
if not LP then return end

--========================
-- CONFIG
--========================
local UPDATE_STATS_INTERVAL = 0.5
local UPDATE_VISUALS_INTERVAL = 0.12
local UPDATE_MODE_INTERVAL = 0.35

local TEXT_SHOW_RADIUS = 60

local OFFSET_Y_BILLBOARD = 10.2
local OFFSET_Y_ARROW = 7

local BASE_BB_WIDTH_PX  = 320
local BASE_BB_HEIGHT_PX = 180

local BASE_ARROW_SIZE_PX = 150

local REF_DISTANCE = 25
local MIN_SCALE = 0.35
local MAX_SCALE = 1.00
local USE_MAX_DISTANCE = true
local MAX_DISTANCE = 700

local TITLE_TEXT_SIZE = 28
local LINE_TEXT_SIZE = 27
local PLAYTIME_TEXT_SIZE = 35
local MIN_TEXT_SIZE = 10

local BG_TRANSPARENCY = 0.24
local STROKE_TRANSPARENCY = 0.55

--========================
-- NEW PLAYTIME TIERS (revamped)
-- Order now feels like "new -> experienced -> veteran -> elite"
-- 0-3: gray, 4-7: green, 7-11: blue, 11-20: purple, 20+: white/gold-ish
--========================
local TIERS = {
	{
		minDays = 0,  maxDays = 4,
		bg = Color3.fromRGB(28, 30, 36),        -- slate
		text = Color3.fromRGB(245, 245, 245),   -- white
		accentK = Color3.fromRGB(255, 90, 90),
		accentS = Color3.fromRGB(120, 255, 140),
		arrowText = Color3.fromRGB(255,255,255),
		arrowStroke = Color3.fromRGB(0,0,0),
	},
	{
		minDays = 4,  maxDays = 7,
		bg = Color3.fromRGB(18, 70, 44),        -- green
		text = Color3.fromRGB(245, 255, 245),
		accentK = Color3.fromRGB(255, 120, 120),
		accentS = Color3.fromRGB(170, 255, 190),
		arrowText = Color3.fromRGB(255,255,255),
		arrowStroke = Color3.fromRGB(0,0,0),
	},
	{
		minDays = 7,  maxDays = 11,
		bg = Color3.fromRGB(18, 52, 112),       -- blue
		text = Color3.fromRGB(245, 248, 255),
		accentK = Color3.fromRGB(255, 120, 120),
		accentS = Color3.fromRGB(175, 255, 195),
		arrowText = Color3.fromRGB(255,255,255),
		arrowStroke = Color3.fromRGB(0,0,0),
	},
	{
		minDays = 11, maxDays = 20,
		bg = Color3.fromRGB(76, 33, 112),       -- purple
		text = Color3.fromRGB(255, 245, 255),
		accentK = Color3.fromRGB(255, 120, 120),
		accentS = Color3.fromRGB(190, 255, 205),
		arrowText = Color3.fromRGB(255,255,255),
		arrowStroke = Color3.fromRGB(0,0,0),
	},
	{
		minDays = 20, maxDays = math.huge,
		bg = Color3.fromRGB(240, 236, 220),     -- warm white (still "white" tier)
		text = Color3.fromRGB(20, 20, 20),      -- dark text
		accentK = Color3.fromRGB(160, 0, 0),
		accentS = Color3.fromRGB(0, 120, 55),
		arrowText = Color3.fromRGB(20,20,20),
		arrowStroke = Color3.fromRGB(255,255,255),
	},
}

--========================
-- KILL LAST
--========================
if _G.StatShowerController and type(_G.StatShowerController.Cleanup) == "function" then
	pcall(function() _G.StatShowerController.Cleanup() end)
end

local ctrl = {
	running = true,
	conns = {},
	perPlayer = {}, -- [player] = { charConn, humConn, diedConn, healthConn, ancestryConn, displayMode, bb, ui, adornee, humanoid }
	accumStats = 0,
	accumVisual = 0,
	accumMode = 0,
	mode = "LOBBY", -- or "INGAME"
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

local function destroyDisplay(pp)
	if not pp then return end
	if pp.bb then
		pcall(function() pp.bb:Destroy() end)
	end
	pp.bb = nil
	pp.ui = nil
	pp.adornee = nil
	pp.humanoid = nil
	pp.displayMode = nil
end

function ctrl.Cleanup()
	ctrl.running = false
	for _, c in ipairs(ctrl.conns) do safeDisconnect(c) end
	ctrl.conns = {}

	for _, pp in pairs(ctrl.perPlayer) do
		safeDisconnect(pp.charConn)
		safeDisconnect(pp.humConn)
		safeDisconnect(pp.diedConn)
		safeDisconnect(pp.healthConn)
		safeDisconnect(pp.ancestryConn)
		destroyDisplay(pp)
	end
	ctrl.perPlayer = {}
end

--========================
-- MODE: LOBBY vs INGAME
--========================
local function getIngameFolder()
	local map = workspace:FindFirstChild("Map")
	return map and map:FindFirstChild("Ingame") or nil
end

local function computeMode()
	local ingame = getIngameFolder()
	if not ingame then
		return "LOBBY" -- fallback
	end
	return (#ingame:GetChildren() > 0) and "INGAME" or "LOBBY"
end

--========================
-- STATS HELPERS
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

local function toStr(v) return (v ~= nil) and tostring(v) or "?" end

local function secondsToDHMS(seconds)
	seconds = tonumber(seconds) or 0
	if seconds < 0 then seconds = 0 end
	local days = math.floor(seconds / 86400)
	local rem = seconds - days * 86400
	local hours = math.floor(rem / 3600); rem -= hours * 3600
	local mins = math.floor(rem / 60); rem -= mins * 60
	local secs = math.floor(rem)
	return days, hours, mins, secs
end

local function formatDHMS(d,h,m,s)
	return string.format("%d:%02d:%02d:%02d", d,h,m,s)
end

local function tierForDays(days)
	days = tonumber(days) or 0
	for _, t in ipairs(TIERS) do
		if days >= t.minDays and days < t.maxDays then
			return t
		end
	end
	return TIERS[1]
end

--========================
-- DISTANCE SCALING / VISIBILITY
--========================
local function scaleFromDistance(dist)
	local sc = REF_DISTANCE / math.max(dist, 1e-3)
	return math.clamp(sc, MIN_SCALE, MAX_SCALE)
end

local function localHRP()
	local ch = LP.Character
	return ch and ch:FindFirstChild("HumanoidRootPart") or nil
end

local function withinRadius(pp, radius)
	local my = localHRP()
	if my and pp.adornee then
		return (my.Position - pp.adornee.Position).Magnitude <= radius
	end
	local cam = workspace.CurrentCamera
	if cam and pp.adornee then
		return (cam.CFrame.Position - pp.adornee.Position).Magnitude <= radius
	end
	return false
end

local function applyTextScale(ui, scale)
	local function sized(base) return math.max(MIN_TEXT_SIZE, math.floor(base * scale + 0.5)) end
	ui.kTitle.TextSize = sized(TITLE_TEXT_SIZE)
	ui.sTitle.TextSize = sized(TITLE_TEXT_SIZE)
	ui.kWins.TextSize  = sized(LINE_TEXT_SIZE)
	ui.kLoss.TextSize  = sized(LINE_TEXT_SIZE)
	ui.sWins.TextSize  = sized(LINE_TEXT_SIZE)
	ui.sLoss.TextSize  = sized(LINE_TEXT_SIZE)
	ui.playtime.TextSize = sized(PLAYTIME_TEXT_SIZE)
end

local function setTextVisible(ui, on)
	for _, lbl in ipairs(ui.allLabels) do
		lbl.Visible = on
	end
end

--========================
-- UI: BILLBOARD (Lobby)
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

local function createBillboardUI(character, tier)
	local adornee = character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")
	if not adornee then
		adornee = character:WaitForChild("Head", 2) or character:FindFirstChild("HumanoidRootPart")
	end
	if not adornee then return nil, nil end

	local bb = Instance.new("BillboardGui")
	bb.Name = "StatShowerBillboard"
	bb.AlwaysOnTop = true
	bb.Adornee = adornee
	bb.ResetOnSpawn = false
	bb.Size = UDim2.new(0, BASE_BB_WIDTH_PX, 0, BASE_BB_HEIGHT_PX)
	if USE_MAX_DISTANCE then bb.MaxDistance = MAX_DISTANCE end

	pcall(function()
		bb.StudsOffsetWorldSpace = Vector3.new(0, OFFSET_Y_BILLBOARD, 0)
	end)

	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, 0, 1, 0)
	frame.BackgroundColor3 = tier.bg
	frame.BackgroundTransparency = BG_TRANSPARENCY
	frame.BorderSizePixel = 0
	frame.Parent = bb

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Transparency = STROKE_TRANSPARENCY
	stroke.Color = (tier.text == Color3.fromRGB(20,20,20)) and Color3.fromRGB(0,0,0) or Color3.fromRGB(255,255,255)
	stroke.Parent = frame

	local colPad, topPad = 14, 10
	local playH, playBottomPad = 60, 8

	local cols = Instance.new("Frame")
	cols.BackgroundTransparency = 1
	cols.Position = UDim2.new(0, colPad, 0, topPad)
	cols.Size = UDim2.new(1, -colPad*2, 1, -(topPad + playH + playBottomPad))
	cols.Parent = frame

	local left = Instance.new("Frame")
	left.BackgroundTransparency = 1
	left.Size = UDim2.new(0.5, -10, 1, 0)
	left.Parent = cols

	local right = Instance.new("Frame")
	right.BackgroundTransparency = 1
	right.Position = UDim2.new(0.5, 10, 0, 0)
	right.Size = UDim2.new(0.5, -10, 1, 0)
	right.Parent = cols

	local kTitle = makeLabel(left, "Killer:", TITLE_TEXT_SIZE, tier.accentK, Enum.TextXAlignment.Left, true)
	kTitle.Position = UDim2.new(0, 0, 0, 0)
	kTitle.Size = UDim2.new(1, 0, 0, TITLE_TEXT_SIZE + 6)

	local kWins = makeLabel(left, "Wins: ?", LINE_TEXT_SIZE, tier.text, Enum.TextXAlignment.Left, true)
	kWins.Position = UDim2.new(0, 0, 0, TITLE_TEXT_SIZE + 10)
	kWins.Size = UDim2.new(1, 0, 0, LINE_TEXT_SIZE + 6)

	local kLoss = makeLabel(left, "Losses: ?", LINE_TEXT_SIZE, tier.text, Enum.TextXAlignment.Left, true)
	kLoss.Position = UDim2.new(0, 0, 0, TITLE_TEXT_SIZE + LINE_TEXT_SIZE + 18)
	kLoss.Size = UDim2.new(1, 0, 0, LINE_TEXT_SIZE + 6)

	local sTitle = makeLabel(right, "Survivor:", TITLE_TEXT_SIZE, tier.accentS, Enum.TextXAlignment.Left, true)
	sTitle.Position = UDim2.new(0, 0, 0, 0)
	sTitle.Size = UDim2.new(1, 0, 0, TITLE_TEXT_SIZE + 6)

	local sWins = makeLabel(right, "Wins: ?", LINE_TEXT_SIZE, tier.text, Enum.TextXAlignment.Left, true)
	sWins.Position = UDim2.new(0, 0, 0, TITLE_TEXT_SIZE + 10)
	sWins.Size = UDim2.new(1, 0, 0, LINE_TEXT_SIZE + 6)

	local sLoss = makeLabel(right, "Losses: ?", LINE_TEXT_SIZE, tier.text, Enum.TextXAlignment.Left, true)
	sLoss.Position = UDim2.new(0, 0, 0, TITLE_TEXT_SIZE + LINE_TEXT_SIZE + 18)
	sLoss.Size = UDim2.new(1, 0, 0, LINE_TEXT_SIZE + 6)

	local playtime = makeLabel(frame, "TimePlayed : ?", PLAYTIME_TEXT_SIZE, tier.text, Enum.TextXAlignment.Center, true)
	playtime.AnchorPoint = Vector2.new(0.5, 1)
	playtime.Position = UDim2.new(0.5, 0, 1, -playBottomPad)
	playtime.Size = UDim2.new(1, -20, 0, playH)
	playtime.TextYAlignment = Enum.TextYAlignment.Center

	bb.Parent = character

	local ui = {
		frame = frame,
		stroke = stroke,
		kTitle = kTitle, kWins = kWins, kLoss = kLoss,
		sTitle = sTitle, sWins = sWins, sLoss = sLoss,
		playtime = playtime,
		allLabels = {kTitle,kWins,kLoss,sTitle,sWins,sLoss,playtime},
	}
	return bb, {adornee = adornee, ui = ui}
end

--========================
-- UI: ARROW (Ingame)
--========================
local function createArrowUI(character, tier)
	local adornee = character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")
	if not adornee then
		adornee = character:WaitForChild("Head", 2) or character:FindFirstChild("HumanoidRootPart")
	end
	if not adornee then return nil, nil end

	local bb = Instance.new("BillboardGui")
	bb.Name = "StatShowerArrow"
	bb.AlwaysOnTop = true
	bb.Adornee = adornee
	bb.ResetOnSpawn = false
	bb.Size = UDim2.new(0, BASE_ARROW_SIZE_PX, 0, BASE_ARROW_SIZE_PX)
	if USE_MAX_DISTANCE then bb.MaxDistance = MAX_DISTANCE end

	pcall(function()
		bb.StudsOffsetWorldSpace = Vector3.new(0, OFFSET_Y_ARROW, 0)
	end)

	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(1,0,1,0)
	holder.Parent = bb

	-- Arrow glyph (down)
	local arrow = Instance.new("TextLabel")
	arrow.BackgroundTransparency = 1
	arrow.Size = UDim2.new(1,0,1,0)
	arrow.Font = Enum.Font.SourceSansBold
	arrow.TextScaled = true
	arrow.Text = "▼"
	arrow.TextColor3 = tier.bg -- arrow color == tier color
	arrow.TextStrokeTransparency = 0.25
	arrow.TextStrokeColor3 = tier.arrowStroke
	arrow.Parent = holder

	-- Number centered in the arrow
	local num = Instance.new("TextLabel")
	num.BackgroundTransparency = 1
	num.AnchorPoint = Vector2.new(0.5, 0.5)
	num.Position = UDim2.new(0.5, 0, 0.55, 0)
	num.Size = UDim2.new(0.55, 0, 0.45, 0)
	num.Font = Enum.Font.SourceSansBold
	num.TextScaled = true
	num.Text = "?"
	num.TextColor3 = tier.arrowText
	num.TextStrokeTransparency = 0.4
	num.TextStrokeColor3 = tier.arrowStroke
	num.Parent = holder

	bb.Parent = character

	return bb, {
		adornee = adornee,
		arrow = arrow,
		num = num,
	}
end

--========================
-- DISPLAY BUILD/SWITCH
--========================
local function getTierFromTimePlayedSeconds(tPlayed)
	local d = 0
	if tPlayed ~= nil then
		d = math.floor((tonumber(tPlayed) or 0) / 86400)
	end
	return tierForDays(d), d
end

local function applyBillboardTheme(ui, tier)
	ui.frame.BackgroundColor3 = tier.bg
	ui.kTitle.TextColor3 = tier.accentK
	ui.sTitle.TextColor3 = tier.accentS

	ui.kWins.TextColor3 = tier.text
	ui.kLoss.TextColor3 = tier.text
	ui.sWins.TextColor3 = tier.text
	ui.sLoss.TextColor3 = tier.text
	ui.playtime.TextColor3 = tier.text

	ui.stroke.Color = (tier.text == Color3.fromRGB(20,20,20)) and Color3.fromRGB(0,0,0) or Color3.fromRGB(255,255,255)
	ui.stroke.Transparency = STROKE_TRANSPARENCY
end

local function ensureModeDisplay(plr, pp)
	if not plr.Character or not plr.Character.Parent then
		destroyDisplay(pp)
		return
	end

	-- Detect dead in a robust way
	if pp.humanoid and (pp.humanoid.Health <= 0) then
		destroyDisplay(pp)
		return
	end

	local _, _, sW, _, tPlayed = getStats(plr)
	local tier = getTierFromTimePlayedSeconds(tPlayed)

	if ctrl.mode == "LOBBY" then
		if pp.displayMode ~= "BILLBOARD" then
			destroyDisplay(pp)
			local bb, data = createBillboardUI(plr.Character, tier)
			if not bb or not data then return end
			pp.bb = bb
			pp.adornee = data.adornee
			pp.ui = data.ui
			pp.displayMode = "BILLBOARD"
		else
			-- refresh tier colors live
			if pp.ui then
				applyBillboardTheme(pp.ui, tier)
			end
		end
	else
		-- INGAME
		if pp.displayMode ~= "ARROW" then
			destroyDisplay(pp)
			local bb, data = createArrowUI(plr.Character, tier)
			if not bb or not data then return end
			pp.bb = bb
			pp.adornee = data.adornee
			pp.ui = data
			pp.displayMode = "ARROW"
		else
			-- refresh arrow color live
			if pp.ui and pp.ui.arrow then
				pp.ui.arrow.TextColor3 = tier.bg
				pp.ui.num.TextColor3 = tier.arrowText
				pp.ui.arrow.TextStrokeColor3 = tier.arrowStroke
				pp.ui.num.TextStrokeColor3 = tier.arrowStroke
			end
		end

		-- update the one number (SurvivorWins) in arrow
		if pp.ui and pp.ui.num then
			pp.ui.num.Text = toStr(sW)
		end
	end
end

--========================
-- UPDATE CONTENT
--========================
local function updateBillboardText(plr, pp)
	if pp.displayMode ~= "BILLBOARD" or not pp.ui then return end

	local kW, kL, sW, sL, t = getStats(plr)

	pp.ui.kWins.Text = "Wins: " .. toStr(kW)
	pp.ui.kLoss.Text = "Losses: " .. toStr(kL)
	pp.ui.sWins.Text = "Wins: " .. toStr(sW)
	pp.ui.sLoss.Text = "Losses: " .. toStr(sL)

	if t ~= nil then
		local d,h,m,s = secondsToDHMS(t)
		pp.ui.playtime.Text = "TimePlayed : " .. formatDHMS(d,h,m,s)
	else
		pp.ui.playtime.Text = "TimePlayed : ?"
	end

	-- tier refresh (also affects colors)
	local tier = getTierFromTimePlayedSeconds(t)
	applyBillboardTheme(pp.ui, tier)
end

local function applyVisualScaling(plr, pp)
	if not pp.bb or not pp.adornee or not pp.adornee.Parent then return end
	local cam = workspace.CurrentCamera
	if not cam then return end

	local dist = (cam.CFrame.Position - pp.adornee.Position).Magnitude
	if USE_MAX_DISTANCE and dist > MAX_DISTANCE then
		pp.bb.Enabled = false
		return
	end
	pp.bb.Enabled = true

	local sc = scaleFromDistance(dist)

	if pp.displayMode == "BILLBOARD" then
		pp.bb.Size = UDim2.new(0, math.floor(BASE_BB_WIDTH_PX * sc + 0.5), 0, math.floor(BASE_BB_HEIGHT_PX * sc + 0.5))
		if pp.ui then
			applyTextScale(pp.ui, sc)

			-- Lobby-only: show text only when within radius; otherwise background-only
			local showText = withinRadius(pp, TEXT_SHOW_RADIUS)
			setTextVisible(pp.ui, showText)
		end
	else
		-- Arrow
		pp.bb.Size = UDim2.new(0, math.floor(BASE_ARROW_SIZE_PX * sc + 0.5), 0, math.floor(BASE_ARROW_SIZE_PX * sc + 0.5))
	end
end

--========================
-- CHARACTER + DEATH HOOKS
--========================
local function hookHumanoidDeath(plr, pp, character)
	-- cleanup old
	safeDisconnect(pp.diedConn)
	safeDisconnect(pp.healthConn)
	safeDisconnect(pp.ancestryConn)
	pp.diedConn, pp.healthConn, pp.ancestryConn = nil, nil, nil
	pp.humanoid = nil

	local hum = character:FindFirstChildOfClass("Humanoid")
	if not hum then
		-- wait a moment for humanoid, but don't hard-freeze the script
		task.spawn(function()
			local h = character:WaitForChild("Humanoid", 4)
			if h and h:IsA("Humanoid") and ctrl.running then
				hookHumanoidDeath(plr, pp, character)
			end
		end)
		return
	end

	pp.humanoid = hum

	pp.diedConn = hum.Died:Connect(function()
		destroyDisplay(pp)
	end)

	pp.healthConn = hum.HealthChanged:Connect(function(hp)
		if hp <= 0 then
			destroyDisplay(pp)
		end
	end)

	-- if character leaves workspace (common in custom death systems)
	pp.ancestryConn = character.AncestryChanged:Connect(function(_, parent)
		if not parent then
			destroyDisplay(pp)
		end
	end)
end

--========================
-- PLAYER TRACKING
--========================
local function ensurePlayer(plr)
	if plr == LP then return end
	if ctrl.perPlayer[plr] then return end

	local pp = {
		charConn = nil,
		humConn = nil,
		diedConn = nil,
		healthConn = nil,
		ancestryConn = nil,
		displayMode = nil,
		bb = nil,
		ui = nil,
		adornee = nil,
		humanoid = nil,
	}
	ctrl.perPlayer[plr] = pp

	local function onChar(char)
		destroyDisplay(pp)
		hookHumanoidDeath(plr, pp, char)
		ensureModeDisplay(plr, pp) -- build correct mode display
	end

	pp.charConn = plr.CharacterAdded:Connect(onChar)
	if plr.Character then
		onChar(plr.Character)
	end
end

local function removePlayer(plr)
	local pp = ctrl.perPlayer[plr]
	if not pp then return end
	safeDisconnect(pp.charConn)
	safeDisconnect(pp.humConn)
	safeDisconnect(pp.diedConn)
	safeDisconnect(pp.healthConn)
	safeDisconnect(pp.ancestryConn)
	destroyDisplay(pp)
	ctrl.perPlayer[plr] = nil
end

--========================
-- INIT
--========================
ctrl.mode = computeMode()

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

	-- mode checks
	ctrl.accumMode += dt
	if ctrl.accumMode >= UPDATE_MODE_INTERVAL then
		ctrl.accumMode = 0
		local newMode = computeMode()
		if newMode ~= ctrl.mode then
			ctrl.mode = newMode
			-- rebuild displays for everyone
			for plr, pp in pairs(ctrl.perPlayer) do
				ensureModeDisplay(plr, pp)
			end
		end
	end

	-- visual scaling & radius visibility
	ctrl.accumVisual += dt
	if ctrl.accumVisual >= UPDATE_VISUALS_INTERVAL then
		ctrl.accumVisual = 0
		for plr, pp in pairs(ctrl.perPlayer) do
			if pp.bb then
				-- keep display up to date for current mode/tier
				ensureModeDisplay(plr, pp)
				applyVisualScaling(plr, pp)
			end
		end
	end

	-- stats text refresh (billboard only; arrow only needs survivor wins, handled in ensureModeDisplay)
	ctrl.accumStats += dt
	if ctrl.accumStats >= UPDATE_STATS_INTERVAL then
		ctrl.accumStats = 0
		for plr, pp in pairs(ctrl.perPlayer) do
			if pp.displayMode == "BILLBOARD" and pp.bb and pp.ui then
				updateBillboardText(plr, pp)
			else
				-- arrow mode: refresh number too in case it changed
				ensureModeDisplay(plr, pp)
			end
		end
	end
end)

print("[StatShower] Loaded. Lobby=billboard, Ingame=arrow(SurvivorWins). Tiers revamped.")
