--!strict
-- Server-authoritative battlefield simulation. Spawns miniature units of the
-- types defined in GameConfig.Units, tracks which trench slot each one holds,
-- marches them between slots, resolves combat, and runs officer abilities
-- (aura, charge, fortification building). Everything costs Supplies (Economy).
--
-- Trench Models carry replicated attributes the client UI reads:
--   AlliesCount / EnemiesCount       : units tied to the trench
--   Owner                            : last team to hold the trench uncontested
--   AlliesCanCharge / EnemiesCanCharge, AlliesCanBuild / EnemiesCanBuild
--                                    : a settled unit with that ability is present
--   AlliesChargeReadyAt / Enemies... : server time the next Charge is allowed
--   Fort_<type>_Count                : fortifications of that type here
--   Fort_<type>_Building             : how many of those are still under construction

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local Economy = require(script.Parent:WaitForChild("Economy"))

type Team = GameConfig.Team
type UnitDefinition = GameConfig.UnitDefinition
type UnitAura = GameConfig.UnitAura
type FortificationDefinition = GameConfig.FortificationDefinition

type Unit = {
	id: number,
	unitType: string,
	def: UnitDefinition,
	team: Team,
	model: Model,
	position: Vector3, -- feet position
	trenchIndex: number, -- trench the unit holds, is marching to, or is waiting outside
	slotIndex: number, -- slot in that trench, or NO_SLOT while waiting outside it
	preferredSlot: number, -- last slot held; keeps the unit in its lane
	waitPosition: Vector3, -- where to stand while waiting outside a trench (NO_SLOT only)
	arrived: boolean, -- settled in its slot
	health: number,
	fireCooldown: number, -- seconds until the unit may shoot again
	scanCooldown: number, -- seconds until the unit looks for a new target
	target: Unit?, -- enemy currently being engaged
	retreating: boolean, -- falling back; keeps moving even under fire
	chargeTimeLeft: number, -- seconds of Charge left: faster, and won't halt to shoot
	dead: boolean,
}

type Fortification = {
	fortType: string,
	def: FortificationDefinition,
	team: Team,
	trenchIndex: number,
	model: Model,
	centerX: number, -- world X of the hazard strip's centre line
	buildProgress: number, -- seconds of construction done
	built: boolean,
	health: number,
	destroyed: boolean,
}

local TEAMS: { Team } = { "Allies", "Enemies" }

local NO_SLOT = 0
-- How far short of a trench a unit stands while waiting outside it.
local WAIT_STANDOFF = 6
local ORDER_COOLDOWN = 0.2 -- seconds between trench orders, per player

local TEAM_COLORS: { [Team]: Color3 } = {
	Allies = Color3.fromRGB(50, 90, 170),
	Enemies = Color3.fromRGB(160, 50, 50),
}
local SKIN_COLOR = Color3.fromRGB(224, 184, 150)
local WIRE_COLOR = Color3.fromRGB(70, 70, 75)
local WIRE_POST_COLOR = Color3.fromRGB(90, 62, 40)
local REINFORCED_SANDBAG_COLOR = Color3.fromRGB(150, 130, 92)

local MISS_SPREAD = 1.5 -- studs a missed shot lands away from its target
local TARGET_SCAN_INTERVAL = 0.25 -- seconds between a unit's searches for the nearest enemy
-- Shots per ShotsFired packet; keeps each one under the ~900 byte limit of an
-- UnreliableRemoteEvent.
local SHOTS_PER_PACKET = 20
local UNDER_CONSTRUCTION_TRANSPARENCY = 0.7

-- A full-size character is roughly 2 x 5 x 1 studs: a 3.8 tall body plus head.
local CHARACTER_BODY_SIZE = Vector3.new(2, 3.8, 1)
local CHARACTER_HEAD_DIAMETER = 1.2

local TEAM_FACING: { [Team]: Vector3 } = {
	Allies = Vector3.xAxis,
	Enemies = -Vector3.xAxis,
}

local function getOtherTeam(team: Team): Team
	return if team == "Allies" then "Enemies" else "Allies"
end

local function isValidTrenchIndex(trenchIndex: number): boolean
	return trenchIndex >= 1 and trenchIndex <= GameConfig.TRENCH_COUNT
end

-- World setup ---------------------------------------------------------------

local trenchesFolder = Workspace:WaitForChild("Trenches")
local trenchModels: { Model } = {}
for trenchIndex = 1, GameConfig.TRENCH_COUNT do
	trenchModels[trenchIndex] = trenchesFolder:WaitForChild(`Trench_{trenchIndex}`) :: Model
end

local unitsFolder = Instance.new("Folder")
unitsFolder.Name = "Units"
unitsFolder.Parent = Workspace

local fortificationsFolder = Instance.new("Folder")
fortificationsFolder.Name = "Fortifications"
fortificationsFolder.Parent = Workspace

local remotes = Instance.new("Folder")
remotes.Name = GameConfig.REMOTES_FOLDER

local function makeRemoteEvent(name: string): RemoteEvent
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = remotes
	return remote
end

