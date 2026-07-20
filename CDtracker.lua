local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
	return
end

--//======================================================
--// SINGLETON / HARD KILL PREVIOUS INSTANCE
--//======================================================

local SINGLETON_KEY = "__CDTracker_MULTI_SURVIVOR_SINGLETON__"

do
	local old = rawget(_G, SINGLETON_KEY)
	if type(old) == "table" and old.Destroy then
		pcall(function()
			old:Destroy()
		end)
	end
end

local runtime = {
	Alive = true,
	GlobalConnections = {},
	Trackers = {},
}

function runtime:IsDead()
	return (not self.Alive) or rawget(_G, SINGLETON_KEY) ~= self
end

function runtime:AddGlobalConnection(conn)
	table.insert(self.GlobalConnections, conn)
	return conn
end

function runtime:DisconnectList(list)
	for _, conn in ipairs(list) do
		pcall(function()
			if conn then
				conn:Disconnect()
			end
		end)
	end
	table.clear(list)
end

function runtime:Destroy()
	if not self.Alive then
		return
	end

	self.Alive = false

	for _, tracker in pairs(self.Trackers) do
		if tracker and tracker.Destroy then
			pcall(function()
				tracker:Destroy()
			end)
		end
	end
	table.clear(self.Trackers)

	self:DisconnectList(self.GlobalConnections)

	if rawget(_G, SINGLETON_KEY) == self then
		_G[SINGLETON_KEY] = nil
	end
end

_G[SINGLETON_KEY] = runtime

--//======================================================
--// CONFIG
--//======================================================

local SURVIVORS_PATH = {"Players", "Survivors"}
local RESISTANCE_FOLDER_NAME = "ResistanceMultipliers"
local BILLBOARD_NAME_PREFIX = "CDTracker_"

local BOX_WORLD_SIZE = 2.0
local BOX_WORLD_GAP = 0.08
local HEAD_GAP_STUDS = -10
local MAX_DISTANCE = 200

local READY_TOP = Color3.fromRGB(58, 126, 255)
local READY_BOTTOM = Color3.fromRGB(37, 101, 224)

local COOLDOWN_TOP = Color3.fromRGB(231, 70, 70)
local COOLDOWN_BOTTOM = Color3.fromRGB(174, 36, 36)

local OUTER_BG = Color3.fromRGB(24, 24, 24)
local OUTER_STROKE = Color3.fromRGB(72, 72, 72)
local TEXT_COLOR = Color3.fromRGB(255, 255, 255)
local COVER_TRANSPARENCY = 0.14

local READY_FLASH_COLOR = Color3.fromRGB(185, 225, 255)
local READY_FLASH_TIME_IN = 0.10
local READY_FLASH_TIME_OUT = 0.18

local ATTRIBUTE_EVENT_DELAY = 0.30
local EXCLUDED_MOVE_MATCH_WINDOW = 0.60

--[[
HOW TO EDIT LATER

For any move that watches animations:
	TriggerType = "AnimationPlayed"
	AnimationIds = {
		"123456789",
		"987654321",
	}

To add more animation ids later, just add more ids to that move's AnimationIds list.

If you want a small prep countdown to appear when a certain animation plays,
add:
	PrepAnimationIds = { "someAnimationId" }
	PrepDuration = 7.5

Supported TriggerType values in this version:
	"AnimationPlayed"
	"ResistanceValueEquals"
	"AttributeBoolTrue"
	"AttributeNumberEquals"
	"AttributeGroupEnds"
	"AttributeIncreaseExcludingMove"
	"GuestBlockBySpeedMultiplier"
	"GuestChargeByAbilityIncrease"
	"GuestPunchByTimesHitLowDamage"

AnimationPlayed:
	AnimationIds = { "id1", "id2", ... }

ResistanceValueEquals:
	FolderName = "ResistanceMultipliers"
	ValueObjectName = "ResistanceStatus"
	ExpectedValue = number

AttributeBoolTrue:
	AttributeName = "SomeBoolAttribute"
	Starts cooldown when that model attribute becomes true.

AttributeNumberEquals:
	AttributeName = "SomeNumberAttribute"
	ExpectedValue = number
	Starts cooldown when that model attribute becomes the expected number.

AttributeGroupEnds:
	AttributeNames = { "Attr1", "Attr2", ... }
	When any of them become true, move is considered active.
	When all of them become false again, cooldown starts.
	Optional:
		PrepAnimationIds = { "id1", ... }
		PrepDuration = 7.5
		This shows a small top-left countdown when one of those prep animations plays.

AttributeIncreaseExcludingMove:
	AttributeName = "AbilitiesUsed"
	ExcludedMoveLabel = "Throw Pizza"
	When the numeric attribute increases, start cooldown,
	UNLESS that increase matches the excluded move within the time window.

GuestBlockBySpeedMultiplier:
	FolderName = "SpeedMultipliers"
	ChildName = "GuestBlocking"
	Starts cooldown when that child exists inside the configured folder.
	It only triggers once while the child exists, then can trigger again after the child is removed and appears again.

GuestChargeByAbilityIncrease:
	AttributeName = "AbilitiesUsed"
	Starts cooldown when that numeric attribute increases,
	UNLESS Block matched around the same time.
	Also checks the configured resistance conditions before starting cooldown.

GuestPunchByTimesHitLowDamage:
	AttributeName = "TimesHit"
	Shows the Punch box only when that numeric attribute increases
	and the survivor loses less than the configured health threshold.
	If the configured resistance value is detected, the Punch box is hidden again.

Optional:
	ShowUseCount = true
]]

