--!strict
-- Milestone 2: spawns miniature units, tracks which trench slot each one is
-- assigned to, and marches them between slots. No combat or economy.
--
-- Trench Models carry replicated attributes the client UI reads:
--   AlliesCount / EnemiesCount : units currently assigned to the trench
--   Owner                      : last team to move into the trench

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

type Team = GameConfig.Team

type Unit = {
	id: number,
	team: Team,
	model: Model,
	position: Vector3, -- feet position
	trenchIndex: number,
	slotIndex: number,
	arrived: boolean,
}

local ADVANCE_ORDER_COOLDOWN = 0.2 -- seconds between advance orders, per player

local TEAM_COLORS: { [Team]: Color3 } = {
	Allies = Color3.fromRGB(50, 90, 170),
	Enemies = Color3.fromRGB(160, 50, 50),
}
local SKIN_COLOR = Color3.fromRGB(224, 184, 150)
local RIFLE_COLOR = Color3.fromRGB(60, 42, 28)

-- A player character is roughly 2 x 5 x 1 studs.
local scale = GameConfig.MINIATURE_SCALE
local BODY_SIZE = Vector3.new(2, 3.8, 1) * scale
local HEAD_DIAMETER = 1.2 * scale
local RIFLE_SIZE = Vector3.new(0.25, 0.25, 2.6) * scale

local TEAM_FACING: { [Team]: Vector3 } = {
	Allies = Vector3.xAxis,
	Enemies = -Vector3.xAxis,
}

-- World setup ---------------------------------------------------------------

local trenchesFolder = Workspace:WaitForChild("Trenches")
local trenchModels: { Model } = {}
for trenchIndex = 1, GameConfig.TRENCH_COUNT do
	trenchModels[trenchIndex] = trenchesFolder:WaitForChild(`Trench_{trenchIndex}`) :: Model
end

local unitsFolder = Instance.new("Folder")
unitsFolder.Name = "Units"
unitsFolder.Parent = Workspace

local remotes = Instance.new("Folder")
remotes.Name = GameConfig.REMOTES_FOLDER

local deployRemote = Instance.new("RemoteEvent")
deployRemote.Name = GameConfig.REMOTE_DEPLOY_UNIT
deployRemote.Parent = remotes

local advanceRemote = Instance.new("RemoteEvent")
advanceRemote.Name = GameConfig.REMOTE_ADVANCE_TRENCH
advanceRemote.Parent = remotes

remotes.Parent = ReplicatedStorage

-- State -----------------------------------------------------------------------

local units: { Unit } = {}
local nextUnitId = 1

-- slots[trenchIndex][slotIndex] = the unit assigned there (arrived or en route).
local slots: { { [number]: Unit } } = {}
for trenchIndex = 1, GameConfig.TRENCH_COUNT do
	slots[trenchIndex] = {}
end

local function countUnits(trenchIndex: number, team: Team): number
	local count = 0
	for _, unit in slots[trenchIndex] do
		if unit.team == team then
			count += 1
		end
	end
	return count
end

local function refreshTrenchCounts(trenchIndex: number)
	local trench = trenchModels[trenchIndex]
	trench:SetAttribute("AlliesCount", countUnits(trenchIndex, "Allies"))
	trench:SetAttribute("EnemiesCount", countUnits(trenchIndex, "Enemies"))
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

local function assignSlot(unit: Unit, trenchIndex: number, slotIndex: number)
	local previousTrench = unit.trenchIndex
	if slots[previousTrench][unit.slotIndex] == unit then
		slots[previousTrench][unit.slotIndex] = nil
	end

	slots[trenchIndex][slotIndex] = unit
	unit.trenchIndex = trenchIndex
	unit.slotIndex = slotIndex
	unit.arrived = false
	unit.model:SetAttribute("TrenchIndex", trenchIndex)
	unit.model:SetAttribute("SlotIndex", slotIndex)

	refreshTrenchCounts(previousTrench)
	refreshTrenchCounts(trenchIndex)
end

-- Units -----------------------------------------------------------------------

local function makeUnitPart(props: { [string]: any }, parent: Instance): Part
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

-- Builds a soldier standing at the origin facing -Z, pivoting at its feet.
local function buildUnitModel(team: Team, id: number): Model
	local model = Instance.new("Model")
	model.Name = `{team}Unit_{id}`

	local body = makeUnitPart({
		Name = "Body",
		Size = BODY_SIZE,
		Position = Vector3.new(0, BODY_SIZE.Y / 2, 0),
		Color = TEAM_COLORS[team],
	}, model)
	body.PivotOffset = CFrame.new(0, -BODY_SIZE.Y / 2, 0)
	model.PrimaryPart = body

	makeUnitPart({
		Name = "Head",
		Shape = Enum.PartType.Ball,
		Size = Vector3.one * HEAD_DIAMETER,
		Position = Vector3.new(0, BODY_SIZE.Y + HEAD_DIAMETER / 2, 0),
		Color = SKIN_COLOR,
	}, model)

	makeUnitPart({
		Name = "Rifle",
		Size = RIFLE_SIZE,
		Position = Vector3.new(BODY_SIZE.X / 2, BODY_SIZE.Y * 0.7, -RIFLE_SIZE.Z / 4),
		Color = RIFLE_COLOR,
	}, model)

	model:SetAttribute("Team", team)
	model:SetAttribute("UnitId", id)
	return model