local deployRemote = makeRemoteEvent(GameConfig.REMOTE_DEPLOY_UNIT)
local advanceRemote = makeRemoteEvent(GameConfig.REMOTE_ADVANCE_TRENCH)
local retreatRemote = makeRemoteEvent(GameConfig.REMOTE_RETREAT_TRENCH)
local chargeRemote = makeRemoteEvent(GameConfig.REMOTE_TRIGGER_CHARGE)
local buildRemote = makeRemoteEvent(GameConfig.REMOTE_BUILD_FORTIFICATION)

-- Tracers are cosmetic, so a dropped packet is fine.
local shotsRemote = Instance.new("UnreliableRemoteEvent")
shotsRemote.Name = GameConfig.REMOTE_SHOTS_FIRED
shotsRemote.Parent = remotes

remotes.Parent = ReplicatedStorage

-- State -----------------------------------------------------------------------

local units: { Unit } = {}
local nextUnitId = 1
local rng = Random.new()

-- slots[trenchIndex][slotIndex] = the unit assigned there (arrived or en route).
local slots: { { [number]: Unit } } = {}
for trenchIndex = 1, GameConfig.TRENCH_COUNT do
	slots[trenchIndex] = {}
end

local fortifications: { Fortification } = {}

-- Units of a team tied to a trench: holding a slot, marching to one, or
-- waiting outside it.
local function countUnits(trenchIndex: number, team: Team): number
	local count = 0
	for _, unit in units do
		if unit.team == team and unit.trenchIndex == trenchIndex and not unit.dead then
			count += 1
		end
	end
	return count
end

local function countTeam(team: Team): number
	local count = 0
	for _, unit in units do
		if unit.team == team and not unit.dead then
			count += 1
		end
	end
	return count
end

-- Whether a unit of `team` with the given ability flag is settled in the trench.
local function hasSettledAbility(
	trenchIndex: number,
	team: Team,
	ability: "CanOrderCharge" | "CanBuildFortifications"
): boolean
	for _, unit in slots[trenchIndex] do
		local abilities = unit.def.Abilities
		if unit.team == team and unit.arrived and abilities and abilities[ability] then
			return true
		end
	end
	return false
end

-- Strongest aura among `team`'s units settled in the trench, if any.
local function getAura(trenchIndex: number, team: Team): UnitAura?
	local best: UnitAura? = nil
	for _, unit in slots[trenchIndex] do
		local abilities = unit.def.Abilities
		local aura = abilities and abilities.Aura
		if aura and unit.team == team and unit.arrived then
			if not best or aura.FireRateMultiplier * aura.AccuracyMultiplier > best.FireRateMultiplier * best.AccuracyMultiplier then
				best = aura
			end
		end
	end
	return best
end

-- Refreshes the trench's unit-related attributes (see the header comment).
local function refreshTrench(trenchIndex: number)
	local trench = trenchModels[trenchIndex]
	for _, team in TEAMS do
		trench:SetAttribute(`{team}Count`, countUnits(trenchIndex, team))
		trench:SetAttribute(`{team}CanCharge`, hasSettledAbility(trenchIndex, team, "CanOrderCharge"))
		trench:SetAttribute(`{team}CanBuild`, hasSettledAbility(trenchIndex, team, "CanBuildFortifications"))
	end
end

local function countFortifications(trenchIndex: number, fortType: string): (number, number)
	local total, building = 0, 0
	for _, fort in fortifications do
		if fort.trenchIndex == trenchIndex and fort.fortType == fortType and not fort.destroyed then
			total += 1
			if not fort.built then
				building += 1
			end
		end
	end
	return total, building
end

local function refreshFortificationAttributes(trenchIndex: number)
	local trench = trenchModels[trenchIndex]
	for fortType in GameConfig.Fortifications do
		local total, building = countFortifications(trenchIndex, fortType)
		trench:SetAttribute(`Fort_{fortType}_Count`, total)
		trench:SetAttribute(`Fort_{fortType}_Building`, building)
	end
end

-- Marks a fortification destroyed and removes its model. The entry is dropped
-- from `fortifications` by the next updateFortifications pass.
local function destroyFortification(fort: Fortification)
	if fort.destroyed then
		return
	end
	fort.destroyed = true
	fort.model:Destroy()
	refreshFortificationAttributes(fort.trenchIndex)
end

-- A trench belongs to a team once that team has a unit settled in it and the
-- other team has none assigned to it. A contested trench keeps its old owner.
-- Taking a trench tears down the previous owner's fortifications there.
local function updateOwner(trenchIndex: number)
	local holder: Team? = nil
	local settled = false
	for _, unit in slots[trenchIndex] do
		if holder and unit.team ~= holder then
			return
		end
		holder = unit.team
		settled = settled or unit.arrived
	end
	if not holder or not settled then
		return
	end

	local trench = trenchModels[trenchIndex]
	if trench:GetAttribute("Owner") == holder then
		return
	end
	trench:SetAttribute("Owner", holder)
	for _, fort in fortifications do
		if fort.trenchIndex == trenchIndex and fort.team ~= holder then
			destroyFortification(fort)
		end
	end
end

