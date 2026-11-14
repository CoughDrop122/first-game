--!strict
-- Gets the battle map ready on server start.
--
-- If the place already contains Workspace.CurrentMap (a map built in Studio),
-- that map is used as it is. Otherwise this script generates the default
-- diorama described by GameConfig.DefaultMap: mud baseplate, raised ground
-- with trench cut-outs, sandbagged trenches and team spawn zones.
--
-- Either way the map is then handed to Shared.MapLoader, which is what the
-- rest of the game reads. See MapLoader for the map contract.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local MapLoader = require(Shared:WaitForChild("MapLoader"))

local MUD_COLOR = Color3.fromRGB(92, 64, 44)
local TRENCH_FLOOR_COLOR = Color3.fromRGB(62, 44, 32)
local SANDBAG_COLOR = Color3.fromRGB(196, 174, 128)

local TRENCH_FLOOR_THICKNESS = 1
local BASEPLATE_THICKNESS = 4
local SANDBAG_GAP = 0.2 -- visual gap between neighbouring sandbag segments

local layout = GameConfig.DefaultMap
local groundY = GameConfig.GROUND_Y
local trenchFloorY = groundY - layout.TrenchDepth

-- Outer trenches sit one TrenchSpacing away from their spawn zone.
local mapSizeX = (layout.TrenchCount + 1) * layout.TrenchSpacing + 2 * layout.SpawnZoneWidth
local mapSizeZ = layout.TrenchLength + 2 * layout.MarginZ
local halfMapX = mapSizeX / 2
local halfMapZ = mapSizeZ / 2
local halfTrenchWidth = layout.TrenchWidth / 2
local halfTrenchLength = layout.TrenchLength / 2

-- The baseplate's top surface lies under the trench floors; raised ground
-- slabs fill everything that is not a trench up to groundY.
local baseplateTopY = trenchFloorY - TRENCH_FLOOR_THICKNESS

-- World X of a trench's centre line. Trench 1 is nearest the Allies (-X).
local function getTrenchCenterX(trenchIndex: number): number
	return (trenchIndex - (layout.TrenchCount + 1) / 2) * layout.TrenchSpacing
end

-- World X of the centre of a team's spawn zone.
local function getSpawnZoneCenterX(owner: GameConfig.Team): number
	local x = (mapSizeX - layout.SpawnZoneWidth) / 2
	return if owner == "Allies" then -x else x
end

-- Each side starts holding the trench nearest its spawn zone.
local function getInitialOwner(trenchIndex: number): GameConfig.Owner
	if trenchIndex == 1 then
		return "Allies"
	elseif trenchIndex == layout.TrenchCount then
		return "Enemies"
	end
	return "Neutral"
end

local function makePart(props: { [string]: any }, parent: Instance): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		(part :: any)[key] = value
	end
	part.Parent = parent
	return part
end

-- Ground slab spanning the given X/Z bounds, from the baseplate up to groundY.
local function makeGroundSlab(name: string, minX: number, maxX: number, minZ: number, maxZ: number, parent: Instance)
	local height = groundY - baseplateTopY
	makePart({
		Name = name,
		Size = Vector3.new(maxX - minX, height, maxZ - minZ),
		Position = Vector3.new((minX + maxX) / 2, baseplateTopY + height / 2, (minZ + maxZ) / 2),
		Color = MUD_COLOR,
		Material = Enum.Material.Ground,
	}, parent)
end

local function buildBattlefield(parent: Instance)
	local battlefield = Instance.new("Folder")
	battlefield.Name = "Battlefield"

	makePart({
		Name = "Baseplate",
		Size = Vector3.new(mapSizeX, BASEPLATE_THICKNESS, mapSizeZ),
		Position = Vector3.new(0, baseplateTopY - BASEPLATE_THICKNESS / 2, 0),
		Color = MUD_COLOR,
		Material = Enum.Material.Slate,
		Locked = true,
	}, battlefield)

	-- Full-depth slabs for every strip of ground between (and outside) trenches.
	local stripStartX = -halfMapX
	for trenchIndex = 1, layout.TrenchCount do
		local trenchX = getTrenchCenterX(trenchIndex)
		makeGroundSlab(`Ground_{trenchIndex}`, stripStartX, trenchX - halfTrenchWidth, -halfMapZ, halfMapZ, battlefield)
		stripStartX = trenchX + halfTrenchWidth

		-- Caps closing off both ends of the trench.
		makeGroundSlab(`TrenchCap_{trenchIndex}_A`, trenchX - halfTrenchWidth, trenchX + halfTrenchWidth, -halfMapZ, -halfTrenchLength, battlefield)
		makeGroundSlab(`TrenchCap_{trenchIndex}_B`, trenchX - halfTrenchWidth, trenchX + halfTrenchWidth, halfTrenchLength, halfMapZ, battlefield)
	end
	makeGroundSlab(`Ground_{layout.TrenchCount + 1}`, stripStartX, halfMapX, -halfMapZ, halfMapZ, battlefield)

	battlefield.Parent = parent
