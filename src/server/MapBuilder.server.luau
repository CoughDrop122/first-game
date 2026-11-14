--!strict
-- Procedurally builds the battlefield on server start: mud baseplate, raised
-- ground with trench cut-outs, sandbagged trenches and team spawn zones.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

local MUD_COLOR = Color3.fromRGB(92, 64, 44)
local TRENCH_FLOOR_COLOR = Color3.fromRGB(62, 44, 32)
local SANDBAG_COLOR = Color3.fromRGB(196, 174, 128)
local ALLIES_COLOR = Color3.fromRGB(60, 110, 200)
local ENEMIES_COLOR = Color3.fromRGB(190, 60, 60)

local TRENCH_FLOOR_THICKNESS = 1
local BASEPLATE_THICKNESS = 4
local SANDBAG_GAP = 0.2 -- visual gap between neighbouring sandbag segments

local halfMapX = GameConfig.MAP_SIZE_X / 2
local halfMapZ = GameConfig.MAP_SIZE_Z / 2
local halfTrenchWidth = GameConfig.TRENCH_WIDTH / 2
local halfTrenchLength = GameConfig.TRENCH_LENGTH / 2

-- The baseplate's top surface lies under the trench floors; raised ground
-- slabs fill everything that is not a trench up to GROUND_Y.
local baseplateTopY = GameConfig.TRENCH_FLOOR_Y - TRENCH_FLOOR_THICKNESS

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

-- Ground slab spanning the given X/Z bounds, from the baseplate up to GROUND_Y.
local function makeGroundSlab(name: string, minX: number, maxX: number, minZ: number, maxZ: number, parent: Instance)
	local height = GameConfig.GROUND_Y - baseplateTopY
	makePart({
		Name = name,
		Size = Vector3.new(maxX - minX, height, maxZ - minZ),
		Position = Vector3.new((minX + maxX) / 2, baseplateTopY + height / 2, (minZ + maxZ) / 2),
		Color = MUD_COLOR,
		Material = Enum.Material.Ground,
	}, parent)
end

local function buildBattlefield(): Folder
	local battlefield = Instance.new("Folder")
	battlefield.Name = "Battlefield"

	makePart({
		Name = "Baseplate",
		Size = Vector3.new(GameConfig.MAP_SIZE_X, BASEPLATE_THICKNESS, GameConfig.MAP_SIZE_Z),
		Position = Vector3.new(0, baseplateTopY - BASEPLATE_THICKNESS / 2, 0),
		Color = MUD_COLOR,
		Material = Enum.Material.Slate,
		Locked = true,
	}, battlefield)

	-- Full-depth slabs for every strip of ground between (and outside) trenches.
	local stripStartX = -halfMapX
	for trenchIndex = 1, GameConfig.TRENCH_COUNT do
		local trenchX = GameConfig.GetTrenchCenterX(trenchIndex)
		makeGroundSlab(`Ground_{trenchIndex}`, stripStartX, trenchX - halfTrenchWidth, -halfMapZ, halfMapZ, battlefield)
		stripStartX = trenchX + halfTrenchWidth

		-- Caps closing off both ends of the trench.
		makeGroundSlab(`TrenchCap_{trenchIndex}_A`, trenchX - halfTrenchWidth, trenchX + halfTrenchWidth, -halfMapZ, -halfTrenchLength, battlefield)
		makeGroundSlab(`TrenchCap_{trenchIndex}_B`, trenchX - halfTrenchWidth, trenchX + halfTrenchWidth, halfTrenchLength, halfMapZ, battlefield)
	end
	makeGroundSlab(`Ground_{GameConfig.TRENCH_COUNT + 1}`, stripStartX, halfMapX, -halfMapZ, halfMapZ, battlefield)

	battlefield.Parent = Workspace
	return battlefield
end