local SURVIVOR_CONFIGS = {
	Guest1337 = {
		Name = "Guest1337",
		Moves = {
			{
				Label = "Block",
				Cooldown = 30,
				TriggerType = "GuestBlockBySpeedMultiplier",
				FolderName = "SpeedMultipliers",
				ChildName = "GuestBlocking",
			},
			{
				Label = "Charge",
				Cooldown = 39.7,
				TriggerType = "GuestChargeByAbilityIncrease",
				AttributeName = "AbilitiesUsed",
				BlockMoveLabel = "Block",
				BlockAttributeName = "HitboxPriority",
				BlockValue = 3,
				FolderName = "ResistanceMultipliers",
				ValueObjectName = "ResistanceStatus",
				AllowedWhenFolderEmpty = true,
				AllowedResistanceValue = 100,
			},
			{
				Label = "Punch",
				Cooldown = 0,
				TriggerType = "GuestPunchByTimesHitLowDamage",
				AttributeName = "TimesHit",
				HealthLossThreshold = 1,
				FolderName = "ResistanceMultipliers",
				ValueObjectName = "ResistanceStatus",
				HideWhenValue = 40,
				StartHidden = true,
			},
		},
	},

	Shedletsky = {
		Name = "Shedletsky",
		Moves = {
			{
				Label = "Slash",
				Cooldown = 40,
				TriggerType = "ResistanceValueEquals",
				FolderName = "ResistanceMultipliers",
				ValueObjectName = "ResistanceStatus",
				ExpectedValue = 40,
				ShowUseCount = true,
			},
			{
				Label = "Fried Chicken",
				Cooldown = 70,
				TriggerType = "AnimationPlayed",
				AnimationIds = {
					"121781457295101",
				},
				ShowUseCount = true,
			},
		},
	},

	Elliot = {
		Name = "Elliot",
		Moves = {
			{
				Label = "Throw Pizza",
				Cooldown = 45,
				TriggerType = "AnimationPlayed",
				AnimationIds = {
					"114155003741146",
				},
			},
			{
				Label = "Rush Hour",
				Cooldown = 40,
				TriggerType = "AttributeIncreaseExcludingMove",
				AttributeName = "AbilitiesUsed",
				ExcludedMoveLabel = "Throw Pizza",
			},
		},
	},

	Noob = {
		Name = "Noob",
		Moves = {
			{
				Label = "Bloxy Cola",
				Cooldown = 50,
				TriggerType = "AnimationPlayed",
				AnimationIds = {
					"124033675853489",
				},
			},
			{
				Label = "Slateskin",
				Cooldown = 55,
				TriggerType = "AttributeGroupEnds",
				AttributeNames = {
					"BleedingDisabled",
					"BurningDisabled",
					"CorruptedDisabled",
					"PoisonedDisabled",
					"RegenerationDisabled",
				},
				PrepAnimationIds = {
					"96771054624545",
				},
				PrepDuration = 7.5,
			},
			{
				Label = "Ghostburger",
				Cooldown = 45,
				TriggerType = "AnimationPlayed",
				AnimationIds = {
					"121781457295101",
				},
			},
		},
	},

	["007n7"] = {
		Name = "007n7",
		Moves = {
			{
				Label = "Clone",
				Cooldown = 27,
				TriggerType = "AttributeBoolTrue",
				AttributeName = "Undetectable",
			},
			{
				Label = "Teleport",
				Cooldown = 50,
				TriggerType = "AnimationPlayed",
				AnimationIds = {
					"123915228705093",
				},
			},
		},
	},

	TwoTime = {
		Name = "TwoTime",
		Moves = {
			{
				Label = "Stab",
				Cooldown = 30,
				TriggerType = "ResistanceValueEquals",
				FolderName = "ResistanceMultipliers",
				ValueObjectName = "ResistanceStatus",
				ExpectedValue = 20,
			},
			{
				Label = "Hide",
				Cooldown = 45,
				TriggerType = "AttributeBoolTrue",
				AttributeName = "Crouching",
			},
		},
	},

	Dusekkar = {
		Name = "Dusekkar",
		Moves = {
			{
				Label = "Protection",
				Cooldown = 30,
				TriggerType = "AnimationPlayed",
				AnimationIds = {
					"92305864294317",
				},
			},
			{
				Label = "Beam",
				Cooldown = 30,
				TriggerType = "AnimationPlayed",
				AnimationIds = {
					"77894750279891",
				},
			},
		},
	},

	Chance = {
		Name = "Chance",
		Moves = {
			{
				Label = "Shoot",
				Cooldown = 45,
				TriggerType = "AnimationPlayed",
				AnimationIds = {
					"133491532453922",
				},
			},
		},
	},

	JaneDoe = {
		Name = "JaneDoe",
		Moves = {
			{
				Label = "Pitch",
				Cooldown = 16,
				TriggerType = "AnimationPlayed",
				AnimationIds = {
					"139929602101552",
				},
			},
			{
				Label = "Hachet",
				Cooldown = 35,
				TriggerType = "ResistanceValueEquals",
				FolderName = "ResistanceMultipliers",
				ValueObjectName = "ResistanceStatus",
				ExpectedValue = 20,
			},
		},
	},
}

--//======================================================
--// HELPERS
--//======================================================

local function isDead()
	return runtime:IsDead()
end

local function disconnectList(list)
	for _, conn in ipairs(list) do
		pcall(function()
			if conn then
				conn:Disconnect()
			end
		end)
	end
	table.clear(list)
end

local function safeFind(startNode, pathParts)
	local node = startNode
	for _, partName in ipairs(pathParts) do
		if not node then
			return nil
		end
		node = node:FindFirstChild(partName)
	end
	return node
end

local function getSurvivorsFolder()
	return safeFind(Workspace, SURVIVORS_PATH)
end

local function getRootPart(model)
	if not model then
		return nil
	end

	if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then
		return model.PrimaryPart
	end

	local candidates = {"HumanoidRootPart", "Head", "UpperTorso", "Torso"}
	for _, name in ipairs(candidates) do
		local part = model:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return part
		end
	end

	return nil
end

local function getHeadPart(model)
	if not model then
		return nil
	end

	local head = model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head
	end

	return nil
end

local function getHumanoid(model)
	if not model then
		return nil
	end

	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		return hum
	end

	return model:FindFirstChild("Humanoid")
end

