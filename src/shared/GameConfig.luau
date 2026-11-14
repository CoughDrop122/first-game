--!strict
-- Shared game constants: units, economy, fortifications, remotes, and the
-- shape of the default generated battlefield.
--
-- Nothing here says where trenches are. Positions, slot counts and which
-- trench comes next are read from the map in the Workspace by Shared.MapLoader.

local GameConfig = {}

export type Owner = "Neutral" | "Allies" | "Enemies"

-- Trenches and units are miniatures: players stay normal-sized and tower over
-- the battlefield like a tabletop diorama.
GameConfig.MINIATURE_SCALE = 1 / 3 -- size of units relative to a player character

-- Height of the open ground, for a map that sets no GroundY attribute.
GameConfig.GROUND_Y = 0
-- Sandbag wall of a generated trench; reinforced sandbags are sized to match.
GameConfig.SANDBAG_HEIGHT = 0.5
GameConfig.SANDBAG_THICKNESS = 0.6
-- Studs of trench per soldier, used when a trench has no valid SlotCount.
GameConfig.DEFAULT_SLOT_SPACING = 4.8

-- The battlefield MapBuilder generates when the place has no
-- Workspace.CurrentMap: parallel trenches spread along X, Allies at -X.
-- Read only by MapBuilder; a map built in Studio ignores all of it.
GameConfig.DefaultMap = {
	TrenchCount = 5,
	TrenchSpacing = 54, -- studs between trench centres
	TrenchLength = 48, -- studs
	TrenchWidth = 2, -- studs
	TrenchDepth = 1, -- how far the floor sits below ground level
	SlotsPerTrench = 10,
	SpawnZoneWidth = 24, -- depth of each team's spawn zone
	MarginZ = 12, -- ground beyond each trench end
}

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

-- Match flow. A team wins by taking the other team's home trench. The match
-- state is replicated as attributes on the TeamState folder:
--   MatchPhase : MATCH_PHASE_PLAYING or MATCH_PHASE_ENDED
--   Winner     : "Allies" / "Enemies" once ended, "" while playing
GameConfig.MATCH_PHASE_PLAYING = "Playing"
GameConfig.MATCH_PHASE_ENDED = "Ended"
GameConfig.RESTART_COOLDOWN = 3 -- seconds after a match ends before Play Again is accepted

-- Combat rules shared by every unit ----------------------------------------

-- Hit-chance multiplier against a target settled in a trench, unless the
-- shooter is in that same trench or its unit type has IgnoresCover.
GameConfig.TRENCH_COVER_MULTIPLIER = 0.35
-- Width (studs, along world X) of the buckets the server sorts units into so a unit
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
		Range = 40, -- less than the default map's trench spacing, so neighbouring trenches can't trade fire
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

	-- Fast, inaccurate fire: strongest against troops crossing open ground.
	MachineGunner = {
		DisplayName = "Machine Gunner",
		SortOrder = 3,
		Cost = 150,
		MaxHP = 110,
		MoveSpeed = 6.5, -- heavy weapon
		Range = 46,
		FireRate = 6,
		Damage = 10,
		Accuracy = 0.4,
		ArmorType = "Infantry",
		IgnoresCover = false,
		SplashRadius = 0,
		OccupiesTrenchSlot = true,
		Visual = {
			BodyScale = 1.05,
			Hat = "Helmet",
			HatColor = Color3.fromRGB(60, 62, 58),
			WeaponSize = Vector3.new(0.45, 0.45, 3.2),
			WeaponColor = Color3.fromRGB(30, 30, 32),
			AccentColor = Color3.fromRGB(120, 124, 128),
		},
		Unlock = { Type = "TrenchesOwned", Count = 2 },
	},

	-- Slow, precise shots that ignore trench cover. Range exceeds the default map's trench spacing,
	-- so a sniper can pick at the neighbouring trench without leaving its own.
	Sniper = {
		DisplayName = "Sniper",
		SortOrder = 4,
		Cost = 160,
		MaxHP = 70,
		MoveSpeed = 8,
		Range = 70,
		FireRate = 0.25,
		Damage = 80,
		Accuracy = 0.75,
		ArmorType = "Infantry",
		IgnoresCover = true,
		SplashRadius = 0,
		OccupiesTrenchSlot = true,
		Visual = {
			BodyScale = 0.95,
			Hat = "None",
			HatColor = Color3.fromRGB(0, 0, 0),
			WeaponSize = Vector3.new(0.2, 0.2, 3.6),
			WeaponColor = Color3.fromRGB(70, 52, 34),
			AccentColor = Color3.fromRGB(70, 110, 60),
		},
		Unlock = { Type = "TrenchesOwned", Count = 3 },
	},

	-- Short-ranged grenades that ignore cover and also hurt enemies next to the
	-- target (SplashRadius reaches the neighbouring slot on each side). Has to
	-- get close, so it works best alongside a charge.
	Grenadier = {
		DisplayName = "Grenadier",
		SortOrder = 5,
		Cost = 110,
		MaxHP = 100,
		MoveSpeed = 8,
		Range = 26,
		FireRate = 0.4,
		Damage = 35,
		Accuracy = 0.6,
		ArmorType = "Infantry",
		IgnoresCover = true,
		SplashRadius = 5,
		OccupiesTrenchSlot = true,
		Visual = {
			BodyScale = 1,
			Hat = "Helmet",
			HatColor = Color3.fromRGB(88, 96, 72),
			WeaponSize = Vector3.new(0.5, 0.5, 1.2),
			WeaponColor = Color3.fromRGB(50, 60, 40),
			AccentColor = Color3.fromRGB(215, 120, 40),
		},
		Unlock = { Type = "TrenchesOwned", Count = 3 },
	},

	-- Future units: add an entry like the sketches below. Fields shown are the
	-- ones that differ from a Rifleman; every field in UnitDefinition is required.
	--
	-- Mortar = { Cost = 220, Range = 110, FireRate = 0.2, Damage = 55, SplashRadius = 8,
	--     IgnoresCover = true, Unlock = { Type = "CommandTier", Tier = 2 }, ... },
	-- Tank   = { Cost = 500, MaxHP = 900, MoveSpeed = 5, ArmorType = "Vehicle",
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
-- halt to shoot while crossing open ground. They still won't run into a trench
-- the enemy occupies: they stop HaltDistance short of it and fight until it is
-- clear, as in a regular assault.
GameConfig.Charge = {
	DisplayName = "Charge",
	Cost = 30, -- supplies
	Duration = 8, -- seconds
	SpeedMultiplier = 1.15,
	HaltDistance = 8, -- studs from an enemy-occupied trench at which chargers stop
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
	Depth: number, -- studs the strip covers, front to back
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
GameConfig.REMOTE_RESTART_MATCH = "RestartMatch" -- (); only accepted once the match has ended
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

return GameConfig