-- Free slot closest to preferredSlot, or nil if the trench is full.
local function findFreeSlot(trenchIndex: number, preferredSlot: number): number?
	local trenchSlots = slots[trenchIndex]
	for offset = 0, GameConfig.SLOTS_PER_TRENCH - 1 do
		for _, slotIndex in { preferredSlot - offset, preferredSlot + offset } do
			if slotIndex >= 1 and slotIndex <= GameConfig.SLOTS_PER_TRENCH and not trenchSlots[slotIndex] then
				return slotIndex
			end
		end
	end
	return nil
end

local function vacateSlot(unit: Unit)
	if slots[unit.trenchIndex][unit.slotIndex] == unit then
		slots[unit.trenchIndex][unit.slotIndex] = nil
	end
end

local function assignSlot(unit: Unit, trenchIndex: number, slotIndex: number)
	local previousTrench = unit.trenchIndex
	vacateSlot(unit)

	slots[trenchIndex][slotIndex] = unit
	unit.trenchIndex = trenchIndex
	unit.slotIndex = slotIndex
	unit.preferredSlot = slotIndex
	unit.arrived = false
	unit.model:SetAttribute("TrenchIndex", trenchIndex)
	unit.model:SetAttribute("SlotIndex", slotIndex)

	refreshTrench(previousTrench)
	refreshTrench(trenchIndex)
end

-- Sends a unit to stand in the open just short of a trench, approaching in
-- `travelDirection` (+1 / -1 along X). Used when the trench has no free slot
-- (the movement loop moves the unit in as soon as one opens) and for unit
-- types that never occupy a slot.
local function queueForTrench(unit: Unit, trenchIndex: number, travelDirection: number)
	local previousTrench = unit.trenchIndex
	vacateSlot(unit)

	local lanePosition = GameConfig.GetSlotWorldPosition(trenchIndex, unit.preferredSlot)
	unit.waitPosition = Vector3.new(
		lanePosition.X - travelDirection * WAIT_STANDOFF,
		GameConfig.GROUND_Y,
		lanePosition.Z
	)
	unit.trenchIndex = trenchIndex
	unit.slotIndex = NO_SLOT
	unit.arrived = false
	unit.model:SetAttribute("TrenchIndex", trenchIndex)
	unit.model:SetAttribute("SlotIndex", NO_SLOT)

	refreshTrench(previousTrench)
	refreshTrench(trenchIndex)
end

-- Units -----------------------------------------------------------------------

local function makePart(props: { [string]: any }, parent: Instance): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = Enum.Material.SmoothPlastic
	for key, value in props do
		(part :: any)[key] = value
	end
	part.Parent = parent
	return part
end

local function getUnitScale(def: UnitDefinition): number
	return GameConfig.MINIATURE_SCALE * def.Visual.BodyScale
end

-- Builds a soldier standing at the origin facing -Z, pivoting at its feet,
-- dressed according to its unit type's Visual settings.
local function buildUnitModel(team: Team, id: number, unitType: string, def: UnitDefinition): Model
	local visual = def.Visual
	local unitScale = getUnitScale(def)
	local bodySize = CHARACTER_BODY_SIZE * unitScale
	local headDiameter = CHARACTER_HEAD_DIAMETER * unitScale
	local headTopY = bodySize.Y + headDiameter

	local model = Instance.new("Model")
	model.Name = `{team}{unitType}_{id}`

	local body = makePart({
		Name = "Body",
		Size = bodySize,
		Position = Vector3.new(0, bodySize.Y / 2, 0),
		Color = TEAM_COLORS[team],
	}, model)
	body.PivotOffset = CFrame.new(0, -bodySize.Y / 2, 0)
	model.PrimaryPart = body

	makePart({
		Name = "Head",
		Shape = Enum.PartType.Ball,
		Size = Vector3.one * headDiameter,
		Position = Vector3.new(0, bodySize.Y + headDiameter / 2, 0),
		Color = SKIN_COLOR,
	}, model)

	if visual.Hat == "Helmet" then
		makePart({
			Name = "Helmet",
			Size = Vector3.new(headDiameter * 1.25, headDiameter * 0.45, headDiameter * 1.25),
			Position = Vector3.new(0, headTopY - headDiameter * 0.15, 0),
			Color = visual.HatColor,
		}, model)
	elseif visual.Hat == "PeakedCap" then
		makePart({
			Name = "Cap",
			Size = Vector3.new(headDiameter * 1.1, headDiameter * 0.4, headDiameter * 1.1),
			Position = Vector3.new(0, headTopY, 0),
			Color = visual.HatColor,
		}, model)
		makePart({
			Name = "CapPeak",
			Size = Vector3.new(headDiameter * 0.9, headDiameter * 0.1, headDiameter * 0.5),
			Position = Vector3.new(0, headTopY - headDiameter * 0.15, -headDiameter * 0.7),
			Color = visual.HatColor,
		}, model)
	end

	local weaponSize = visual.WeaponSize * unitScale
	makePart({
		Name = "Weapon",
		Size = weaponSize,
		Position = Vector3.new(bodySize.X / 2 + weaponSize.X / 2, bodySize.Y * 0.7, -weaponSize.Z / 4),
		Color = visual.WeaponColor,
	}, model)

	if visual.AccentColor then
		makePart({
			Name = "Accent",
			Size = Vector3.new(bodySize.X * 1.08, bodySize.Y * 0.15, bodySize.Z * 1.15),
			Position = Vector3.new(0, bodySize.Y * 0.75, 0),
			Color = visual.AccentColor,
		}, model)
	end

	model:SetAttribute("Team", team)
	model:SetAttribute("UnitId", id)
	model:SetAttribute("UnitType", unitType)
	model:SetAttribute("Health", def.MaxHP)
	return model