local function isModelDead(model)
	local hum = getHumanoid(model)
	if hum and hum.Health <= 0 then
		return true
	end
	return false
end

local function getHumanoidHealth(model)
	local hum = getHumanoid(model)
	if hum then
		return hum.Health
	end
	return nil
end

local function formatCooldownTime(secondsLeft)
	secondsLeft = math.max(0, secondsLeft)
	return string.format("%.1fs", secondsLeft)
end

local function formatSmallCountdown(secondsLeft)
	secondsLeft = math.max(0, secondsLeft)
	return string.format("%.1f", secondsLeft)
end

local function normalizeAnimationId(animationId)
	if not animationId then
		return ""
	end

	animationId = tostring(animationId)
	local digits = string.match(animationId, "(%d+)")
	return digits or animationId
end

local function normalizeAnimationIdList(listOrSingle)
	local out = {}

	if type(listOrSingle) == "table" then
		for _, id in ipairs(listOrSingle) do
			local n = normalizeAnimationId(id)
			if n ~= "" then
				out[n] = true
			end
		end
	elseif listOrSingle ~= nil then
		local n = normalizeAnimationId(listOrSingle)
		if n ~= "" then
			out[n] = true
		end
	end

	return out
end

local function applyFillPalette(boxInfo, topColor, bottomColor)
	if not boxInfo or not boxInfo.FillGradient then
		return
	end

	boxInfo.FillGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, topColor),
		ColorSequenceKeypoint.new(1, bottomColor),
	})
end

local function readResistanceValue(model, folderName, valueObjectName)
	if not model then
		return nil
	end

	local folder = model:FindFirstChild(folderName or RESISTANCE_FOLDER_NAME)
	if not folder then
		return nil
	end

	local valueObj = folder:FindFirstChild(valueObjectName or "ResistanceStatus")
	if not valueObj or not valueObj:IsA("ValueBase") then
		return nil
	end

	return tonumber(valueObj.Value)
end

local function readModelAttributeBool(model, attributeName)
	if not model or not attributeName then
		return false
	end

	return model:GetAttribute(attributeName) == true
end

local function readModelAttributeNumber(model, attributeName)
	if not model or not attributeName then
		return nil
	end

	local n = tonumber(model:GetAttribute(attributeName))
	return n
end

local function getFolderChildCount(model, folderName)
	if not model then
		return 0, nil
	end

	local folder = model:FindFirstChild(folderName or RESISTANCE_FOLDER_NAME)
	if not folder then
		return 0, nil
	end

	return #folder:GetChildren(), folder
end

local function hasNamedChildInFolder(model, folderName, childName)
	if not model or not folderName or not childName then
		return false
	end

	local folder = model:FindFirstChild(folderName)
	if not folder then
		return false
	end

	return folder:FindFirstChild(childName) ~= nil
end

--//======================================================
--// VISUALS
--//======================================================

local function setBoxReady(boxInfo)
	if not boxInfo then
		return
	end

	applyFillPalette(boxInfo, READY_TOP, READY_BOTTOM)
	boxInfo.CooldownCover.Visible = false
	boxInfo.CooldownCover.Size = UDim2.new(1, 0, 0, 0)
	boxInfo.Timer.Text = ""
end

