--!strict
-- Procedurally builds the lobby room players land in: a floor, low perimeter
-- walls and a spawn point. Assumes an empty Workspace.

local Workspace = game:GetService("Workspace")

local FLOOR_SIZE = 80 -- studs, square
local FLOOR_THICKNESS = 4
local WALL_HEIGHT = 6
local WALL_THICKNESS = 2

local FLOOR_COLOR = Color3.fromRGB(110, 104, 96)
local WALL_COLOR = Color3.fromRGB(92, 64, 44)

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

local lobby = Instance.new("Folder")
lobby.Name = "Lobby"

-- Floor surface sits at Y = 0.
makePart({
	Name = "Floor",
	Size = Vector3.new(FLOOR_SIZE, FLOOR_THICKNESS, FLOOR_SIZE),
	Position = Vector3.new(0, -FLOOR_THICKNESS / 2, 0),
	Color = FLOOR_COLOR,
	Material = Enum.Material.Slate,
}, lobby)

-- One wall along each edge of the floor.
local wallOffset = FLOOR_SIZE / 2 - WALL_THICKNESS / 2
local walls = {
	{ name = "WallNorth", position = Vector3.new(0, WALL_HEIGHT / 2, -wallOffset), alongX = true },
	{ name = "WallSouth", position = Vector3.new(0, WALL_HEIGHT / 2, wallOffset), alongX = true },
	{ name = "WallWest", position = Vector3.new(-wallOffset, WALL_HEIGHT / 2, 0), alongX = false },
	{ name = "WallEast", position = Vector3.new(wallOffset, WALL_HEIGHT / 2, 0), alongX = false },
}
for _, wall in walls do
	makePart({
		Name = wall.name,
		Size = if wall.alongX
			then Vector3.new(FLOOR_SIZE, WALL_HEIGHT, WALL_THICKNESS)
			else Vector3.new(WALL_THICKNESS, WALL_HEIGHT, FLOOR_SIZE),
		Position = wall.position,
		Color = WALL_COLOR,
		Material = Enum.Material.WoodPlanks,
	}, lobby)
end

local spawnLocation = Instance.new("SpawnLocation")
spawnLocation.Name = "LobbySpawn"
spawnLocation.Anchored = true
spawnLocation.Size = Vector3.new(12, 1, 12)
spawnLocation.Position = Vector3.new(0, 0.5, 0)
spawnLocation.TopSurface = Enum.SurfaceType.Smooth
spawnLocation.Parent = lobby

lobby.Parent = Workspace