end

local function placeUnit(unit: Unit, facing: Vector3)
	unit.model:PivotTo(CFrame.lookAt(unit.position, unit.position + facing))
end

-- Buys a unit for its team: spawns it in the spawn zone and sends it to the
-- home trench. Returns nil, charging nothing, if the unit type doesn't exist or
-- is locked, the home trench has no free slot, or the team can't afford it.
local function spawnUnit(team: Team, unitType: string): Unit?
	local def = GameConfig.Units[unitType]
	if not def or not GameConfig.IsUnitUnlocked(unitType, Economy.GetTeamState(team)) then
		return nil
	end

	local homeTrench = GameConfig.GetHomeTrenchIndex(team)
	local preferredSlot = rng:NextInteger(1, GameConfig.SLOTS_PER_TRENCH)
	local slotIndex: number? = nil
	if def.OccupiesTrenchSlot then
		slotIndex = findFreeSlot(homeTrench, preferredSlot)
		if not slotIndex then
			return nil
		end
		preferredSlot = slotIndex
	end
	if not Economy.TrySpend(team, def.Cost) then
		return nil
	end

	local id = nextUnitId
	nextUnitId += 1

	-- Start level with the destination lane so the unit marches straight in.
	local lanePosition = GameConfig.GetSlotWorldPosition(homeTrench, preferredSlot)
	local unit: Unit = {
		id = id,
		unitType = unitType,
		def = def,
		team = team,
		model = buildUnitModel(team, id, unitType, def),
		position = Vector3.new(GameConfig.GetSpawnZoneCenterX(team), GameConfig.GROUND_Y, lanePosition.Z),
		trenchIndex = homeTrench,
		slotIndex = NO_SLOT,
		preferredSlot = preferredSlot,
		waitPosition = Vector3.zero,
		arrived = false,
		health = def.MaxHP,
		fireCooldown = rng:NextNumber(0, 1 / def.FireRate),
		scanCooldown = rng:NextNumber(0, TARGET_SCAN_INTERVAL),
		target = nil,
		retreating = false,
		chargeTimeLeft = 0,
		dead = false,
	}
	table.insert(units, unit)
	if slotIndex then
		assignSlot(unit, homeTrench, slotIndex)
	else
		queueForTrench(unit, homeTrench, GameConfig.GetAdvanceDirection(team))
	end
	placeUnit(unit, TEAM_FACING[team])
	unit.model.Parent = unitsFolder
	return unit
end

-- Orders every unit of `team` at the trench to move toward the other side
-- (advance) or back toward its own spawn (retreat). Every unit goes:
--   * it takes a free slot in the next trench if there is one;
--   * otherwise it spills past that trench and heads for the first trench
--     further along that has a free slot;
--   * if every trench along the way is full, it waits in the open outside the
--     last one and takes the first slot that frees up.
-- Units that never occupy a slot simply move up outside the next trench.
-- `chargeDuration` > 0 makes it a Charge (see GameConfig.Charge).
local function orderTrench(team: Team, trenchIndex: number, retreat: boolean, chargeDuration: number)
	local advanceDirection = GameConfig.GetAdvanceDirection(team)
	local travelDirection = if retreat then -advanceDirection else advanceDirection
	local firstTarget = trenchIndex + travelDirection
	if not isValidTrenchIndex(firstTarget) then
		return
	end

	local movers: { Unit } = {}
	for _, unit in units do
		if unit.team == team and unit.trenchIndex == trenchIndex and not unit.dead then
			table.insert(movers, unit)
		end
	end

	for _, unit in movers do
		local destination = firstTarget
		local slotIndex: number? = nil
		if unit.def.OccupiesTrenchSlot then
			slotIndex = findFreeSlot(destination, unit.preferredSlot)
			while not slotIndex and isValidTrenchIndex(destination + travelDirection) do
				destination += travelDirection
				slotIndex = findFreeSlot(destination, unit.preferredSlot)
			end
		end

		if slotIndex then
			assignSlot(unit, destination, slotIndex)
		else
			queueForTrench(unit, destination, travelDirection)
		end
		unit.retreating = retreat
		unit.chargeTimeLeft = chargeDuration
	end
end

-- Fortifications ----------------------------------------------------------------

local function setModelTransparency(model: Model, transparency: number)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Transparency = transparency
		end
	end
end