local function playReadyFlash(boxInfo)
	if not boxInfo or not boxInfo.Fill then
		return
	end

	local flash = boxInfo.Fill:FindFirstChild("ReadyFlash")
	if not flash then
		flash = Instance.new("Frame")
		flash.Name = "ReadyFlash"
		flash.Size = UDim2.new(1, 0, 1, 0)
		flash.Position = UDim2.new(0, 0, 0, 0)
		flash.BackgroundColor3 = READY_FLASH_COLOR
		flash.BackgroundTransparency = 1
		flash.BorderSizePixel = 0
		flash.ZIndex = 3
		flash.Parent = boxInfo.Fill

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 3)
		corner.Parent = flash
	end

	flash.BackgroundTransparency = 1

	local t1 = TweenService:Create(
		flash,
		TweenInfo.new(READY_FLASH_TIME_IN, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{BackgroundTransparency = 0.55}
	)

	local t2 = TweenService:Create(
		flash,
		TweenInfo.new(READY_FLASH_TIME_OUT, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{BackgroundTransparency = 1}
	)

	t1:Play()
	t1.Completed:Connect(function()
		pcall(function()
			t2:Play()
		end)
	end)
end

local function setBoxCooldown(boxInfo, progress, remaining)
	if not boxInfo then
		return
	end

	progress = math.clamp(progress, 0, 1)
	remaining = math.max(0, remaining or 0)

	applyFillPalette(boxInfo, COOLDOWN_TOP, COOLDOWN_BOTTOM)

	local coverScale = 1 - progress
	boxInfo.CooldownCover.Visible = coverScale > 0.001
	boxInfo.CooldownCover.Size = UDim2.new(1, 0, coverScale, 0)

	boxInfo.Timer.Text = formatCooldownTime(remaining)
end

local function makeBox(parent, xScale, boxScaleX, moveDef)
	local labelText = moveDef.Label or "Move"

	local outer = Instance.new("Frame")
	outer.Name = labelText:gsub("%s+", "") .. "Box"
	outer.Size = UDim2.new(boxScaleX, 0, 1, 0)
	outer.Position = UDim2.new(xScale, 0, 0, 0)
	outer.BackgroundColor3 = OUTER_BG
	outer.BorderSizePixel = 0
	outer.Parent = parent

	local outerCorner = Instance.new("UICorner")
	outerCorner.CornerRadius = UDim.new(0.06, 0)
	outerCorner.Parent = outer

	local outerStroke = Instance.new("UIStroke")
	outerStroke.Color = OUTER_STROKE
	outerStroke.Thickness = 1.1
	outerStroke.Parent = outer

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(1, 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	fill.BorderSizePixel = 0
	fill.ClipsDescendants = true
	fill.Parent = outer

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0.06, 0)
	fillCorner.Parent = fill

	local fillGradient = Instance.new("UIGradient")
	fillGradient.Name = "FillGradient"
	fillGradient.Rotation = 90
	fillGradient.Parent = fill

	local topHighlight = Instance.new("Frame")
	topHighlight.Name = "TopHighlight"
	topHighlight.Size = UDim2.new(1, 0, 0.03, 0)
	topHighlight.Position = UDim2.new(0, 0, 0, 0)
	topHighlight.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	topHighlight.BackgroundTransparency = 0.86
	topHighlight.BorderSizePixel = 0
	topHighlight.ZIndex = 2
	topHighlight.Parent = fill

	local cooldownCover = Instance.new("Frame")
	cooldownCover.Name = "CooldownCover"
	cooldownCover.AnchorPoint = Vector2.new(0, 1)
	cooldownCover.Position = UDim2.new(0, 0, 1, 0)
	cooldownCover.Size = UDim2.new(1, 0, 0, 0)
	cooldownCover.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	cooldownCover.BackgroundTransparency = COVER_TRANSPARENCY
	cooldownCover.BorderSizePixel = 0
	cooldownCover.Visible = false
	cooldownCover.ZIndex = 3
	cooldownCover.Parent = fill

	local coverGradient = Instance.new("UIGradient")
	coverGradient.Rotation = 90
	coverGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(58, 58, 58)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 0, 0)),
	})
	coverGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.20),
		NumberSequenceKeypoint.new(1, 0.00),
	})
	coverGradient.Parent = cooldownCover

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.new(0.88, 0, 0.34, 0)
	label.Position = UDim2.new(0.06, 0, 0.37, 0)
	label.BackgroundTransparency = 1
	label.Text = labelText
	label.TextColor3 = TEXT_COLOR
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.TextStrokeTransparency = 0.35
	label.TextWrapped = true
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.ZIndex = 4
	label.Parent = outer

	local labelConstraint = Instance.new("UITextSizeConstraint")
	labelConstraint.MinTextSize = 8
	labelConstraint.MaxTextSize = 20
	labelConstraint.Parent = label

	local timer = Instance.new("TextLabel")
	timer.Name = "Timer"
	timer.Size = UDim2.new(0.88, 0, 0.16, 0)
	timer.Position = UDim2.new(0.06, 0, 0.78, 0)
	timer.BackgroundTransparency = 1
	timer.Text = ""
	timer.TextColor3 = TEXT_COLOR
	timer.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	timer.TextStrokeTransparency = 0.40
	timer.TextWrapped = false
	timer.TextScaled = true
	timer.Font = Enum.Font.GothamBold
	timer.TextXAlignment = Enum.TextXAlignment.Center
	timer.TextYAlignment = Enum.TextYAlignment.Center
	timer.ZIndex = 4
	timer.Parent = outer

	local timerConstraint = Instance.new("UITextSizeConstraint")
	timerConstraint.MinTextSize = 7
	timerConstraint.MaxTextSize = 16
	timerConstraint.Parent = timer

	local useCountLabel = nil
	if moveDef.ShowUseCount then
		useCountLabel = Instance.new("TextLabel")
		useCountLabel.Name = "UseCount"
		useCountLabel.Size = UDim2.new(0.26, 0, 0.20, 0)
		useCountLabel.Position = UDim2.new(0.05, 0, 0.04, 0)
		useCountLabel.BackgroundTransparency = 1
		useCountLabel.Text = "0"
		useCountLabel.TextColor3 = TEXT_COLOR
		useCountLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
		useCountLabel.TextStrokeTransparency = 0.30
		useCountLabel.TextScaled = true
		useCountLabel.Font = Enum.Font.GothamBold
		useCountLabel.TextXAlignment = Enum.TextXAlignment.Left
		useCountLabel.TextYAlignment = Enum.TextYAlignment.Top
		useCountLabel.ZIndex = 4
		useCountLabel.Parent = outer

		local countConstraint = Instance.new("UITextSizeConstraint")
		countConstraint.MinTextSize = 7
		countConstraint.MaxTextSize = 16
		countConstraint.Parent = useCountLabel
	end

	local smallCountdown = Instance.new("TextLabel")
	smallCountdown.Name = "SmallCountdown"
	smallCountdown.Size = UDim2.new(0.38, 0, 0.20, 0)
	smallCountdown.Position = UDim2.new(0.05, 0, 0.04, 0)
	smallCountdown.BackgroundTransparency = 1
	smallCountdown.Text = ""
	smallCountdown.TextColor3 = TEXT_COLOR
	smallCountdown.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	smallCountdown.TextStrokeTransparency = 0.30
	smallCountdown.TextScaled = true
	smallCountdown.Font = Enum.Font.GothamBold
	smallCountdown.TextXAlignment = Enum.TextXAlignment.Left
	smallCountdown.TextYAlignment = Enum.TextYAlignment.Top
	smallCountdown.Visible = false
	smallCountdown.ZIndex = 4
	smallCountdown.Parent = outer

	local smallConstraint = Instance.new("UITextSizeConstraint")
	smallConstraint.MinTextSize = 7
	smallConstraint.MaxTextSize = 16
	smallConstraint.Parent = smallCountdown

	local boxInfo = {
		Outer = outer,
		Fill = fill,
		FillGradient = fillGradient,
		CooldownCover = cooldownCover,
		Label = label,
		Timer = timer,
		UseCountLabel = useCountLabel,
		SmallCountdown = smallCountdown,
	}

	setBoxReady(boxInfo)

	return boxInfo
end

--//======================================================
--// TRACKER OBJECT
--//======================================================

local Tracker = {}
Tracker.__index = Tracker

