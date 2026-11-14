--!strict
-- The battle map, as the rest of the game sees it. Everything that needs to
-- know where a trench is, how many slots it has, which trench is next, or
-- where a team spawns asks this module instead of doing layout maths.
--
-- The map is whatever is in Workspace.CurrentMap when the server starts: build
-- one in Studio, or leave it out and MapBuilder generates the default one.
--
-- Map contract
--   Workspace.CurrentMap (Folder or Model)
--     GroundY : number (optional)   height of the open ground units walk on;
--         defaults to GameConfig.GROUND_Y
--     Trenches (Folder)
--       <any name> (Model), one per trench
--         TrenchIndex : number    position in the chain. The lowest index is
--             the Allies' home trench, the highest is the Enemies' home, and
--             advancing moves to the next index up (Allies) or down (Enemies).
--             Indices must be unique; gaps are fine.
--         InitialOwner : "Allies" | "Enemies" | "Neutral"   owner at match start
--         SlotCount : number      how many soldiers the trench holds
--         Floor (BasePart)        soldiers stand on its top face. Its longer
--             horizontal side is the trench's length; slots are spread evenly
--             along it, so the trench can sit anywhere, at any angle and size.
--     SpawnZones (Folder)
--       BaseParts with an Owner attribute ("Allies" / "Enemies"): units of that
--       team appear at the part's position.
--     Bounds (BasePart, optional)   box the tactical camera stays inside. Made
--         invisible on load. Without it, the box is measured from the trenches
--         and spawn zones.
--
-- MapLoader.Load (server) checks the map, warns about anything missing, and
-- writes: Owner on each trench (current owner, match state), and MapReady,
-- BoundsMin, BoundsMax on CurrentMap.
--
-- Clients only rely on attributes (ids, counts, bounds); the geometry
-- functions read the Floor parts and are used by the server.
--
-- Current limits: trenches form a single chain, the open ground is flat, and
-- moving a Floor after Load is not noticed until Load is called again.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(script.Parent:WaitForChild("GameConfig"))

type Team = GameConfig.Team
type Owner = GameConfig.Owner

local MapLoader = {}

MapLoader.MAP_NAME = "CurrentMap"
MapLoader.TRENCHES_FOLDER = "Trenches"
MapLoader.SPAWN_ZONES_FOLDER = "SpawnZones"
MapLoader.BOUNDS_PART = "Bounds"
MapLoader.FLOOR_PART = "Floor"

-- Attributes whose change alters the shape of the map (as opposed to match
-- state such as Owner or unit counts).
local STRUCTURAL_ATTRIBUTES = { "TrenchIndex", "SlotCount" }

-- How far behind its home trench a team's units appear when the map has no
-- spawn zone for it.
local SPAWN_FALLBACK_DISTANCE = 30

type Layout = {
	center: Vector3, -- centre of the floor's top face
	enemyDirection: Vector3, -- horizontal, across the trench, toward the Enemies' side
	halfLength: number,
	halfWidth: number,
	slots: { CFrame },
}

local changedEvent = Instance.new("BindableEvent")
-- Fires (deferred, at most once per frame) when trenches are added or removed
-- or a structural attribute changes. Listeners should re-read what they cached.
MapLoader.Changed = changedEvent.Event

-- Caches -----------------------------------------------------------------------

local mapRoot: Instance? = nil
local trenchesFolder: Instance? = nil
local connections: { RBXScriptConnection } = {}
local trenchById: { [number]: Model }? = nil
local orderedIds: { number }? = nil
local orderById: { [number]: number } = {}
local layoutCache: { [number]: Layout } = {}
local changePending = false

local function invalidate()
	trenchById = nil
	orderedIds = nil
	table.clear(orderById)
	table.clear(layoutCache)
	if not changePending then
		changePending = true
		task.defer(function()
			changePending = false
			changedEvent:Fire()
		end)
	end
end

local function watchTrench(trench: Instance)
	for _, attribute in STRUCTURAL_ATTRIBUTES do
		table.insert(connections, trench:GetAttributeChangedSignal(attribute):Connect(invalidate))
	end
end

local function getMap(): Instance?
	local current = mapRoot
	if current and current.Parent == Workspace then
		return current
	end

	-- First use, or the map was replaced: drop everything tied to the old one.
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	trenchesFolder = nil
	if current then
		mapRoot = nil
		invalidate()
	end

	local map = Workspace:FindFirstChild(MapLoader.MAP_NAME)
	if not map then
		return nil
	end
	mapRoot = map
	table.insert(connections, map.AttributeChanged:Connect(invalidate))
	return map
