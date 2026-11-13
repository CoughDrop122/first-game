--!strict
-- Lobby menu: one button per game mode in Shared.GameModes. Choosing a mode
-- asks the server to send the player to that mode's place.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameModes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameModes"))

local MAX_BUTTON_HEIGHT = 0.3 -- of the list area

local player = Players.LocalPlayer :: Player
local playerGui = player:WaitForChild("PlayerGui")

local requestRemote = ReplicatedStorage:WaitForChild(GameModes.REMOTE_REQUEST_MODE) :: RemoteFunction

local modeIds = GameModes.GetSortedModeIds()

-- UI --------------------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "ModeSelectGui"
screenGui.ResetOnSpawn = false

local panel = Instance.new("Frame")
panel.Name = "ModeSelectPanel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.fromScale(0.4, 0.6)
panel.Parent = screenGui

local title = Instance.new("TextLabel")
title.Name = "Title"
title.AnchorPoint = Vector2.new(0.5, 0)
title.Position = UDim2.fromScale(0.5, 0.03)
title.Size = UDim2.fromScale(0.9, 0.12)
title.BackgroundTransparency = 1
title.TextScaled = true
title.Text = "Choose a game mode"
title.Parent = panel

local list = Instance.new("Frame")
list.Name = "ModeList"
list.AnchorPoint = Vector2.new(0.5, 0)
list.Position = UDim2.fromScale(0.5, 0.18)
list.Size = UDim2.fromScale(0.9, 0.64)
list.BackgroundTransparency = 1
list.Parent = panel

local listLayout = Instance.new("UIListLayout")
listLayout.FillDirection = Enum.FillDirection.Vertical
listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Padding = UDim.new(0.03, 0)
listLayout.Parent = list

local status = Instance.new("TextLabel")
status.Name = "Status"
status.AnchorPoint = Vector2.new(0.5, 1)
status.Position = UDim2.fromScale(0.5, 0.97)
status.Size = UDim2.fromScale(0.9, 0.1)
status.BackgroundTransparency = 1
status.TextScaled = true
status.Text = ""
status.Parent = panel

-- Mode buttons ------------------------------------------------------------------

local buttons: { TextButton } = {}
local requestInFlight = false

local function setButtonsEnabled(enabled: boolean)
	for _, button in buttons do
		button.Active = enabled
		button.AutoButtonColor = enabled
		button.TextTransparency = if enabled then 0 else 0.6
	end
end

local function requestMode(modeId: string)
	if requestInFlight then
		return
	end
	requestInFlight = true
	setButtonsEnabled(false)
	status.Text = "Joining..."

	local ok, accepted, message = pcall(function()
		return requestRemote:InvokeServer(modeId)
	end)
	if ok and typeof(message) == "string" then
		status.Text = message
	else
		status.Text = "Couldn't reach the server. Please try again."
	end

	-- On success the teleport takes over; otherwise let the player pick again.
	if not (ok and accepted == true) then
		requestInFlight = false
		setButtonsEnabled(true)
	end
end

local buttonHeight = math.min(MAX_BUTTON_HEIGHT, 1 / math.max(#modeIds, 1) - 0.03)
for order, modeId in modeIds do
	local mode = GameModes.Modes[modeId]

	local button = Instance.new("TextButton")
	button.Name = `Mode_{modeId}`
	button.LayoutOrder = order
	button.Size = UDim2.fromScale(1, buttonHeight)
	button.TextScaled = true
	button.Text = `{mode.DisplayName}\n{mode.Description}`
	button.Parent = list
	table.insert(buttons, button)

	button.Activated:Connect(function()
		requestMode(modeId)
	end)
end

screenGui.Parent = playerGui