function Tracker.new(config, survivorModel)
	local self = setmetatable({}, Tracker)

	self.Config = config
	self.Survivor = survivorModel
	self.RootPart = nil
	self.Humanoid = nil
	self.Billboard = nil

	self.GlobalConnections = {}
	self.MoveStates = {}
	self.LastMoveTriggeredAt = {}
	self.LastKnownHealth = nil

	for _, moveDef in ipairs(config.Moves) do
		self.MoveStates[moveDef.Label] = {
			Definition = moveDef,
			Box = nil,
			Active = false,
			CooldownEnd = 0,
			UseCount = 0,
			ReadyFlashPlayed = false,
			Hidden = moveDef.StartHidden == true,

			ResistanceLatched = false,
			BoolAttrLatched = false,
			NumberAttrLatched = false,
			GroupWasActive = false,
			SpeedChildLatched = false,

			LastAttributeValue = nil,
			PendingAttributeEvents = {},

			PrepActive = false,
			PrepEnd = 0,
		}
	end

	self:BindToSurvivor(survivorModel)

	return self
end

function Tracker:IsDead()
	return isDead()
end

function Tracker:AddConnection(list, conn)
	table.insert(list, conn)
	return conn
end

function Tracker:DisconnectList(list)
	disconnectList(list)
end

function Tracker:DestroyBillboard()
	if self.Billboard then
		pcall(function()
			self.Billboard:Destroy()
		end)
	end
	self.Billboard = nil
	self.RootPart = nil

	for _, moveState in pairs(self.MoveStates) do
		moveState.Box = nil
	end
end

function Tracker:Destroy()
	self:DisconnectList(self.GlobalConnections)
	self:DestroyBillboard()
	self.Survivor = nil
	self.Humanoid = nil
end

function Tracker:CleanupOnDeath()
	self:DestroyBillboard()
end

function Tracker:GetBillboardName()
	return BILLBOARD_NAME_PREFIX .. tostring(self.Config.Name)
end