-- Rows of posts strung with wire, covering the hazard strip centred on centerX.
local function buildBarbedWireModel(model: Model, def: FortificationDefinition, centerX: number)
	local length = GameConfig.TRENCH_LENGTH
	local postSpacing = 6
	local postHeight = 0.6
	local rowOffsets = { -def.Depth / 2 + 0.5, 0, def.Depth / 2 - 0.5 }

	for _, rowOffset in rowOffsets do
		local x = centerX + rowOffset
		for _, wireHeight in { 0.25, 0.5 } do
			makePart({
				Name = "Wire",
				Size = Vector3.new(0.06, 0.06, length),
				Position = Vector3.new(x, GameConfig.GROUND_Y + wireHeight, 0),
				Color = WIRE_COLOR,
				Material = Enum.Material.Metal,
			}, model)
		end
		for z = -length / 2, length / 2, postSpacing do
			makePart({
				Name = "Post",
				Size = Vector3.new(0.15, postHeight, 0.15),
				Position = Vector3.new(x, GameConfig.GROUND_Y + postHeight / 2, z),
				Color = WIRE_POST_COLOR,
				Material = Enum.Material.Wood,
			}, model)
		end
	end
end

-- An extra course of sandbags on top of both trench walls.
local function buildSandbagsModel(model: Model, _def: FortificationDefinition, centerX: number)
	local courseHeight = 0.35
	local wallOffsetX = GameConfig.TRENCH_WIDTH / 2 + GameConfig.SANDBAG_THICKNESS / 2
	for _, side in { -1, 1 } do
		makePart({
			Name = "SandbagCourse",
			Size = Vector3.new(GameConfig.SANDBAG_THICKNESS * 0.8, courseHeight, GameConfig.TRENCH_LENGTH),
			Position = Vector3.new(
				centerX + side * wallOffsetX,
				GameConfig.GROUND_Y + GameConfig.SANDBAG_HEIGHT + courseHeight / 2,
				0
			),
			Color = REINFORCED_SANDBAG_COLOR,
			Material = Enum.Material.Sand,
		}, model)
	end
end

-- Procedural model builders, keyed by FortificationDefinition.Model.
local FORTIFICATION_MODEL_BUILDERS: { [string]: (Model, FortificationDefinition, number) -> () } = {
	BarbedWire = buildBarbedWireModel,
	Sandbags = buildSandbagsModel,
}

-- Starts construction of a fortification at a trench. Returns false, charging
-- nothing, unless the team owns the trench, has a settled builder in it, is
-- under the per-trench limit and can afford it.
local function startFortification(team: Team, trenchIndex: number, fortType: string): boolean
	local def = GameConfig.Fortifications[fortType]
	if not def then
		return false
	end
	if trenchModels[trenchIndex]:GetAttribute("Owner") ~= team then
		return false
	end
	if not hasSettledAbility(trenchIndex, team, "CanBuildFortifications") then
		return false
	end
	local existing = countFortifications(trenchIndex, fortType)
	if existing >= def.MaxPerTrench then
		return false
	end
	if not Economy.TrySpend(team, def.Cost) then
		return false
	end

	-- Hazard strips go in front of the trench, each further one beyond the last.
	local forward = GameConfig.GetAdvanceDirection(team)
	local centerX = GameConfig.GetTrenchCenterX(trenchIndex)
		+ forward * (def.ForwardOffset + existing * (def.Depth + 1))

	local model = Instance.new("Model")
	model.Name = `{fortType}_Trench{trenchIndex}`
	model:SetAttribute("Team", team)
	model:SetAttribute("TrenchIndex", trenchIndex)
	local buildModel = FORTIFICATION_MODEL_BUILDERS[def.Model]
	if buildModel then
		buildModel(model, def, centerX)
	end
	setModelTransparency(model, UNDER_CONSTRUCTION_TRANSPARENCY)
	model.Parent = fortificationsFolder

	table.insert(fortifications, {
		fortType = fortType,
		def = def,
		team = team,
		trenchIndex = trenchIndex,
		model = model,
		centerX = centerX,
		buildProgress = 0,
		built = false,
		health = def.MaxHP,
		destroyed = false,
	})
	refreshFortificationAttributes(trenchIndex)
	return true
end

-- Advances construction (only while a builder is settled in the trench) and
-- drops destroyed fortifications from the list.
local function updateFortifications(deltaTime: number)
	local anyDestroyed = false
	for _, fort in fortifications do
		if fort.destroyed then
			anyDestroyed = true
		elseif not fort.built and hasSettledAbility(fort.trenchIndex, fort.team, "CanBuildFortifications") then
			fort.buildProgress += deltaTime
			if fort.buildProgress >= fort.def.BuildTime then
				fort.built = true
				setModelTransparency(fort.model, 0)
				refreshFortificationAttributes(fort.trenchIndex)
			end
		end
	end

	if anyDestroyed then
		local remaining: { Fortification } = {}
		for _, fort in fortifications do
			if not fort.destroyed then
				table.insert(remaining, fort)
			end
		end
		fortifications = remaining
	end
end

-- Hit-chance multiplier for shots at `team`'s units settled in the trench.
local function getCoverMultiplier(trenchIndex: number, team: Team): number
	local multiplier = GameConfig.TRENCH_COVER_MULTIPLIER
	for _, fort in fortifications do
		if fort.trenchIndex == trenchIndex and fort.team == team and fort.built and not fort.destroyed then
			multiplier *= fort.def.CoverMultiplier
		end
	end
	return multiplier
