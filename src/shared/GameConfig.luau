--!strict
-- Shared battlefield constants and layout helpers.
--
-- Layout: trenches are parallel strips running along the Z-axis and are spread
-- out along the X-axis. Allies are on the far left (-X), Enemies on the far
-- right (+X). The battlefield is centred on the world origin.

local GameConfig = {}

export type Owner = "Neutral" | "Allies" | "Enemies"

-- Trench grid
GameConfig.TRENCH_COUNT = 5
GameConfig.TRENCH_SPACING = 54 -- studs between trench centres (X-axis)
GameConfig.TRENCH_LENGTH = 48 -- studs (Z-axis)
GameConfig.SLOTS_PER_TRENCH = 10

-- Trench shape. Trenches and (later) units are miniatures: players stay
-- normal-sized and tower over the battlefield like a tabletop diorama.
GameConfig.MINIATURE_SCALE = 1 / 3 -- size of units relative to a player character
GameConfig.TRENCH_WIDTH = 2 -- studs (X-axis)
GameConfig.TRENCH_DEPTH = 1 -- how far the floor sits below ground level
GameConfig.SANDBAG_HEIGHT = 0.5
GameConfig.SANDBAG_THICKNESS = 0.6

-- Battlefield
GameConfig.GROUND_Y = 0 -- Y of the walkable ground surface
GameConfig.SPAWN_ZONE_WIDTH = 24 -- X-depth of each team's spawn zone
GameConfig.MAP_MARGIN_Z = 12 -- ground beyond each trench end

GameConfig.TRENCH_FLOOR_Y = GameConfig.GROUND_Y - GameConfig.TRENCH_DEPTH

-- Outer trenches sit one TRENCH_SPACING away from their spawn zone.
GameConfig.MAP_SIZE_X = (GameConfig.TRENCH_COUNT + 1) * GameConfig.TRENCH_SPACING
	+ 2 * GameConfig.SPAWN_ZONE_WIDTH
GameConfig.MAP_SIZE_Z = GameConfig.TRENCH_LENGTH + 2 * GameConfig.MAP_MARGIN_Z

-- World X of a trench's centre line. Trench 1 is nearest the Allies (-X).
function GameConfig.GetTrenchCenterX(trenchIndex: number): number
	assert(
		trenchIndex >= 1 and trenchIndex <= GameConfig.TRENCH_COUNT and trenchIndex % 1 == 0,
		`trenchIndex must be an integer in 1..{GameConfig.TRENCH_COUNT}, got {trenchIndex}`
	)
	return (trenchIndex - (GameConfig.TRENCH_COUNT + 1) / 2) * GameConfig.TRENCH_SPACING
end

-- World position of a troop slot, on the trench floor surface. Slots are evenly
-- distributed along the trench's length (Z-axis); slot 1 is at the -Z end.
function GameConfig.GetSlotWorldPosition(trenchIndex: number, slotIndex: number): Vector3
	assert(
		slotIndex >= 1 and slotIndex <= GameConfig.SLOTS_PER_TRENCH and slotIndex % 1 == 0,
		`slotIndex must be an integer in 1..{GameConfig.SLOTS_PER_TRENCH}, got {slotIndex}`
	)
	local slotLength = GameConfig.TRENCH_LENGTH / GameConfig.SLOTS_PER_TRENCH
	local z = -GameConfig.TRENCH_LENGTH / 2 + (slotIndex - 0.5) * slotLength
	return Vector3.new(GameConfig.GetTrenchCenterX(trenchIndex), GameConfig.TRENCH_FLOOR_Y, z)
end

-- Starting ownership: each side holds the trench nearest its spawn zone.
function GameConfig.GetInitialOwner(trenchIndex: number): Owner
	if trenchIndex == 1 then
		return "Allies"
	elseif trenchIndex == GameConfig.TRENCH_COUNT then
		return "Enemies"
	end
	return "Neutral"
end

-- Units ------------------------------------------------------------------

export type Team = "Allies" | "Enemies"

GameConfig.UNIT_WALK_SPEED = 8 -- studs per second
GameConfig.DEPLOY_COOLDOWN = 0.5 -- seconds between deploys, per player
GameConfig.ENEMY_SPAWN_INTERVAL = 4 -- seconds between enemy garrison spawns
GameConfig.ENEMY_MAX_UNITS = 6 -- enemy garrison size (no enemy AI yet)

-- Names of the RemoteEvents the server creates in ReplicatedStorage.Remotes.
GameConfig.REMOTES_FOLDER = "Remotes"
GameConfig.REMOTE_DEPLOY_UNIT = "DeployUnit"
GameConfig.REMOTE_ADVANCE_TRENCH = "AdvanceTrench"

-- The trench nearest a team's spawn zone, where its units deploy to.
function GameConfig.GetHomeTrenchIndex(team: Team): number
	return if team == "Allies" then 1 else GameConfig.TRENCH_COUNT
end

-- Trench-index step a team takes when advancing toward the other side.
function GameConfig.GetAdvanceDirection(team: Team): number
	return if team == "Allies" then 1 else -1
end

-- World X of the centre of a team's spawn zone.
function GameConfig.GetSpawnZoneCenterX(owner: "Allies" | "Enemies"): number
	local x = (GameConfig.MAP_SIZE_X - GameConfig.SPAWN_ZONE_WIDTH) / 2
	return if owner == "Allies" then -x else x
end

return GameConfig
