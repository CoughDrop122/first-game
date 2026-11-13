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

-- Teams & economy ---------------------------------------------------------

export type Team = "Allies" | "Enemies"

-- What unlock rules are evaluated against. The server builds it from Economy;
-- the client builds it from the attributes on ReplicatedStorage.TeamState
-- (`{team}TrenchesOwned`, `{team}CommandTier`).
export type TeamState = {
	TrenchesOwned: number,
	CommandTier: number,
}

GameConfig.DEPLOY_COOLDOWN = 0.5 -- seconds between deploys, per player

-- Both teams earn and spend Supplies under the same rules.
GameConfig.STARTING_SUPPLIES = 150
GameConfig.BASE_INCOME = 3 -- supplies per second
GameConfig.INCOME_PER_TRENCH = 2 -- extra supplies per second per owned trench
GameConfig.KILL_BOUNTY = 5 -- supplies awarded to the team that kills a unit
GameConfig.STARTING_COMMAND_TIER = 1 -- nothing raises this yet; here for CommandTier unlocks
-- Folder in ReplicatedStorage whose attributes hold each team's state.
GameConfig.TEAM_STATE_FOLDER = "TeamState"

-- Combat rules shared by every unit ----------------------------------------

-- Hit-chance multiplier against a target settled in a trench, unless the
-- shooter is in that same trench or its unit type has IgnoresCover.
GameConfig.TRENCH_COVER_MULTIPLIER = 0.35
-- Width (studs, along X) of the buckets the server sorts units into so a unit
-- looking for a target only checks enemies near it.
GameConfig.TARGET_BUCKET_SIZE = 20

-- Unit registry --------------------------------------------------------------
--
-- Every deployable unit is one entry in GameConfig.Units, keyed by unitType.
-- UnitManager and the command bar read everything from here, so adding a unit
-- that only uses the fields below needs no code changes.

export type UnlockRule = {
	Type: string, -- "Default" | "CommandTier" | "TrenchesOwned"
	Tier: number?, -- CommandTier: minimum command tier
	Count: number?, -- TrenchesOwned: minimum trenches owned
}

-- How the procedural soldier model is dressed. Sizes are in full-size
-- character studs; the generator multiplies them by MINIATURE_SCALE.
export type UnitVisual = {
	BodyScale: number, -- 1 = standard soldier
	Hat: string, -- "Helmet" | "PeakedCap" | "None"
	HatColor: Color3,
	WeaponSize: Vector3, -- X, Y = thickness, Z = length
	WeaponColor: Color3,
	AccentColor: Color3?, -- band across the torso, if any
}

export type UnitAura = {
	FireRateMultiplier: number,
	AccuracyMultiplier: number,
}

export type UnitAbilities = {
	-- Buffs every friendly unit settled in the same trench (not stacking).
	Aura: UnitAura?,
	-- While settled in a trench, lets the player order a Charge from it.
	CanOrderCharge: boolean?,
	-- While settled in a trench, lets the player build fortifications there.
	CanBuildFortifications: boolean?,
}

export type UnitDefinition = {
	DisplayName: string,
	SortOrder: number, -- order of the deploy buttons
	Cost: number, -- supplies
	MaxHP: number,
	MoveSpeed: number, -- studs per second
	Range: number, -- studs
	FireRate: number, -- shots per second
	Damage: number, -- per hit
	Accuracy: number, -- hit chance against a target in the open, 0..1
	ArmorType: string, -- e.g. "Infantry", "Vehicle"
	DamageVsArmor: { [string]: number }?, -- damage multiplier by target ArmorType (default 1)
	IgnoresCover: boolean, -- shots ignore trench cover
	SplashRadius: number, -- studs; 0 = single target. Hits also damage enemies this close to the target
	OccupiesTrenchSlot: boolean, -- false = never takes a slot; holds position just outside its trench
	Abilities: UnitAbilities?,
	Visual: UnitVisual,
	Unlock: UnlockRule,
}

