--!strict
-- Milestone 2 command bar: a Deploy button plus one Advance button per trench.
-- Button state is driven by the AlliesCount / EnemiesCount attributes the
-- server keeps on each trench Model.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

local DEPLOY_ACTION = "DeployUnit"

local player = Players.LocalPlayer :: Player
local playerGui = player:WaitForChild("PlayerGui")

local remotes = ReplicatedStorage:WaitForChild(GameConfig.REMOTES_FOLDER)
local deployRemote = remotes:WaitForChild(GameConfig.REMOTE_DEPLOY_UNIT) :: RemoteEvent
local advanceRemote = remotes:WaitForChild(GameConfig.REMOTE_ADVANCE_TRENCH) :: RemoteEvent

local trenchesFolder = Workspace:WaitForChild("Trenches")
local trenchModels: { Instance } = {}
for trenchIndex = 1, GameConfig.TRENCH_COUNT do
	trenchModels[trenchIndex] = trenchesFolder:WaitForChild(`Trench_{trenchIndex}`)
end

local function getCount(trenchIndex: number, attribute: string): number
	local value = trenchModels[trenchIndex]:GetAttribute(attribute)
	return if typeof(value) == "number" then value else 0
end

-- UI --------------------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "UnitCommandGui"
screenGui.ResetOnSpawn = false

local bar = Instance.new("Frame")
bar.Name = "CommandBar"
bar.AnchorPoint = Vector2.new(0.5, 1)
bar.Position = UDim2.fromScale(0.5, 0.97)
bar.Size = UDim2.fromScale(0.8, 0.07)
bar.BackgroundTransparency = 1
bar.Parent = screenGui

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Horizontal
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0.01, 0)
layout.Parent = bar

local function makeButton(name: string, layoutOrder: number): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.LayoutOrder = layoutOrder
	button.Size = UDim2.fromScale(0.19, 1)
	button.TextScaled = true
	button.Parent = bar
	return button
end

local function setEnabled(button: TextButton, enabled: boolean)
	button.Active = enabled
	button.AutoButtonColor = enabled
	button.TextTransparency = if enabled then 0 else 0.6
end

local homeTrench = GameConfig.GetHomeTrenchIndex("Allies")
local deployButton = makeButton("DeployButton", 0)

-- One Advance button per trench that has a trench ahead of it.
local advanceButtons: { [number]: TextButton } = {}
for trenchIndex = 1, GameConfig.TRENCH_COUNT - 1 do
	advanceButtons[trenchIndex] = makeButton(`AdvanceButton_{trenchIndex}`, trenchIndex)
end

local function refresh()
	local homeCount = getCount(homeTrench, "AlliesCount")
	local homeFull = homeCount >= GameConfig.SLOTS_PER_TRENCH
	deployButton.Text = if homeFull then "Trench 1 Full" else "Deploy Rifleman"
	setEnabled(deployButton, not homeFull)

	for trenchIndex, button in advanceButtons do
		local count = getCount(trenchIndex, "AlliesCount")
		local blocked = getCount(trenchIndex + 1, "EnemiesCount") > 0
		button.Text = if blocked
			then `Trench {trenchIndex + 1} Held`
			else `Advance {trenchIndex} > {trenchIndex + 1} ({count})`
		setEnabled(button, count > 0 and not blocked)
	end
end

-- Orders ------------------------------------------------------------------------

local function requestDeploy()
	if deployButton.Active then
		deployRemote:FireServer()
	end
end

deployButton.Activated:Connect(requestDeploy)

for trenchIndex, button in advanceButtons do
	button.Activated:Connect(function()
		if button.Active then
			advanceRemote:FireServer(trenchIndex)
		end
	end)
end

ContextActionService:BindAction(DEPLOY_ACTION, function(_actionName: string, inputState: Enum.UserInputState)
	if inputState == Enum.UserInputState.Begin then
		requestDeploy()
	end
	return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.E, Enum.KeyCode.ButtonX)

for _, trench in trenchModels do
	trench:GetAttributeChangedSignal("AlliesCount"):Connect(refresh)
	trench:GetAttributeChangedSignal("EnemiesCount"):Connect(refresh)
end

refresh()
screenGui.Parent = playerGui