end

-- Combat ----------------------------------------------------------------------

local function getChestPosition(unit: Unit): Vector3
	return unit.position + Vector3.new(0, CHARACTER_BODY_SIZE.Y * getUnitScale(unit.def) * 0.7, 0)
end

-- Shots fired this frame as a flat array: muzzle, impact, muzzle, impact, ...
-- Clients draw the tracers; the server only reports where shots went.
local pendingShots: { Vector3 } = {}

local function flushShots()
	local count = #pendingShots
	if count == 0 then
		return
	end
	local vectorsPerPacket = SHOTS_PER_PACKET * 2
	for first = 1, count, vectorsPerPacket do
		local last = math.min(first + vectorsPerPacket - 1, count)
		shotsRemote:FireAllClients(table.move(pendingShots, first, last, 1, {}))
	end
	table.clear(pendingShots)
end

-- Marks a unit dead and removes its model. The entry is dropped from `units`
-- by the next updateCombat pass.
local function killUnit(unit: Unit)
	unit.dead = true
	vacateSlot(unit)
	refreshTrench(unit.trenchIndex)
	updateOwner(unit.trenchIndex)
	unit.model:Destroy()
end

-- `replicateHealth` is false for continuous damage, to avoid an attribute
-- update every frame.
local function damageUnit(target: Unit, amount: number, attackerTeam: Team, replicateHealth: boolean)
	if target.dead then
		return
	end
	target.health -= amount
	if target.health <= 0 then
		killUnit(target)
		Economy.Add(attackerTeam, GameConfig.KILL_BOUNTY)
	elseif replicateHealth then
		target.model:SetAttribute("Health", math.ceil(target.health))
	end
end

-- Spatial buckets: living units grouped by team and by strips of X, rebuilt at
-- most once per frame, so range queries only look at nearby enemies.
local BUCKET_SIZE = GameConfig.TARGET_BUCKET_SIZE
local buckets: { [Team]: { [number]: { Unit } } } = { Allies = {}, Enemies = {} }
local bucketsStale = true

local function rebuildBuckets()
	for _, teamBuckets in buckets do
		table.clear(teamBuckets)
	end
	for _, unit in units do
		if not unit.dead then
			local teamBuckets = buckets[unit.team]
			local key = math.floor(unit.position.X / BUCKET_SIZE)
			local bucket = teamBuckets[key]
			if not bucket then
				bucket = {}
				teamBuckets[key] = bucket
			end
			table.insert(bucket, unit)
		end
	end
	bucketsStale = false
end

-- Calls `visit` for every living unit of `team` within `radius` of `position`.
local function forEachUnitInRadius(team: Team, position: Vector3, radius: number, visit: (Unit, number) -> ())
	if bucketsStale then
		rebuildBuckets()
	end
	local teamBuckets = buckets[team]
	for key = math.floor((position.X - radius) / BUCKET_SIZE), math.floor((position.X + radius) / BUCKET_SIZE) do
		local bucket = teamBuckets[key]
		if bucket then
			for _, unit in bucket do
				if not unit.dead then
					local distance = (unit.position - position).Magnitude
					if distance <= radius then
						visit(unit, distance)
					end
				end
			end
		end
	end
end

local function isInRange(shooter: Unit, target: Unit): boolean
	return (target.position - shooter.position).Magnitude <= shooter.def.Range
end

-- Nearest living enemy within the shooter's range, if any.
local function findTarget(shooter: Unit): Unit?
	local best: Unit? = nil
	local bestDistance = math.huge
	forEachUnitInRadius(getOtherTeam(shooter.team), shooter.position, shooter.def.Range, function(enemy: Unit, distance: number)
		if distance < bestDistance then
			best = enemy
			bestDistance = distance
		end
	end)
	return best
end

local function getDamage(shooterDef: UnitDefinition, target: Unit): number
	local byArmor = shooterDef.DamageVsArmor
	local multiplier = if byArmor then byArmor[target.def.ArmorType] or 1 else 1
	return shooterDef.Damage * multiplier
end

-- Fires one shot and returns the seconds until the shooter may fire again.
local function fireAt(shooter: Unit, target: Unit): number
	local def = shooter.def
	local accuracy = def.Accuracy
	local fireRate = def.FireRate

	-- Aura from a friendly officer settled in the shooter's trench.
	if shooter.arrived then
		local aura = getAura(shooter.trenchIndex, shooter.team)
		if aura then
			accuracy *= aura.AccuracyMultiplier
			fireRate *= aura.FireRateMultiplier
		end
	end

	local sharingTrench = shooter.arrived and shooter.trenchIndex == target.trenchIndex
	if target.arrived and not sharingTrench and not def.IgnoresCover then
		accuracy *= getCoverMultiplier(target.trenchIndex, target.team)
	end

	local impactPosition = target.position
	local aimPoint = getChestPosition(target)
	local hit = rng:NextNumber() < accuracy
	if not hit then
		aimPoint += rng:NextUnitVector() * MISS_SPREAD
	end
	table.insert(pendingShots, getChestPosition(shooter))
	table.insert(pendingShots, aimPoint)

	if hit then
		damageUnit(target, getDamage(def, target), shooter.team, true)
		if def.SplashRadius > 0 then
			forEachUnitInRadius(target.team, impactPosition, def.SplashRadius, function(nearby: Unit)
				if nearby ~= target then
					damageUnit(nearby, getDamage(def, nearby), shooter.team, true)
				end
			end)
		end
	end

	return (1 / fireRate) * rng:NextNumber(0.8, 1.2)