local function buildTrench(trenchIndex: number, parent: Instance)
	local trenchX = GameConfig.GetTrenchCenterX(trenchIndex)

	local trench = Instance.new("Model")
	trench.Name = `Trench_{trenchIndex}`
	trench:SetAttribute("TrenchIndex", trenchIndex)
	trench:SetAttribute("Owner", GameConfig.GetInitialOwner(trenchIndex))

	local floor = makePart({
		Name = "Floor",
		Size = Vector3.new(GameConfig.TRENCH_WIDTH, TRENCH_FLOOR_THICKNESS, GameConfig.TRENCH_LENGTH),
		Position = Vector3.new(trenchX, GameConfig.TRENCH_FLOOR_Y - TRENCH_FLOOR_THICKNESS / 2, 0),
		Color = TRENCH_FLOOR_COLOR,
		Material = Enum.Material.Ground,
	}, trench)
	trench.PrimaryPart = floor

	-- One sandbag segment per slot on each side, sitting on the trench lip.
	local slotLength = GameConfig.TRENCH_LENGTH / GameConfig.SLOTS_PER_TRENCH
	local wallOffsetX = halfTrenchWidth + GameConfig.SANDBAG_THICKNESS / 2
	local wallY = GameConfig.GROUND_Y + GameConfig.SANDBAG_HEIGHT / 2

	for _, side in { { name = "West", sign = -1 }, { name = "East", sign = 1 } } do
		local wall = Instance.new("Folder")
		wall.Name = `Sandbags{side.name}`
		for slotIndex = 1, GameConfig.SLOTS_PER_TRENCH do
			local slotPosition = GameConfig.GetSlotWorldPosition(trenchIndex, slotIndex)
			makePart({
				Name = `Sandbag_{slotIndex}`,
				Size = Vector3.new(GameConfig.SANDBAG_THICKNESS, GameConfig.SANDBAG_HEIGHT, slotLength - SANDBAG_GAP),
				Position = Vector3.new(trenchX + side.sign * wallOffsetX, wallY, slotPosition.Z),
				Color = SANDBAG_COLOR,
				Material = Enum.Material.Sand,
			}, wall)
		end
		wall.Parent = trench
	end

	trench.Parent = parent
end

local function buildSpawnZone(owner: "Allies" | "Enemies", color: Color3, parent: Instance): Part
	local zone = makePart({
		Name = `{owner}SpawnZone`,
		Size = Vector3.new(GameConfig.SPAWN_ZONE_WIDTH, 0.2, GameConfig.MAP_SIZE_Z),
		Position = Vector3.new(GameConfig.GetSpawnZoneCenterX(owner), GameConfig.GROUND_Y + 0.1, 0),
		Color = color,
		Material = Enum.Material.SmoothPlastic,
		Transparency = 1, -- invisible; kept as a marker of the zone's bounds
		CanCollide = false,
	}, parent)
	zone:SetAttribute("Owner", owner)
	return zone
end

-- The Rojo project template ships a flat grey Baseplate whose surface sits at
-- GROUND_Y; left in place it would fill every trench.
local templateBaseplate = Workspace:FindFirstChild("Baseplate")
if templateBaseplate then
	templateBaseplate:Destroy()
end

buildBattlefield()

local trenches = Instance.new("Folder")
trenches.Name = "Trenches"
for trenchIndex = 1, GameConfig.TRENCH_COUNT do
	buildTrench(trenchIndex, trenches)
end
trenches.Parent = Workspace

local spawnZones = Instance.new("Folder")
spawnZones.Name = "SpawnZones"
buildSpawnZone("Allies", ALLIES_COLOR, spawnZones)
buildSpawnZone("Enemies", ENEMIES_COLOR, spawnZones)

-- Players spawn in the Allies zone, facing the front line (+X).
local spawnLocation = Instance.new("SpawnLocation")
spawnLocation.Name = "AlliesSpawn"
spawnLocation.Anchored = true
spawnLocation.Size = Vector3.new(12, 1, 12)
spawnLocation.Transparency = 1
spawnLocation.CanCollide = false
spawnLocation.CFrame = CFrame.lookAt(
	Vector3.new(GameConfig.GetSpawnZoneCenterX("Allies"), GameConfig.GROUND_Y + 0.5, 0),
	Vector3.new(0, GameConfig.GROUND_Y + 0.5, 0)
)
spawnLocation.Parent = spawnZones

spawnZones.Parent = Workspace
