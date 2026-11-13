--!strict
-- Handles game mode requests from the lobby menu: validates the mode and
-- teleports the player to the place it runs in (see Shared.GameModes).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")

local GameModes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameModes"))

-- Players with a teleport in flight, so repeated clicks don't stack requests.
local teleporting: { [Player]: boolean } = {}

local requestRemote = Instance.new("RemoteFunction")
requestRemote.Name = GameModes.REMOTE_REQUEST_MODE

-- Returns (accepted, message). `accepted` means the teleport was started; the
-- player leaves this server shortly after.
requestRemote.OnServerInvoke = function(player: Player, modeId: unknown): (boolean, string)
	if typeof(modeId) ~= "string" then
		return false, "Unknown game mode."
	end
	local mode = GameModes.Modes[modeId]
	if not mode then
		return false, "Unknown game mode."
	end
	if not GameModes.IsAvailable(modeId) then
		return false, `{mode.DisplayName} isn't published yet (no Place ID set in GameModes).`
	end
	if teleporting[player] then
		return false, "Already joining a game..."
	end

	teleporting[player] = true
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(mode.PlaceId, { player })
	end)
	if not ok then
		teleporting[player] = nil
		warn(`Teleport to {modeId} failed for {player.Name}: {err}`)
		return false, "Couldn't join the game. Please try again."
	end
	return true, `Joining {mode.DisplayName}...`
end

-- A teleport that was accepted can still fail afterwards; let the player retry.
TeleportService.TeleportInitFailed:Connect(function(player: Player)
	teleporting[player] = nil
end)

Players.PlayerRemoving:Connect(function(player: Player)
	teleporting[player] = nil
end)

requestRemote.Parent = ReplicatedStorage