end

local function getTrenchesFolder(): Instance?
	local map = getMap()
	if not map then
		return nil
	end
	local current = trenchesFolder
	if current and current.Parent == map then
		return current
	end
	local folder = map:FindFirstChild(MapLoader.TRENCHES_FOLDER)
	if not folder then
		return nil
	end
	trenchesFolder = folder
	for _, child in folder:GetChildren() do
		watchTrench(child)
	end
	table.insert(
		connections,
		folder.ChildAdded:Connect(function(child: Instance)
			watchTrench(child)
			invalidate()
		end)
	)
	table.insert(connections, folder.ChildRemoved:Connect(invalidate))
	return folder
end

local function getIndex(): { [number]: Model }
	if trenchById then
		return trenchById
	end
	local index: { [number]: Model } = {}
	local folder = getTrenchesFolder()
	if not folder then
		return index -- not cached: nothing would invalidate it when the folder appears
	end
	for _, child in folder:GetChildren() do
		local id = child:GetAttribute("TrenchIndex")
		if child:IsA("Model") and typeof(id) == "number" and not index[id] then
			index[id] = child
		end
	end
	trenchById = index
	return index
end

local function getNumberAttribute(instance: Instance, attribute: string): number
	local value = instance:GetAttribute(attribute)
	return if typeof(value) == "number" then value else 0
end

