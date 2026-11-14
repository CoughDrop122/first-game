--!strict
-- Victory / defeat screen. Appears when the server marks the match as ended
-- (MatchPhase / Winner attributes on ReplicatedStorage.TeamState) and offers
-- Play Again and Return to Lobby.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local GameModes = require(Shared:WaitForChild("GameModes"))

-- All players command the Allies for now.
local TEAM: GameConfig.Team = "Allies"

local player = Players.LocalPlayer :: Player
local playerGui = player:WaitForChild("PlayerGui")

local teamState = ReplicatedStorage:WaitForChild(GameConfig.TEAM_STATE_FOLDER)
local remotes = ReplicatedStorage:WaitForChild(GameConfig.REMOTES_FOLDER)
local restartRemote = remotes:WaitForChild(GameConfig.REMOTE_RESTART_MATCH) :: RemoteEvent
local returnRemote = ReplicatedStorage:WaitForChild(GameModes.REMOTE_RETURN_TO_LOBBY) :: RemoteFunction

-- UI --------------------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "MatchResultGui"
screenGui.ResetOnSpawn = false
screenGui.DisplayOrder = 10 -- above the command bar
screenGui.Enabled = false

local panel = Instance.new("Frame")
panel.Name = "ResultPanel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.45)
panel.Size = UDim2.fromScale(0.4, 0.4)
panel.Parent = screenGui

local title = Instance.new("TextLabel")
title.Name = "Title"
title.AnchorPoint = Vector2.new(0.5, 0)
title.Position = UDim2.fromScale(0.5, 0.05)
title.Size = UDim2.fromScale(0.9, 0.25)
title.BackgroundTransparency = 1
title.TextScaled = true
title.Parent = panel

local subtitle = Instance.new("TextLabel")
subtitle.Name = "Subtitle"
subtitle.AnchorPoint = Vector2.new(0.5, 0)
subtitle.Position = UDim2.fromScale(0.5, 0.32)
subtitle.Size = UDim2.fromScale(0.9, 0.14)
subtitle.BackgroundTransparency = 1
subtitle.TextScaled = true
subtitle.Parent = panel

local playAgainButton = Instance.new("TextButton")
playAgainButton.Name = "PlayAgainButton"
playAgainButton.AnchorPoint = Vector2.new(0.5, 0)
playAgainButton.Position = UDim2.fromScale(0.27, 0.55)
playAgainButton.Size = UDim2.fromScale(0.42, 0.2)
playAgainButton.TextScaled = true
playAgainButton.Text = "Play Again"
playAgainButton.Parent = panel

local lobbyButton = Instance.new("TextButton")
lobbyButton.Name = "ReturnToLobbyButton"
lobbyButton.AnchorPoint = Vector2.new(0.5, 0)
lobbyButton.Position = UDim2.fromScale(0.73, 0.55)
lobbyButton.Size = UDim2.fromScale(0.42, 0.2)
lobbyButton.TextScaled = true
lobbyButton.Text = "Return to Lobby"
lobbyButton.Parent = panel

local status = Instance.new("TextLabel")
status.Name = "Status"
status.AnchorPoint = Vector2.new(0.5, 1)
status.Position = UDim2.fromScale(0.5, 0.97)
status.Size = UDim2.fromScale(0.9, 0.14)
status.BackgroundTransparency = 1
status.TextScaled = true
status.Text = ""
status.Parent = panel

screenGui.Parent = playerGui

-- State -------------------------------------------------------------------------

local function refresh()
	local ended = teamState:GetAttribute("MatchPhase") == GameConfig.MATCH_PHASE_ENDED
	if not ended then
		screenGui.Enabled = false
		status.Text = ""
		return
	end

	local won = teamState:GetAttribute("Winner") == TEAM
	title.Text = if won then "Victory!" else "Defeat"
	subtitle.Text = if won
		then "You took the enemy's home trench."
		else "The enemy took your home trench."
	screenGui.Enabled = true
end

teamState:GetAttributeChangedSignal("MatchPhase"):Connect(refresh)
teamState:GetAttributeChangedSignal("Winner"):Connect(refresh)
refresh()

-- Buttons -----------------------------------------------------------------------

-- The server ignores restart requests for a few seconds after the match ends,
-- so a click that lands too early simply does nothing; the screen closes when
-- the server actually restarts.
playAgainButton.Activated:Connect(function()
	restartRemote:FireServer()
end)

local returning = false
lobbyButton.Activated:Connect(function()
	if returning then
		return
	end
	returning = true
	status.Text = "Returning to the lobby..."

	local ok, accepted, message = pcall(function()
		return returnRemote:InvokeServer()
	end)
	if ok and typeof(message) == "string" then
		status.Text = message
	else
		status.Text = "Couldn't reach the server. Please try again."
	end

	-- On success the teleport takes over; otherwise let the player try again.
	if not (ok and accepted == true) then
		returning = false
	end
end)