local Units: { [string]: UnitDefinition } = {
	Rifleman = {
		DisplayName = "Rifleman",
		SortOrder = 1,
		Cost = 50,
		MaxHP = 100,
		MoveSpeed = 8,
		Range = 40, -- less than TRENCH_SPACING, so neighbouring trenches can't trade fire
		FireRate = 0.83,
		Damage = 25,
		Accuracy = 0.6,
		ArmorType = "Infantry",
		IgnoresCover = false,
		SplashRadius = 0,
		OccupiesTrenchSlot = true,
		Visual = {
			BodyScale = 1,
			Hat = "Helmet",
			HatColor = Color3.fromRGB(88, 96, 72),
			WeaponSize = Vector3.new(0.25, 0.25, 2.6),
			WeaponColor = Color3.fromRGB(60, 42, 28),
		},
		Unlock = { Type = "Default" },
	},

	Officer = {
		DisplayName = "Officer",
		SortOrder = 2,
		Cost = 120,
		MaxHP = 160,
		MoveSpeed = 8,
		Range = 22, -- pistol
		FireRate = 1.6,
		Damage = 14,
		Accuracy = 0.55,
		ArmorType = "Infantry",
		IgnoresCover = false,
		SplashRadius = 0,
		OccupiesTrenchSlot = true,
		Abilities = {
			Aura = { FireRateMultiplier = 1.05, AccuracyMultiplier = 1.1 },
			CanOrderCharge = true,
			CanBuildFortifications = true,
		},
		Visual = {
			BodyScale = 1.12,
			Hat = "PeakedCap",
			HatColor = Color3.fromRGB(36, 36, 44),
			WeaponSize = Vector3.new(0.3, 0.3, 0.9),
			WeaponColor = Color3.fromRGB(40, 40, 40),
			AccentColor = Color3.fromRGB(230, 190, 70),
		},
		Unlock = { Type = "TrenchesOwned", Count = 2 },
	},

	-- Future units: add an entry like the sketches below. Fields shown are the
	-- ones that differ from a Rifleman; every field in UnitDefinition is required.
	--
	-- MachineGunner = { Cost = 150, MaxHP = 110, Range = 44, FireRate = 5, Damage = 9, Accuracy = 0.35,
	--     Unlock = { Type = "TrenchesOwned", Count = 2 }, ... },
	-- Sniper        = { Cost = 140, MaxHP = 70, Range = 70, FireRate = 0.3, Damage = 90, Accuracy = 0.9,
	--     IgnoresCover = true, Unlock = { Type = "CommandTier", Tier = 2 }, ... },
	-- Grenadier     = { Cost = 110, Range = 26, FireRate = 0.4, Damage = 40, SplashRadius = 5,
	--     IgnoresCover = true, Unlock = { Type = "TrenchesOwned", Count = 3 }, ... },
	-- Mortar        = { Cost = 220, Range = 110, FireRate = 0.2, Damage = 55, SplashRadius = 8,
	--     IgnoresCover = true, Unlock = { Type = "CommandTier", Tier = 2 }, ... },
	-- Tank          = { Cost = 500, MaxHP = 900, MoveSpeed = 5, ArmorType = "Vehicle",
	--     OccupiesTrenchSlot = false, Unlock = { Type = "CommandTier", Tier = 3 }, ... },
	--   (give anti-tank weapons DamageVsArmor = { Vehicle = 3 } and small arms { Vehicle = 0.1 })
	--
	-- Needs code as well as config: a new Hat style, a new Abilities field, a new
	-- Unlock Type, or indirect fire that should not draw a straight tracer.
}
GameConfig.Units = Units

-- Unit type the enemy commander buys.
GameConfig.ENEMY_UNIT_TYPE = "Rifleman"

-- Whether a team may deploy a unit type. Used by the server to validate deploy
-- requests and by the client to show locked buttons.
function GameConfig.IsUnitUnlocked(unitType: string, teamState: TeamState): boolean
	local definition = Units[unitType]
	if not definition then
		return false
	end
	local rule = definition.Unlock
	if rule.Type == "Default" then
		return true
	elseif rule.Type == "CommandTier" then
		return teamState.CommandTier >= (rule.Tier or 1)
	elseif rule.Type == "TrenchesOwned" then
		return teamState.TrenchesOwned >= (rule.Count or 0)
	end
	return false
end

-- Short player-facing description of what unlocks a unit, e.g. "Own 2 trenches".
function GameConfig.DescribeUnlock(unitType: string): string
	local definition = Units[unitType]
	if not definition then
		return "Unavailable"
	end
	local rule = definition.Unlock
	if rule.Type == "Default" then
		return "Available"
	elseif rule.Type == "CommandTier" then
		return `Command Tier {rule.Tier or 1}`
	elseif rule.Type == "TrenchesOwned" then
		return `Own {rule.Count or 0} trenches`
	end
	return "Unavailable"
end