function Tracker:CreateBillboard()
	self:DestroyBillboard()

	if not self.Survivor or not self.Survivor.Parent then
		return
	end

	if isModelDead(self.Survivor) then
		return
	end

	local root = getRootPart(self.Survivor)
	if not root then
		return
	end

	self.RootPart = root

	local head = getHeadPart(self.Survivor)
	local adornee = head or root
	if not adornee then
		return
	end

	local billboardName = self:GetBillboardName()
	local existing = self.Survivor:FindFirstChild(billboardName)
	if existing then
		pcall(function()
			existing:Destroy()
		end)
	end

	local moveCount = #self.Config.Moves
	local totalWidthWorld = (BOX_WORLD_SIZE * moveCount) + (BOX_WORLD_GAP * math.max(0, moveCount - 1))
	local rowHeightWorld = BOX_WORLD_SIZE

	local modelHeight = 5
	pcall(function()
		modelHeight = math.max(1, self.Survivor:GetExtentsSize().Y)
	end)

	local topHalfHeight = head and (head.Size.Y * 0.5) or (modelHeight * 0.5)
	local yOffset = topHalfHeight + HEAD_GAP_STUDS + (rowHeightWorld * 0.5)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = billboardName
	billboard.Adornee = adornee
	billboard.Size = UDim2.fromScale(totalWidthWorld, rowHeightWorld)
	billboard.StudsOffset = Vector3.new(0, yOffset, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = MAX_DISTANCE
	billboard.ResetOnSpawn = false
	billboard.Parent = self.Survivor

	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.new(1, 0, 1, 0)
	container.BackgroundTransparency = 1
	container.Parent = billboard

	for index, moveDef in ipairs(self.Config.Moves) do
		local xWorld = (index - 1) * (BOX_WORLD_SIZE + BOX_WORLD_GAP)
		local xScale = totalWidthWorld > 0 and (xWorld / totalWidthWorld) or 0
		local boxScaleX = totalWidthWorld > 0 and (BOX_WORLD_SIZE / totalWidthWorld) or 1
		local boxInfo = makeBox(container, xScale, boxScaleX, moveDef)

		local moveState = self.MoveStates[moveDef.Label]
		moveState.Box = boxInfo

		if moveDef.ShowUseCount and boxInfo.UseCountLabel then
			boxInfo.UseCountLabel.Text = tostring(moveState.UseCount)
		end
	end

	self.Billboard = billboard
end

function Tracker:EnsureBillboard()
	if not self.Survivor or not self.Survivor.Parent then
		return
	end

	if isModelDead(self.Survivor) then
		if self.Billboard then
			self:CleanupOnDeath()
		end
		return
	end

	if not self.Billboard then
		self:CreateBillboard()
	end
end

function Tracker:StartCooldown(moveLabel)
	local moveState = self.MoveStates[moveLabel]
	if not moveState then
		return
	end

	local moveDef = moveState.Definition
	moveState.Active = true
	moveState.CooldownEnd = time() + (moveDef.Cooldown or 0)
	moveState.ReadyFlashPlayed = false
	moveState.PrepActive = false
	moveState.PrepEnd = 0

	if moveDef.ShowUseCount then
		moveState.UseCount += 1
		if moveState.Box and moveState.Box.UseCountLabel then
			moveState.Box.UseCountLabel.Text = tostring(moveState.UseCount)
		end
	end

	self.LastMoveTriggeredAt[moveLabel] = time()
end

function Tracker:StartPrepCountdown(moveLabel, duration)
	local moveState = self.MoveStates[moveLabel]
	if not moveState then
		return
	end

	moveState.PrepActive = true
	moveState.PrepEnd = time() + math.max(0, duration or 0)
end

function Tracker:SetMoveHidden(moveLabel, hidden)
	local moveState = self.MoveStates[moveLabel]
	if not moveState then
		return
	end

	moveState.Hidden = hidden == true

	if moveState.Box and moveState.Box.Outer then
		moveState.Box.Outer.Visible = not moveState.Hidden
	end
end

function Tracker:GetAnimationIdSetForMove(moveDef)
	if moveDef._NormalizedAnimationIds then
		return moveDef._NormalizedAnimationIds
	end

	moveDef._NormalizedAnimationIds = normalizeAnimationIdList(moveDef.AnimationIds or moveDef.AnimationId)
	return moveDef._NormalizedAnimationIds
end

function Tracker:GetPrepAnimationIdSetForMove(moveDef)
	if moveDef._NormalizedPrepAnimationIds then
		return moveDef._NormalizedPrepAnimationIds
	end

	moveDef._NormalizedPrepAnimationIds = normalizeAnimationIdList(moveDef.PrepAnimationIds or moveDef.PrepAnimationId)
	return moveDef._NormalizedPrepAnimationIds
end

function Tracker:HandleAnimationPlayed(animationId)
	for _, moveDef in ipairs(self.Config.Moves) do
		if moveDef.TriggerType == "AnimationPlayed" then
			local animSet = self:GetAnimationIdSetForMove(moveDef)
			if animSet[animationId] then
				self:StartCooldown(moveDef.Label)
			end
		end

		if moveDef.PrepAnimationIds or moveDef.PrepAnimationId then
			local prepSet = self:GetPrepAnimationIdSetForMove(moveDef)
			if prepSet[animationId] then
				self:StartPrepCountdown(moveDef.Label, moveDef.PrepDuration or 0)
			end
		end
	end
end

function Tracker:BindAnimationWatcher()
	if not self.Humanoid then
		return
	end

	self:AddConnection(self.GlobalConnections, self.Humanoid.AnimationPlayed:Connect(function(track)
		if self:IsDead() then
			return
		end

		local animation = track and track.Animation
		local playedId = animation and normalizeAnimationId(animation.AnimationId) or ""
		if playedId == "" then
			return
		end

		self:HandleAnimationPlayed(playedId)
	end))
end

function Tracker:BindDeathCleanup()
	if not self.Humanoid then
		return
	end

	self:AddConnection(self.GlobalConnections, self.Humanoid.Died:Connect(function()
		self:CleanupOnDeath()
	end))

	self:AddConnection(self.GlobalConnections, self.Humanoid:GetPropertyChangedSignal("Health"):Connect(function()
		if self.Humanoid and self.Humanoid.Health <= 0 then
			self:CleanupOnDeath()
		end
	end))
end

function Tracker:BindToSurvivor(survivorModel)
	self.Survivor = survivorModel
	self.Humanoid = getHumanoid(survivorModel)
	self.LastKnownHealth = getHumanoidHealth(survivorModel)

	self:CreateBillboard()

	self:AddConnection(self.GlobalConnections, survivorModel.AncestryChanged:Connect(function(_, parent)
		if self:IsDead() then
			return
		end

		if not parent then
			self:Destroy()
		end
	end))

	if self.Humanoid then
		self:BindDeathCleanup()
		self:BindAnimationWatcher()
	end
end

function Tracker:EvaluateResistanceMoves()
	for _, moveDef in ipairs(self.Config.Moves) do
		if moveDef.TriggerType == "ResistanceValueEquals" then
			local moveState = self.MoveStates[moveDef.Label]
			local currentValue = readResistanceValue(
				self.Survivor,
				moveDef.FolderName or RESISTANCE_FOLDER_NAME,
				moveDef.ValueObjectName or "ResistanceStatus"
			)

			local matched = currentValue ~= nil and currentValue == tonumber(moveDef.ExpectedValue)

			if matched and not moveState.ResistanceLatched then
				self:StartCooldown(moveDef.Label)
				moveState.ResistanceLatched = true
			elseif not matched then
				moveState.ResistanceLatched = false
			end
		end
	end
end

function Tracker:EvaluateAttributeBoolTrueMoves()
	for _, moveDef in ipairs(self.Config.Moves) do
		if moveDef.TriggerType == "AttributeBoolTrue" then
			local moveState = self.MoveStates[moveDef.Label]
			local isTrue = readModelAttributeBool(self.Survivor, moveDef.AttributeName)

			if isTrue and not moveState.BoolAttrLatched then
				self:StartCooldown(moveDef.Label)
				moveState.BoolAttrLatched = true
			elseif not isTrue then
				moveState.BoolAttrLatched = false
			end
		end
	end
end

function Tracker:EvaluateAttributeNumberEqualsMoves()
	for _, moveDef in ipairs(self.Config.Moves) do
		if moveDef.TriggerType == "AttributeNumberEquals" then
			local moveState = self.MoveStates[moveDef.Label]
			local currentValue = readModelAttributeNumber(self.Survivor, moveDef.AttributeName)
			local matched = currentValue ~= nil and currentValue == tonumber(moveDef.ExpectedValue)

			if matched and not moveState.NumberAttrLatched then
				self:StartCooldown(moveDef.Label)
				moveState.NumberAttrLatched = true
			elseif not matched then
				moveState.NumberAttrLatched = false
			end
		end
	end
end

function Tracker:EvaluateAttributeGroupEndMoves()
	for _, moveDef in ipairs(self.Config.Moves) do
		if moveDef.TriggerType == "AttributeGroupEnds" then
			local moveState = self.MoveStates[moveDef.Label]

			local anyTrue = false
			for _, attrName in ipairs(moveDef.AttributeNames or {}) do
				if readModelAttributeBool(self.Survivor, attrName) then
					anyTrue = true
					break
				end
			end

			if anyTrue then
				moveState.GroupWasActive = true
			else
				if moveState.GroupWasActive then
					self:StartCooldown(moveDef.Label)
				end
				moveState.GroupWasActive = false
			end
		end
	end
end

function Tracker:EvaluateAttributeIncreaseMoves()
	for _, moveDef in ipairs(self.Config.Moves) do
		if moveDef.TriggerType == "AttributeIncreaseExcludingMove" then
			local moveState = self.MoveStates[moveDef.Label]
			local currentValue = readModelAttributeNumber(self.Survivor, moveDef.AttributeName)

			if currentValue ~= nil then
				if moveState.LastAttributeValue == nil then
					moveState.LastAttributeValue = currentValue
				elseif currentValue > moveState.LastAttributeValue then
					local delta = currentValue - moveState.LastAttributeValue
					local nowTime = time()

					for _ = 1, delta do
						table.insert(moveState.PendingAttributeEvents, {
							Time = nowTime,
						})
					end

					moveState.LastAttributeValue = currentValue
				elseif currentValue < moveState.LastAttributeValue then
					moveState.LastAttributeValue = currentValue
				end
			end
		end
	end
end

function Tracker:ProcessPendingAttributeIncreaseMoves()
	local nowTime = time()

	for _, moveDef in ipairs(self.Config.Moves) do
		if moveDef.TriggerType == "AttributeIncreaseExcludingMove" then
			local moveState = self.MoveStates[moveDef.Label]
			local pending = moveState.PendingAttributeEvents
			local kept = {}

			for _, eventInfo in ipairs(pending) do
				if nowTime - eventInfo.Time >= ATTRIBUTE_EVENT_DELAY then
					local shouldSuppress = false
					local excludedLabel = moveDef.ExcludedMoveLabel

					if excludedLabel then
						local excludedTime = self.LastMoveTriggeredAt[excludedLabel]
						if excludedTime and math.abs(eventInfo.Time - excludedTime) <= EXCLUDED_MOVE_MATCH_WINDOW then
							shouldSuppress = true
						end
					end

					if not shouldSuppress then
						self:StartCooldown(moveDef.Label)
					end
				else
					table.insert(kept, eventInfo)
				end
			end

			moveState.PendingAttributeEvents = kept
		end
	end
end

function Tracker:EvaluateGuestBlockMoves()
	for _, moveDef in ipairs(self.Config.Moves) do
		if moveDef.TriggerType == "GuestBlockBySpeedMultiplier" then
			local moveState = self.MoveStates[moveDef.Label]

			local folderName = moveDef.FolderName or "SpeedMultipliers"
			local childName = moveDef.ChildName or "GuestBlocking"
			local matched = hasNamedChildInFolder(self.Survivor, folderName, childName)

			if matched and not moveState.SpeedChildLatched then
				self:StartCooldown(moveDef.Label)
				moveState.SpeedChildLatched = true
			elseif not matched then
				moveState.SpeedChildLatched = false
			end
		end
	end
end

function Tracker:EvaluateGuestChargeMoves()
	for _, moveDef in ipairs(self.Config.Moves) do
		if moveDef.TriggerType == "GuestChargeByAbilityIncrease" then
			local moveState = self.MoveStates[moveDef.Label]
			local currentValue = readModelAttributeNumber(self.Survivor, moveDef.AttributeName)

			if currentValue ~= nil then
				if moveState.LastAttributeValue == nil then
					moveState.LastAttributeValue = currentValue
				elseif currentValue > moveState.LastAttributeValue then
					local delta = currentValue - moveState.LastAttributeValue
					local nowTime = time()

					for _ = 1, delta do
						table.insert(moveState.PendingAttributeEvents, {
							Time = nowTime,
						})
					end

					moveState.LastAttributeValue = currentValue
				elseif currentValue < moveState.LastAttributeValue then
					moveState.LastAttributeValue = currentValue
				end
			end
		end
	end
end

function Tracker:ProcessGuestChargeMoves()
	local nowTime = time()

	for _, moveDef in ipairs(self.Config.Moves) do
		if moveDef.TriggerType == "GuestChargeByAbilityIncrease" then
			local moveState = self.MoveStates[moveDef.Label]
			local pending = moveState.PendingAttributeEvents
			local kept = {}

			for _, eventInfo in ipairs(pending) do
				if nowTime - eventInfo.Time >= ATTRIBUTE_EVENT_DELAY then
					local shouldSuppress = false
					local blockLabel = moveDef.BlockMoveLabel
					local blockTime = blockLabel and self.LastMoveTriggeredAt[blockLabel] or nil
					if blockTime and math.abs(eventInfo.Time - blockTime) <= EXCLUDED_MOVE_MATCH_WINDOW then
						shouldSuppress = true
					end

					local blockAttributeName = moveDef.BlockAttributeName
					local blockValue = tonumber(moveDef.BlockValue)
					if blockAttributeName and blockValue ~= nil then
						local currentHitboxPriority = readModelAttributeNumber(self.Survivor, blockAttributeName)
						if currentHitboxPriority ~= nil and currentHitboxPriority == blockValue then
							shouldSuppress = true
						end
					end

					local resistanceAllowed = false
					local childCount = getFolderChildCount(self.Survivor, moveDef.FolderName or RESISTANCE_FOLDER_NAME)
					local resistanceValue = readResistanceValue(
						self.Survivor,
						moveDef.FolderName or RESISTANCE_FOLDER_NAME,
						moveDef.ValueObjectName or "ResistanceStatus"
					)

					if moveDef.AllowedWhenFolderEmpty and childCount == 0 then
						resistanceAllowed = true
					end

					if resistanceValue ~= nil and resistanceValue == tonumber(moveDef.AllowedResistanceValue) then
						resistanceAllowed = true
					end

					if not shouldSuppress and resistanceAllowed then
						self:StartCooldown(moveDef.Label)
					end
				else
					table.insert(kept, eventInfo)
				end
			end

			moveState.PendingAttributeEvents = kept
		end
	end
end

function Tracker:EvaluateGuestPunchMoves()
	local currentHealth = getHumanoidHealth(self.Survivor)

	for _, moveDef in ipairs(self.Config.Moves) do
		if moveDef.TriggerType == "GuestPunchByTimesHitLowDamage" then
			local moveState = self.MoveStates[moveDef.Label]
			local currentValue = readModelAttributeNumber(self.Survivor, moveDef.AttributeName)

			if currentValue ~= nil then
				if moveState.LastAttributeValue == nil then
					moveState.LastAttributeValue = currentValue
				elseif currentValue > moveState.LastAttributeValue then
					local healthLoss = 0
					if self.LastKnownHealth ~= nil and currentHealth ~= nil then
						healthLoss = math.max(0, self.LastKnownHealth - currentHealth)
					end

					if healthLoss < tonumber(moveDef.HealthLossThreshold or 1) then
						self:SetMoveHidden(moveDef.Label, false)
					end

					moveState.LastAttributeValue = currentValue
				elseif currentValue < moveState.LastAttributeValue then
					moveState.LastAttributeValue = currentValue
				end
			end

			local hideWhenValue = tonumber(moveDef.HideWhenValue)
			local resistanceValue = readResistanceValue(
				self.Survivor,
				moveDef.FolderName or RESISTANCE_FOLDER_NAME,
				moveDef.ValueObjectName or "ResistanceStatus"
			)

			if resistanceValue ~= nil and hideWhenValue ~= nil and resistanceValue == hideWhenValue then
				self:SetMoveHidden(moveDef.Label, true)
			end
		end
	end
end

function Tracker:UpdateMoveVisual(moveState)
	if not moveState or not moveState.Box then
		return
	end

	local box = moveState.Box

	if box.Outer then
		box.Outer.Visible = not moveState.Hidden
	end

	if moveState.Hidden then
		return
	end

	if box.SmallCountdown then
		box.SmallCountdown.Visible = false
		box.SmallCountdown.Text = ""
	end

	if moveState.PrepActive then
		local prepRemaining = math.max(0, moveState.PrepEnd - time())

		if box.SmallCountdown then
			box.SmallCountdown.Visible = true
			box.SmallCountdown.Text = formatSmallCountdown(prepRemaining)
		end

		if prepRemaining <= 0 then
			moveState.PrepActive = false
			moveState.PrepEnd = 0

			if box.SmallCountdown then
				box.SmallCountdown.Visible = false
				box.SmallCountdown.Text = ""
			end
		end
	end

	if not moveState.Active then
		setBoxReady(box)

		if moveState.Definition.ShowUseCount and box.UseCountLabel then
			box.UseCountLabel.Text = tostring(moveState.UseCount)
		end

		if moveState.PrepActive and box.SmallCountdown then
			box.SmallCountdown.Visible = true
		end

		return
	end

	local cooldown = moveState.Definition.Cooldown or 0
	local remaining = math.max(0, moveState.CooldownEnd - time())
	local elapsed = cooldown - remaining
	local progress = (cooldown > 0) and (elapsed / cooldown) or 1

	setBoxCooldown(box, progress, remaining)

	if moveState.Definition.ShowUseCount and box.UseCountLabel then
		box.UseCountLabel.Text = tostring(moveState.UseCount)
	end

	if remaining <= 0 then
		moveState.Active = false
		setBoxReady(box)

		if not moveState.ReadyFlashPlayed then
			moveState.ReadyFlashPlayed = true
			playReadyFlash(box)
		end

		if moveState.Definition.ShowUseCount and box.UseCountLabel then
			box.UseCountLabel.Text = tostring(moveState.UseCount)
		end
	end

	if moveState.PrepActive and box.SmallCountdown then
		box.SmallCountdown.Visible = true
	end
end

function Tracker:Update()
	if self:IsDead() then
		return
	end

	if not self.Survivor or not self.Survivor.Parent then
		self:Destroy()
		return
	end

	if isModelDead(self.Survivor) then
		if self.Billboard then
			self:CleanupOnDeath()
		end
		return
	end

	self:EnsureBillboard()

	self:EvaluateResistanceMoves()
	self:EvaluateAttributeBoolTrueMoves()
	self:EvaluateAttributeNumberEqualsMoves()
	self:EvaluateAttributeGroupEndMoves()
	self:EvaluateAttributeIncreaseMoves()
	self:ProcessPendingAttributeIncreaseMoves()
	self:EvaluateGuestBlockMoves()
	self:EvaluateGuestChargeMoves()
	self:ProcessGuestChargeMoves()
	self:EvaluateGuestPunchMoves()

	for _, moveState in pairs(self.MoveStates) do
		self:UpdateMoveVisual(moveState)
	end

	self.LastKnownHealth = getHumanoidHealth(self.Survivor)
end

--//======================================================
--// BINDING / SCAN
--//======================================================

local function ensureTrackerForSurvivor(survivorModel)
	if isDead() or not survivorModel then
		return
	end

	local config = SURVIVOR_CONFIGS[survivorModel.Name]
	if not config then
		return
	end

	local existing = runtime.Trackers[survivorModel]
	if existing then
		return
	end

	runtime.Trackers[survivorModel] = Tracker.new(config, survivorModel)
end

local function removeDeadTrackers()
	for survivorModel, tracker in pairs(runtime.Trackers) do
		if not tracker or not survivorModel or not survivorModel.Parent then
			if tracker and tracker.Destroy then
				pcall(function()
					tracker:Destroy()
				end)
			end
			runtime.Trackers[survivorModel] = nil
		end
	end
end

local function bindExistingSurvivors()
	local survivorsFolder = getSurvivorsFolder()
	if not survivorsFolder then
		return
	end

	for _, child in ipairs(survivorsFolder:GetChildren()) do
		if SURVIVOR_CONFIGS[child.Name] then
			ensureTrackerForSurvivor(child)
		end
	end
end

bindExistingSurvivors()

runtime:AddGlobalConnection(Workspace.DescendantAdded:Connect(function(descendant)
	if isDead() then
		return
	end

	local survivorsFolder = getSurvivorsFolder()
	if not survivorsFolder then
		return
	end

	if SURVIVOR_CONFIGS[descendant.Name] and descendant.Parent == survivorsFolder then
		ensureTrackerForSurvivor(descendant)
	end
end))

runtime:AddGlobalConnection(RunService.RenderStepped:Connect(function()
	if isDead() then
		return
	end

	bindExistingSurvivors()

	for survivorModel, tracker in pairs(runtime.Trackers) do
		if not tracker or not survivorModel or not survivorModel.Parent then
			if tracker and tracker.Destroy then
				pcall(function()
					tracker:Destroy()
				end)
			end
			runtime.Trackers[survivorModel] = nil
		else
			tracker:Update()
		end
	end

	removeDeadTrackers()
end))