local function flatten(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function horizontalUnit(vector: Vector3, fallback: Vector3): Vector3
	local flat = flatten(vector)
	return if flat.Magnitude < 0.001 then fallback else flat.Unit
end

-- Structure (attributes only; safe on clients) -----------------------------------

-- Yields until the map has been loaded. Call before first use.
function MapLoader.WaitUntilReady()
	local map = Workspace:WaitForChild(MapLoader.MAP_NAME)
	while map:GetAttribute("MapReady") ~= true do
		map:GetAttributeChangedSignal("MapReady"):Wait()
	end
	map:WaitForChild(MapLoader.TRENCHES_FOLDER)
end

-- Every trench id in chain order: from the Allies' home trench to the Enemies'.
function MapLoader.GetTrenchIds(): { number }
	if orderedIds then
		return orderedIds
	end
	local ordered: { number } = {}
	for trenchId in getIndex() do
		table.insert(ordered, trenchId)
	end
	table.sort(ordered)

	if trenchById then
		orderedIds = ordered
		table.clear(orderById)
		for order, trenchId in ordered do
			orderById[trenchId] = order
		end
	end
	return ordered
end

function MapLoader.GetTrenchCount(): number
	return #MapLoader.GetTrenchIds()
end

function MapLoader.HasTrench(trenchId: number): boolean
	return getIndex()[trenchId] ~= nil
end

function MapLoader.GetTrenchModel(trenchId: number): Model?
	return getIndex()[trenchId]
end

function MapLoader.GetSlotCount(trenchId: number): number
	local trench = getIndex()[trenchId]
	return if trench then math.max(math.floor(getNumberAttribute(trench, "SlotCount")), 0) else 0
end

-- +1 for the team that advances toward the Enemies side, -1 for the other.
-- Multiply MapLoader.GetEnemyDirection by it to get a team's forward direction.
function MapLoader.GetSideSign(team: Team): number
	return if team == "Allies" then 1 else -1
end

-- The trench `team` reaches from `trenchId` by advancing (or, with `retreat`,
-- by falling back), or nil if there is none.
function MapLoader.GetNeighbor(trenchId: number, team: Team, retreat: boolean): number?
	local ordered = MapLoader.GetTrenchIds()
	local order = orderById[trenchId]
	if not order then
		return nil
	end
	local towardEnemies = (team == "Allies") ~= retreat
	return ordered[order + (if towardEnemies then 1 else -1)]
end

-- A team's home trench: where its units deploy, and what the other team must
-- take to win. The Allies' is the first trench of the chain, the Enemies' the last.
function MapLoader.GetHomeTrenchId(team: Team): number?
	local ordered = MapLoader.GetTrenchIds()
	return if team == "Allies" then ordered[1] else ordered[#ordered]
end

-- The team whose home trench this is, if any.
function MapLoader.GetHomeTeam(trenchId: number): Team?
	local ordered = MapLoader.GetTrenchIds()
	if ordered[1] == trenchId then
		return "Allies"
	elseif #ordered > 1 and ordered[#ordered] == trenchId then
		return "Enemies"
	end
	return nil
end

function MapLoader.GetInitialOwner(trenchId: number): Owner
	local trench = getIndex()[trenchId]
	local owner = trench and trench:GetAttribute("InitialOwner")
	if owner == "Allies" then
		return "Allies"
	elseif owner == "Enemies" then
		return "Enemies"
	end
	return "Neutral"
end

-- Height of the open ground units walk on between trenches.
function MapLoader.GetGroundY(): number
	local map = getMap()
	local groundY = map and map:GetAttribute("GroundY")
	return if typeof(groundY) == "number" then groundY else GameConfig.GROUND_Y
end

-- Box the tactical camera stays inside.
function MapLoader.GetBounds(): (Vector3, Vector3)
	local map = getMap()
	local boundsMin = map and map:GetAttribute("BoundsMin")
	local boundsMax = map and map:GetAttribute("BoundsMax")
	if typeof(boundsMin) == "Vector3" and typeof(boundsMax) == "Vector3" then
		return boundsMin, boundsMax
	end
	return Vector3.zero, Vector3.zero
end

-- Geometry (reads the Floor parts; used by the server) -----------------------------

-- The box soldiers stand on: the trench's Floor, or the whole model's bounding
-- box if it has none.
local function getFloorBox(trench: Model): (CFrame, Vector3)
	local floor = trench:FindFirstChild(MapLoader.FLOOR_PART, true)
	if floor and floor:IsA("BasePart") then
		return floor.CFrame, floor.Size
	end
	return trench:GetBoundingBox()
end

local function computeCenter(trench: Model): Vector3
	local floorCFrame, floorSize = getFloorBox(trench)
	return floorCFrame * Vector3.new(0, floorSize.Y / 2, 0)
end

local function getSpawnZone(team: Team): BasePart?
	local map = getMap()
	local folder = map and map:FindFirstChild(MapLoader.SPAWN_ZONES_FOLDER)
	if folder then
		for _, child in folder:GetChildren() do
			if child:IsA("BasePart") and not child:IsA("SpawnLocation") and child:GetAttribute("Owner") == team then
				return child
			end
		end
	end
	return nil
end

-- Rough horizontal direction from the Allies' side to the Enemies' side at a
-- trench, from where its neighbours in the chain are.
local function getChainDirection(trenchId: number): Vector3
	local index = getIndex()
	local center = computeCenter(index[trenchId])
	local ahead = MapLoader.GetNeighbor(trenchId, "Allies", false)
	local behind = MapLoader.GetNeighbor(trenchId, "Allies", true)

	local from = if behind then computeCenter(index[behind]) else center
	local to = if ahead then computeCenter(index[ahead]) else center
	if not ahead and not behind then
		-- An isolated trench: fall back to the line between the spawn zones.
		local alliesZone, enemiesZone = getSpawnZone("Allies"), getSpawnZone("Enemies")
		if alliesZone and enemiesZone then
			from, to = alliesZone.Position, enemiesZone.Position
		end
	end
	return horizontalUnit(to - from, Vector3.xAxis)
end

local function getLayout(trenchId: number): Layout?
	local cached = layoutCache[trenchId]
	if cached then
		return cached
	end
	local trench = getIndex()[trenchId]
	if not trench then
		return nil
	end

	local floorCFrame, floorSize = getFloorBox(trench)
	local lengthIsX = floorSize.X >= floorSize.Z
	local length = if lengthIsX then floorSize.X else floorSize.Z
	local width = if lengthIsX then floorSize.Z else floorSize.X
	local along = horizontalUnit(if lengthIsX then floorCFrame.XVector else floorCFrame.ZVector, Vector3.zAxis)

	-- Units face straight out of the trench, on whichever side the enemy is.
	local enemyDirection = along:Cross(Vector3.yAxis)
	if enemyDirection:Dot(getChainDirection(trenchId)) < 0 then
		enemyDirection = -enemyDirection
	end

	-- Number the slots in the same sideways direction in every trench, however
	-- its Floor happens to be rotated, so a unit keeps its lane between trenches.
	local slotDirection = if along:Dot(enemyDirection:Cross(Vector3.yAxis)) >= 0 then 1 else -1

	local slotCount = MapLoader.GetSlotCount(trenchId)
	local slots: { CFrame } = table.create(slotCount)
	for slotIndex = 1, slotCount do
		local offset = slotDirection * (-length / 2 + (slotIndex - 0.5) * length / slotCount)
		local localPosition = if lengthIsX
			then Vector3.new(offset, floorSize.Y / 2, 0)
			else Vector3.new(0, floorSize.Y / 2, offset)
		slots[slotIndex] = floorCFrame * CFrame.new(localPosition)
	end

	local layout: Layout = {
		center = floorCFrame * Vector3.new(0, floorSize.Y / 2, 0),
		enemyDirection = enemyDirection,
		halfLength = length / 2,
		halfWidth = width / 2,
		slots = slots,
	}
	if trenchById then
		layoutCache[trenchId] = layout
	end
	return layout
end

-- Centre of the trench, on the surface soldiers stand on.
function MapLoader.GetTrenchCenter(trenchId: number): Vector3
	local layout = getLayout(trenchId)
	return if layout then layout.center else Vector3.zero
end

-- Where a soldier in the given slot stands (feet position), oriented like the
-- trench's Floor.
function MapLoader.GetSlotCFrame(trenchId: number, slotIndex: number): CFrame
	local layout = getLayout(trenchId)
	local slot = layout and layout.slots[slotIndex]
	assert(slot, `Trench {trenchId} has no slot {slotIndex}`)
	return slot
end

function MapLoader.GetSlotPosition(trenchId: number, slotIndex: number): Vector3
	return MapLoader.GetSlotCFrame(trenchId, slotIndex).Position
end

-- Like GetSlotPosition, but tolerant: an out-of-range slot is clamped, and a
-- trench with no slots gives its centre. Used to keep a unit in its "lane".
function MapLoader.GetLanePosition(trenchId: number, preferredSlot: number): Vector3
	local layout = getLayout(trenchId)
	if not layout then
		return Vector3.zero
	end
	if #layout.slots == 0 then
		return layout.center
	end
	return layout.slots[math.clamp(preferredSlot, 1, #layout.slots)].Position
end

-- Horizontal unit vector straight across the trench, pointing toward the
-- Enemies' side. Follows the Floor's rotation, so an angled trench has an
-- angled front.
function MapLoader.GetEnemyDirection(trenchId: number): Vector3
	local layout = getLayout(trenchId)
	return if layout then layout.enemyDirection else Vector3.xAxis
end

-- Horizontal direction a team's units face when settled in the trench.
function MapLoader.GetFacing(trenchId: number, team: Team): Vector3
	return MapLoader.GetEnemyDirection(trenchId) * MapLoader.GetSideSign(team)
end

-- Half the Floor's longer horizontal side.
function MapLoader.GetTrenchHalfLength(trenchId: number): number
	local layout = getLayout(trenchId)
	return if layout then layout.halfLength else 0
end

-- Half the Floor's shorter horizontal side.
function MapLoader.GetTrenchHalfWidth(trenchId: number): number
	local layout = getLayout(trenchId)
	return if layout then layout.halfWidth else 0
end

-- How far `position` is from the trench's centre line, measured straight
-- across the trench (ignores height and sideways offset).
function MapLoader.GetDistanceAlongAxis(trenchId: number, position: Vector3): number
	local offset = flatten(position - MapLoader.GetTrenchCenter(trenchId))
	return math.abs(offset:Dot(MapLoader.GetEnemyDirection(trenchId)))
end

-- Where a newly deployed unit of `team` appears: in its spawn zone, level with
-- the lane it will take in its home trench so it marches straight in.
function MapLoader.GetSpawnPosition(team: Team, homeTrenchId: number, preferredSlot: number): Vector3
	local center = MapLoader.GetTrenchCenter(homeTrenchId)
	local facing = MapLoader.GetFacing(homeTrenchId, team)

	local zone = getSpawnZone(team)
	local origin = if zone then zone.Position else center - facing * SPAWN_FALLBACK_DISTANCE

	-- Sideways offset of the lane from the trench centre.
	local laneOffset = flatten(MapLoader.GetLanePosition(homeTrenchId, preferredSlot) - center)
	laneOffset -= facing * laneOffset:Dot(facing)

	return Vector3.new(origin.X + laneOffset.X, MapLoader.GetGroundY(), origin.Z + laneOffset.Z)
end

-- Loading (server) -----------------------------------------------------------------

local function problem(message: string)
	warn(`[MapLoader] {message}`)
end

-- Checks Workspace.CurrentMap against the map contract, fills in what can be
-- defaulted (warning about each problem), resets every trench to its initial
-- owner, measures the bounds and marks the map ready. Call again after
-- changing the map's layout.
function MapLoader.Load()
	assert(RunService:IsServer(), "MapLoader.Load can only be called on the server")
	local map = getMap()
	assert(map, `Workspace.{MapLoader.MAP_NAME} must exist before loading the map`)

	local boundsMin = Vector3.one * math.huge
	local boundsMax = Vector3.one * -math.huge
	local function includeBox(boxCFrame: CFrame, size: Vector3)
		local half = size / 2
		for x = -1, 1, 2 do
			for y = -1, 1, 2 do
				for z = -1, 1, 2 do
					local corner = boxCFrame * Vector3.new(x * half.X, y * half.Y, z * half.Z)
					boundsMin = boundsMin:Min(corner)
					boundsMax = boundsMax:Max(corner)
				end
			end
		end
	end

	local seen: { [number]: boolean } = {}
	local trenchCount = 0
	local folder = getTrenchesFolder()
	if not folder then
		problem(`{map:GetFullName()} has no "{MapLoader.TRENCHES_FOLDER}" folder, so the map has no trenches.`)
	end
	for _, child in if folder then folder:GetChildren() else {} do
		local id = child:GetAttribute("TrenchIndex")
		if not child:IsA("Model") or typeof(id) ~= "number" then
			problem(`{child:GetFullName()} is ignored: a trench must be a Model with a number attribute TrenchIndex.`)
			continue
		end
		if seen[id] then
			problem(`{child:GetFullName()} is ignored: another trench already has TrenchIndex {id}.`)
			continue
		end
		seen[id] = true
		trenchCount += 1

		local floor = child:FindFirstChild(MapLoader.FLOOR_PART, true)
		if not (floor and floor:IsA("BasePart")) then
			problem(`{child:GetFullName()} has no "{MapLoader.FLOOR_PART}" part; using the model's bounding box instead.`)
		end
		local floorCFrame, floorSize = getFloorBox(child)
		includeBox(floorCFrame, floorSize)

		local slotCount = child:GetAttribute("SlotCount")
		if typeof(slotCount) ~= "number" or slotCount < 1 or slotCount % 1 ~= 0 then
			local length = math.max(floorSize.X, floorSize.Z)
			local derived = math.max(1, math.round(length / GameConfig.DEFAULT_SLOT_SPACING))
			problem(`{child:GetFullName()} needs a whole-number SlotCount of at least 1; using {derived} from its length.`)
			child:SetAttribute("SlotCount", derived)
		end

		local initialOwner = child:GetAttribute("InitialOwner")
		if initialOwner ~= "Allies" and initialOwner ~= "Enemies" and initialOwner ~= "Neutral" then
			problem(`{child:GetFullName()} needs InitialOwner "Allies", "Enemies" or "Neutral"; using "Neutral".`)
			initialOwner = "Neutral"
			child:SetAttribute("InitialOwner", initialOwner)
		end
		child:SetAttribute("Owner", initialOwner)
	end
	if trenchCount < 2 then
		problem(`The map has {trenchCount} usable trench(es); a match needs at least 2 (one home trench per team).`)
	end

	local spawnZones = map:FindFirstChild(MapLoader.SPAWN_ZONES_FOLDER)
	for _, team: Team in { "Allies", "Enemies" } :: { Team } do
		if not getSpawnZone(team) then
			problem(`No part with Owner = "{team}" in {MapLoader.MAP_NAME}.{MapLoader.SPAWN_ZONES_FOLDER}; {team} units will appear just behind their home trench.`)
		end
	end

	local bounds = map:FindFirstChild(MapLoader.BOUNDS_PART)
	if bounds and bounds:IsA("BasePart") then
		boundsMin = Vector3.one * math.huge
		boundsMax = Vector3.one * -math.huge
		includeBox(bounds.CFrame, bounds.Size)
		bounds.Transparency = 1
		bounds.CanCollide = false
		bounds.CanQuery = false
		bounds.CanTouch = false
	elseif spawnZones then
		for _, child in spawnZones:GetChildren() do
			if child:IsA("BasePart") then
				includeBox(child.CFrame, child.Size)
			end
		end
	end

	if boundsMin.X <= boundsMax.X then
		map:SetAttribute("BoundsMin", boundsMin)
		map:SetAttribute("BoundsMax", boundsMax)
	end
	invalidate()
	map:SetAttribute("MapReady", true)
end

return MapLoader