end

-- Keeps each unit's `target` current (nil when no enemy is in range) and fires
-- when its weapon is ready. Movement reads `target` to decide whether to halt.
local function updateCombat(deltaTime: number)
	local anyDied = false
	for _, unit in units do
		if unit.dead then
			anyDied = true
			continue
		end

		-- Drop a target that died or moved out of range, and look again at once.
		local target = unit.target
		if target and (target.dead or not isInRange(unit, target)) then
			target = nil
			unit.scanCooldown = 0
		end

		unit.scanCooldown -= deltaTime
		if unit.scanCooldown <= 0 then
			target = findTarget(unit)
			unit.scanCooldown = TARGET_SCAN_INTERVAL
		end

		unit.fireCooldown = math.max(unit.fireCooldown - deltaTime, 0)
		if target and unit.fireCooldown <= 0 then
			unit.fireCooldown = fireAt(unit, target)
			if target.dead then
				target = nil
				unit.scanCooldown = 0
			end
		end
		unit.target = target
	end

	-- Splash damage can kill units other than the one aimed at, so recheck.
	if not anyDied then
		for _, unit in units do
			if unit.dead then
				anyDied = true
				break
			end
		end
	end

	if anyDied then
		local living: { Unit } = {}
		for _, unit in units do
			if not unit.dead then
				table.insert(living, unit)
			end
		end
		units = living
	end

	flushShots()
end

-- Movement --------------------------------------------------------------------

-- Applies enemy hazard strips (barbed wire) the unit is standing in: the unit
-- is hurt and cuts at the wire. Returns its move-speed multiplier.
local function applyHazards(unit: Unit, deltaTime: number): number
	local speedMultiplier = 1
	for _, fort in fortifications do
		local def = fort.def
		if
			def.Depth > 0
			and fort.built
			and not fort.destroyed
			and fort.team ~= unit.team
			and math.abs(unit.position.X - fort.centerX) <= def.Depth / 2
			and math.abs(unit.position.Z) <= GameConfig.TRENCH_LENGTH / 2
		then
			speedMultiplier = math.min(speedMultiplier, def.SlowMultiplier)
			if def.MaxHP > 0 then
				fort.health -= def.CutDamagePerSecond * deltaTime
				if fort.health <= 0 then
					destroyFortification(fort)
				end
			end
			if def.DamagePerSecond > 0 then
				damageUnit(unit, def.DamagePerSecond * deltaTime, fort.team, false)
			end
		end
	end
	return speedMultiplier
end

RunService.Heartbeat:Connect(function(deltaTime: number)
	bucketsStale = true
	updateFortifications(deltaTime)
	updateCombat(deltaTime)

	for _, unit in units do
		if unit.dead or unit.arrived then
			continue
		end

		unit.chargeTimeLeft = math.max(unit.chargeTimeLeft - deltaTime, 0)
		local charging = unit.chargeTimeLeft > 0

		-- A unit waiting outside a full trench takes the first slot to open up.
		if unit.slotIndex == NO_SLOT and unit.def.OccupiesTrenchSlot then
			local freeSlot = findFreeSlot(unit.trenchIndex, unit.preferredSlot)
			if freeSlot then
				assignSlot(unit, unit.trenchIndex, freeSlot)
			end
		end

		local speedMultiplier = applyHazards(unit, deltaTime)
		if unit.dead then
			continue
		end

		-- Hold position and fight while any enemy is in range; move on once the
		-- way is clear. Retreating and charging units keep moving under fire.
		if unit.target and not unit.retreating and not charging then
			continue
		end
		if charging then
			speedMultiplier *= GameConfig.Charge.SpeedMultiplier
		end

		local hasSlot = unit.slotIndex ~= NO_SLOT
		local destination = if hasSlot
			then GameConfig.GetSlotWorldPosition(unit.trenchIndex, unit.slotIndex)
			else unit.waitPosition
		local toDestination = Vector3.new(destination.X - unit.position.X, 0, destination.Z - unit.position.Z)
		local distance = toDestination.Magnitude
		local step = unit.def.MoveSpeed * speedMultiplier * deltaTime

		if distance > step then
			-- March across open ground.
			local direction = toDestination / distance
			local moved = unit.position + direction * step
			unit.position = Vector3.new(moved.X, GameConfig.GROUND_Y, moved.Z)
			placeUnit(unit, direction)
		elseif hasSlot then
			-- Drop into the slot and face the enemy.
			unit.position = destination
			unit.arrived = true
			unit.retreating = false
			unit.chargeTimeLeft = 0
			placeUnit(unit, TEAM_FACING[unit.team])
			refreshTrench(unit.trenchIndex)
			updateOwner(unit.trenchIndex)
		elseif distance > 0.01 or unit.retreating then
			-- Reached the waiting spot outside the trench; stand facing the enemy.
			unit.position = destination
			unit.retreating = false
			placeUnit(unit, TEAM_FACING[unit.team])
		end
	end
end)

