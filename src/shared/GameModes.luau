--!strict
-- Game modes offered in the lobby, and the Roblox places they run in.
--
-- The experience is split into two places built from this repo:
--   lobby.project.json   -> the lobby (must be the experience's start place)
--   default.project.json -> the Trench Warfare battle place
--
-- After publishing a place, put its Place ID here. A PlaceId of 0 means "not
-- published yet": the lobby lists the mode but refuses to teleport to it.

local GameModes = {}

export type GameMode = {
	DisplayName: string,
	Description: string,
	SortOrder: number, -- order of the buttons in the lobby menu
	PlaceId: number, -- place the mode runs in; 0 = not published yet
}

local Modes: { [string]: GameMode } = {
	TrenchWarfare = {
		DisplayName = "Trench Warfare",
		Description = "Command your troops from trench to trench against the enemy line.",
		SortOrder = 1,
		PlaceId = 0, -- TODO: Place ID of the published battle place (default.project.json)
	},

	-- Add further modes here; each needs its own published place.
}
GameModes.Modes = Modes

-- Place ID of the published lobby place (lobby.project.json), for the battle
-- place's Return to Lobby button. 0 = not published yet.
GameModes.LOBBY_PLACE_ID = 0 -- TODO: Place ID of the published lobby place

-- RemoteFunction a battle place's server creates in ReplicatedStorage.
-- Client invokes with no arguments; server returns (accepted: boolean, message: string).
GameModes.REMOTE_RETURN_TO_LOBBY = "ReturnToLobby"

-- RemoteFunction the lobby server creates in ReplicatedStorage.
-- Client invokes with (modeId: string); server returns (accepted: boolean, message: string).
GameModes.REMOTE_REQUEST_MODE = "RequestGameMode"

-- Mode ids in SortOrder.
function GameModes.GetSortedModeIds(): { string }
	local ids: { string } = {}
	for id in Modes do
		table.insert(ids, id)
	end
	table.sort(ids, function(a: string, b: string)
		local orderA, orderB = Modes[a].SortOrder, Modes[b].SortOrder
		if orderA ~= orderB then
			return orderA < orderB
		end
		return a < b
	end)
	return ids
end

-- Whether a mode has a published place to teleport to.
function GameModes.IsAvailable(modeId: string): boolean
	local mode = Modes[modeId]
	return mode ~= nil and mode.PlaceId ~= 0
end

return GameModes