end

local function placeUnit(unit: Unit, facing: Vector3)
	unit.model:PivotTo(CFrame.lookAt(unit.position, unit.position + facing))
end

-- Spawns a unit in its team's spawn zone and sends it to a free slot in the
-- home trench. Returns nil if the home trench has no free slot.
local function spawnUnit(team: Team): Unit?
	local homeTrench = GameConfig.GetHomeTrenchIndex(team)
	local slotIndex = findFreeSlot(homeTrench, math.random(1, GameConfig.SLOTS_PER_TRENCH))
	if not slotIndex then
		return nil
	end

	local id = nextUnitId
	nextUnitId += 1

	-- Start level with the destination slot so the unit marches straight in.
	local slotPosition = GameConfig.GetSlotWorldPosition(homeTrench, slotIndex)
	local unit: Unit = {
		id = id,
		team = team,
		model = buildUnitModel(team, id),
		position = Vector3.new(GameConfig.GetSpawnZoneCenterX(team), GameConfig.GROUND_Y, slotPosition.Z),
		trenchIndex = homeTrench,
		slotIndex = slotIndex,
		arrived = false,
	}
	assignSlot(unit, homeTrench, slotIndex)
	placeUnit(unit, TEAM_FACING[team])
	unit.model.Parent = unitsFolder
	table.insert(units, unit)
	return unit
end

-- Orders every unit of `team` assigned to the trench to move to the next trench
-- toward the other side. Units that don't fit stay behind.
local function advanceTrench(team: Team, trenchIndex: number)
	local targetTrench = trenchIndex + GameConfig.GetAdvanceDirection(team)
	if targetTrench < 1 or targetTrench > GameConfig.TRENCH_COUNT then
		return
	end

	-- Without combat, a trench held by the other side can't be entered.
	local otherTeam: Team = if team == "Allies" then "Enemies" else "Allies"
	if countUnits(targetTrench, otherTeam) > 0 then
		return
	end

	local movers: { Unit } = {}
	for _, unit in slots[trenchIndex] do
		if unit.team == team then
			table.insert(movers, unit)
		end
	end

	for _, unit in movers do
		local slotIndex = findFreeSlot(targetTrench, unit.slotIndex)
		if not slotIndex then
			break
		end
		assignSlot(unit, targetTrench, slotIndex)
	end
end

-- Movement --------------------------------------------------------------------

RunService.Heartbeat:Connect(function(deltaTime: number)
	local step = GameConfig.UNIT_WALK_SPEED * deltaTime
	for _, unit in units do
		if unit.arrived then
			continue
		end

		local target = GameConfig.GetSlotWorldPosition(unit.trenchIndex, unit.slotIndex)
		local toTarget = Vector3.new(target.X - unit.position.X, 0, target.Z - unit.position.Z)
		local distance = toTarget.Magnitude

		if distance <= step then
			-- Drop into the slot and face the enemy.
			unit.position = target
			unit.arrived = true
			placeUnit(unit, TEAM_FACING[unit.team])
			trenchModels[unit.trenchIndex]:SetAttribute("Owner", unit.team)
		else
			-- March across open ground toward the slot.
			local direction = toTarget / distance
			local moved = unit.position + direction * step
			unit.position = Vector3.new(moved.X, GameConfig.GROUND_Y, moved.Z)
			placeUnit(unit, direction)
		end
	end
end)

-- Player orders ---------------------------------------------------------------

-- All players command the Allies for now.
local PLAYER_TEAM: Team = "Allies"

local lastDeployTime: { [Player]: number } = {}
local lastAdvanceTime: { [Player]: number } = {}

deployRemote.OnServerEvent:Connect(function(player: Player)
	local now = os.clock()
	if now - (lastDeployTime[player] or 0) < GameConfig.DEPLOY_COOLDOWN then
		return
	end
	lastDeployTime[player] = now
	spawnUnit(PLAYER_TEAM)
end)

advanceRemote.OnServerEvent:Connect(function(player: Player, trenchIndex: unknown)
	if typeof(trenchIndex) ~= "number" or trenchIndex % 1 ~= 0 then
		return
	end
	if trenchIndex < 1 or trenchIndex > GameConfig.TRENCH_COUNT then
		return
	end

	local now = os.clock()
	if now - (lastAdvanceTime[player] or 0) < ADVANCE_ORDER_COOLDOWN then
		return
	end
	lastAdvanceTime[player] = now
	advanceTrench(PLAYER_TEAM, trenchIndex)
end)

Players.PlayerRemoving:Connect(function(player: Player)
	lastDeployTime[player] = nil
	lastAdvanceTime[player] = nil
end)

-- Enemy garrison --------------------------------------------------------------

for trenchIndex = 1, GameConfig.TRENCH_COUNT do
	refreshTrenchCounts(trenchIndex)
end

-- Placeholder until enemy AI exists: the enemy trickles a small garrison into
-- its home trench and holds there.
task.spawn(function()
	local spawned = 0
	while spawned < GameConfig.ENEMY_MAX_UNITS do
		task.wait(GameConfig.ENEMY_SPAWN_INTERVAL)
		if spawnUnit("Enemies") then
			spawned += 1
		end
	end
end)