end

local function buildTrench(trenchIndex: number, parent: Instance)
	local trenchX = getTrenchCenterX(trenchIndex)

	local trench = Instance.new("Model")
	trench.Name = `Trench_{trenchIndex}`
	trench:SetAttribute("TrenchIndex", trenchIndex)
	trench:SetAttribute("InitialOwner", getInitialOwner(trenchIndex))
	trench:SetAttribute("SlotCount", layout.SlotsPerTrench)

	local floor = makePart({
		Name = MapLoader.FLOOR_PART,
		Size = Vector3.new(layout.TrenchWidth, TRENCH_FLOOR_THICKNESS, layout.TrenchLength),
		Position = Vector3.new(trenchX, trenchFloorY - TRENCH_FLOOR_THICKNESS / 2, 0),
		Color = TRENCH_FLOOR_COLOR,
		Material = Enum.Material.Ground,
	}, trench)
	trench.PrimaryPart = floor

	-- One sandbag segment per slot on each side, sitting on the trench lip.
	local slotLength = layout.TrenchLength / layout.SlotsPerTrench
	local wallOffsetX = halfTrenchWidth + GameConfig.SANDBAG_THICKNESS / 2
	local wallY = groundY + GameConfig.SANDBAG_HEIGHT / 2

	for _, side in { { name = "West", sign = -1 }, { name = "East", sign = 1 } } do
		local wall = Instance.new("Folder")
		wall.Name = `Sandbags{side.name}`
		for slotIndex = 1, layout.SlotsPerTrench do
			makePart({
				Name = `Sandbag_{slotIndex}`,
				Size = Vector3.new(GameConfig.SANDBAG_THICKNESS, GameConfig.SANDBAG_HEIGHT, slotLength - SANDBAG_GAP),
				Position = Vector3.new(trenchX + side.sign * wallOffsetX, wallY, -halfTrenchLength + (slotIndex - 0.5) * slotLength),
				Color = SANDBAG_COLOR,
				Material = Enum.Material.Sand,
			}, wall)
		end
		wall.Parent = trench
	end

	trench.Parent = parent
end

-- Invisible marker of where a team's units appear.
local function buildSpawnZone(owner: GameConfig.Team, parent: Instance)
	local zone = makePart({
		Name = `{owner}SpawnZone`,
		Size = Vector3.new(layout.SpawnZoneWidth, 0.2, mapSizeZ),
		Position = Vector3.new(getSpawnZoneCenterX(owner), groundY + 0.1, 0),
		Transparency = 1,
		CanCollide = false,
	}, parent)
	zone:SetAttribute("Owner", owner)
end

local function buildDefaultMap()
	-- Older builds of the Rojo project shipped a flat grey Baseplate whose
	-- surface sits at ground level; left in place it would fill every trench.
	local templateBaseplate = Workspace:FindFirstChild("Baseplate")
	if templateBaseplate then
		templateBaseplate:Destroy()
	end

	local map = Instance.new("Folder")
	map.Name = MapLoader.MAP_NAME
	map:SetAttribute("GroundY", groundY)

	buildBattlefield(map)

	local trenches = Instance.new("Folder")
	trenches.Name = MapLoader.TRENCHES_FOLDER
	for trenchIndex = 1, layout.TrenchCount do
		buildTrench(trenchIndex, trenches)
	end
	trenches.Parent = map

	local spawnZones = Instance.new("Folder")
	spawnZones.Name = MapLoader.SPAWN_ZONES_FOLDER
	buildSpawnZone("Allies", spawnZones)
	buildSpawnZone("Enemies", spawnZones)

	-- Players spawn in the Allies zone, facing the front line (+X).
	local spawnLocation = Instance.new("SpawnLocation")
	spawnLocation.Name = "AlliesSpawn"
	spawnLocation.Anchored = true
	spawnLocation.Size = Vector3.new(12, 1, 12)
	spawnLocation.Transparency = 1
	spawnLocation.CanCollide = false
	spawnLocation.CFrame = CFrame.lookAt(
		Vector3.new(getSpawnZoneCenterX("Allies"), groundY + 0.5, 0),
		Vector3.new(0, groundY + 0.5, 0)
	)
	spawnLocation.Parent = spawnZones
	spawnZones.Parent = map

	makePart({
		Name = MapLoader.BOUNDS_PART,
		Size = Vector3.new(mapSizeX, 1, mapSizeZ),
		Position = Vector3.new(0, groundY, 0),
		Transparency = 1,
		CanCollide = false,
	}, map)

	map.Parent = Workspace
end

if not Workspace:FindFirstChild(MapLoader.MAP_NAME) then
	buildDefaultMap()
end

MapLoader.Load()