-- Charge ------------------------------------------------------------------------

-- Server time at which each team may next order a Charge from each trench.
local chargeReadyAt: { [Team]: { [number]: number } } = { Allies = {}, Enemies = {} }

-- Orders an "Over the Top" charge from a trench. Returns false, charging
-- nothing, unless there is a trench to charge at, a settled unit that can
-- order it, the cooldown has passed and the team can afford it.
local function triggerCharge(team: Team, trenchIndex: number): boolean
	local charge = GameConfig.Charge
	if not isValidTrenchIndex(trenchIndex + GameConfig.GetAdvanceDirection(team)) then
		return false
	end
	if not hasSettledAbility(trenchIndex, team, "CanOrderCharge") then
		return false
	end
	local now = Workspace:GetServerTimeNow()
	if now < (chargeReadyAt[team][trenchIndex] or 0) then
		return false
	end
	if not Economy.TrySpend(team, charge.Cost) then
		return false
	end

	local readyAt = now + charge.Cooldown
	chargeReadyAt[team][trenchIndex] = readyAt
	trenchModels[trenchIndex]:SetAttribute(`{team}ChargeReadyAt`, readyAt)
	orderTrench(team, trenchIndex, false, charge.Duration)
	return true
end

-- Player orders ---------------------------------------------------------------

-- All players command the Allies for now.
local PLAYER_TEAM: Team = "Allies"

local lastDeployTime: { [Player]: number } = {}
local lastOrderTime: { [Player]: number } = {}

deployRemote.OnServerEvent:Connect(function(player: Player, unitType: unknown)
	if typeof(unitType) ~= "string" then
		return
	end
	local now = os.clock()
	if now - (lastDeployTime[player] or 0) < GameConfig.DEPLOY_COOLDOWN then
		return
	end
	lastDeployTime[player] = now
	spawnUnit(PLAYER_TEAM, unitType)
end)

-- Validates a client-supplied trench index and applies the per-player order
-- rate limit. Returns the index if the order may go ahead.
local function acceptTrenchOrder(player: Player, trenchIndex: unknown): number?
	if typeof(trenchIndex) ~= "number" or trenchIndex % 1 ~= 0 or not isValidTrenchIndex(trenchIndex) then
		return nil
	end
	local now = os.clock()
	if now - (lastOrderTime[player] or 0) < ORDER_COOLDOWN then
		return nil
	end
	lastOrderTime[player] = now
	return trenchIndex
end

advanceRemote.OnServerEvent:Connect(function(player: Player, trenchIndex: unknown)
	local index = acceptTrenchOrder(player, trenchIndex)
	if index then
		orderTrench(PLAYER_TEAM, index, false, 0)
	end
end)

retreatRemote.OnServerEvent:Connect(function(player: Player, trenchIndex: unknown)
	local index = acceptTrenchOrder(player, trenchIndex)
	if index then
		orderTrench(PLAYER_TEAM, index, true, 0)
	end
end)

chargeRemote.OnServerEvent:Connect(function(player: Player, trenchIndex: unknown)
	local index = acceptTrenchOrder(player, trenchIndex)
	if index then
		triggerCharge(PLAYER_TEAM, index)
	end
end)

buildRemote.OnServerEvent:Connect(function(player: Player, trenchIndex: unknown, fortType: unknown)
	if typeof(fortType) ~= "string" then
		return
	end
	local index = acceptTrenchOrder(player, trenchIndex)
	if index then
		startFortification(PLAYER_TEAM, index, fortType)
	end
end)

Players.PlayerRemoving:Connect(function(player: Player)
	lastDeployTime[player] = nil
	lastOrderTime[player] = nil
end)

-- NPC Enemy commander testing stage -------------------------------------------------------------

for trenchIndex = 1, GameConfig.TRENCH_COUNT do
	refreshTrench(trenchIndex)
	refreshFortificationAttributes(trenchIndex)
end

-- Timer-driven opponent: buys reinforcements whenever it can afford them (up
-- to a unit cap), and periodically pushes its most forward well-manned trench toward the Allies.
task.spawn(function()
	local sinceAdvance = 0
	while true do
		task.wait(GameConfig.ENEMY_SPAWN_INTERVAL)
		if countTeam("Enemies") < GameConfig.ENEMY_MAX_UNITS then
			spawnUnit("Enemies", GameConfig.ENEMY_UNIT_TYPE)
		end

		sinceAdvance += GameConfig.ENEMY_SPAWN_INTERVAL
		if sinceAdvance >= GameConfig.ENEMY_ADVANCE_INTERVAL then
			sinceAdvance = 0
			-- Trench 1 is the Allied side, so low indices are the enemy's front.
			for trenchIndex = 2, GameConfig.TRENCH_COUNT do
				if countUnits(trenchIndex, "Enemies") >= GameConfig.ENEMY_ADVANCE_MIN_UNITS then
					orderTrench("Enemies", trenchIndex, false, 0)
					break
				end
			end
		end
	end
end)
