--!strict
-- Teleports a player back to the lobby place on request (see Shared.GameModes).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")

local GameModes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameModes"))

-- Players with a teleport in flight, so repeated clicks don't stack requests.
local teleporting: { [Player]: boolean } = {}

local returnRemote = Instance.new("RemoteFunction")
returnRemote.Name = GameModes.REMOTE_RETURN_TO_LOBBY

-- Returns (accepted, message). `accepted` means the teleport was started.
returnRemote.OnServerInvoke = function(player: Player): (boolean, string)
	if GameModes.LOBBY_PLACE_ID == 0 then
		return false, "The lobby isn't published yet (no LOBBY_PLACE_ID set in GameModes)."
	end
	if teleporting[player] then
		return false, "Already returning to the lobby..."
	end

	teleporting[player] = true
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(GameModes.LOBBY_PLACE_ID, { player })
	end)
	if not ok then
		teleporting[player] = nil
		warn(`Teleport to lobby failed for {player.Name}: {err}`)
		return false, "Couldn't return to the lobby. Please try again."
	end
	return true, "Returning to the lobby..."
end

-- A teleport that was accepted can still fail afterwards; let the player retry.
TeleportService.TeleportInitFailed:Connect(function(player: Player)
	teleporting[player] = nil
end)

Players.PlayerRemoving:Connect(function(player: Player)
	teleporting[player] = nil
end)

returnRemote.Parent = ReplicatedStorage