-- "Over the Top" charge ----------------------------------------------------------
--
-- Ordered from a trench with a settled unit that has CanOrderCharge. Everyone
-- in the trench advances; for Duration seconds they move faster and do not
-- halt to shoot while enemies are in range.
GameConfig.Charge = {
	DisplayName = "Charge",
	Cost = 30, -- supplies
	Duration = 8, -- seconds
	SpeedMultiplier = 1.15,
	Cooldown = 20, -- seconds, per trench
}

-- Fortifications -----------------------------------------------------------------
--
-- Built at a trench the team owns, only while a settled unit with
-- CanBuildFortifications is in it. Construction pauses if that unit leaves or
-- dies. A trench's fortifications are torn down when the other team takes it.

export type FortificationDefinition = {
	DisplayName: string,
	SortOrder: number, -- order of the build buttons
	Model: string, -- which procedural model to build: "BarbedWire" | "Sandbags"
	Cost: number, -- supplies, paid when construction starts
	BuildTime: number, -- seconds
	MaxPerTrench: number,
	MaxHP: number, -- 0 = cannot be destroyed
	CoverMultiplier: number, -- extra multiplier on enemy hit chance against the trench's occupants (1 = none)
	-- Hazard strip, laid in front of the trench toward the enemy. Depth 0 = no strip.
	ForwardOffset: number, -- studs from the trench centre to the strip's centre
	Depth: number, -- studs (X-axis) the strip covers
	SlowMultiplier: number, -- move-speed multiplier for enemies inside the strip
	DamagePerSecond: number, -- to each enemy inside the strip
	CutDamagePerSecond: number, -- damage each enemy inside deals to the strip (cutting through)
}

local Fortifications: { [string]: FortificationDefinition } = {
	BarbedWire = {
		DisplayName = "Barbed Wire",
		SortOrder = 1,
		Model = "BarbedWire",
		Cost = 60,
		BuildTime = 6,
		MaxPerTrench = 1,
		MaxHP = 150,
		CoverMultiplier = 1,
		ForwardOffset = 14,
		Depth = 6,
		SlowMultiplier = 0.3,
		DamagePerSecond = 8,
		CutDamagePerSecond = 20,
	},

	ReinforcedSandbags = {
		DisplayName = "Sandbags",
		SortOrder = 2,
		Model = "Sandbags",
		Cost = 80,
		BuildTime = 8,
		MaxPerTrench = 1,
		MaxHP = 0,
		CoverMultiplier = 0.7,
		ForwardOffset = 0,
		Depth = 0,
		SlowMultiplier = 1,
		DamagePerSecond = 0,
		CutDamagePerSecond = 0,
	},
}
GameConfig.Fortifications = Fortifications

-- Enemy commander (simple timer-driven AI) -------------------------------------

GameConfig.ENEMY_SPAWN_INTERVAL = 5 -- seconds between enemy commander decisions
GameConfig.ENEMY_MAX_UNITS = 8 -- enemy units alive at once
GameConfig.ENEMY_ADVANCE_INTERVAL = 25 -- seconds between enemy advance orders
GameConfig.ENEMY_ADVANCE_MIN_UNITS = 4 -- units a trench needs before it advances

-- Remotes ------------------------------------------------------------------------

-- Names of the remotes the server creates in ReplicatedStorage.Remotes.
GameConfig.REMOTES_FOLDER = "Remotes"
GameConfig.REMOTE_DEPLOY_UNIT = "DeployUnit" -- (unitType: string)
GameConfig.REMOTE_ADVANCE_TRENCH = "AdvanceTrench" -- (trenchIndex: number)
GameConfig.REMOTE_RETREAT_TRENCH = "RetreatTrench" -- (trenchIndex: number)
GameConfig.REMOTE_TRIGGER_CHARGE = "TriggerCharge" -- (trenchIndex: number)
GameConfig.REMOTE_BUILD_FORTIFICATION = "BuildFortification" -- (trenchIndex: number, fortificationType: string)
-- UnreliableRemoteEvent, server -> clients. Carries a flat array of Vector3s,
-- two per shot (muzzle, impact), for clients to draw tracers from.
GameConfig.REMOTE_SHOTS_FIRED = "ShotsFired"

-- Keys of a string-keyed registry (Units, Fortifications) in SortOrder.
function GameConfig.GetSortedKeys(registry: { [string]: { SortOrder: number } }): { string }
	local keys: { string } = {}
	for key in registry do
		table.insert(keys, key)
	end
	table.sort(keys, function(a: string, b: string)
		local orderA, orderB = registry[a].SortOrder, registry[b].SortOrder
		if orderA ~= orderB then
			return orderA < orderB
		end
		return a < b
	end)
	return keys
end

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
