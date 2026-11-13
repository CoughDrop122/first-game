--!strict
-- Draws combat effects locally. The server only reports where shots went
-- (ShotsFired); the tracer parts exist on this client alone and are pooled so
-- large battles don't churn instances.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

local TRACER_COLOR = Color3.fromRGB(255, 220, 120)
local TRACER_LIFETIME = 0.12 -- seconds
local TRACER_THICKNESS = 0.06
local MAX_POOLED_TRACERS = 200

local remotes = ReplicatedStorage:WaitForChild(GameConfig.REMOTES_FOLDER)
local shotsRemote = remotes:WaitForChild(GameConfig.REMOTE_SHOTS_FIRED) :: UnreliableRemoteEvent

local effectsFolder = Instance.new("Folder")
effectsFolder.Name = "LocalEffects"
effectsFolder.Parent = Workspace

local tracerPool: { Part } = {}

local function acquireTracer(): Part
	local tracer = table.remove(tracerPool)
	if tracer then
		return tracer
	end

	local part = Instance.new("Part")
	part.Name = "Tracer"
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = TRACER_COLOR
	return part
end

local function releaseTracer(tracer: Part)
	tracer.Parent = nil
	if #tracerPool < MAX_POOLED_TRACERS then
		table.insert(tracerPool, tracer)
	else
		tracer:Destroy()
	end
end

local function showTracer(from: Vector3, to: Vector3)
	local length = (to - from).Magnitude
	if length < 0.01 then
		return
	end

	local tracer = acquireTracer()
	tracer.Size = Vector3.new(TRACER_THICKNESS, TRACER_THICKNESS, length)
	tracer.CFrame = CFrame.lookAt((from + to) / 2, to)
	tracer.Parent = effectsFolder
	task.delay(TRACER_LIFETIME, releaseTracer, tracer)
end

-- `shots` is a flat array of Vector3s: muzzle, impact, muzzle, impact, ...
shotsRemote.OnClientEvent:Connect(function(shots: unknown)
	if typeof(shots) ~= "table" then
		return
	end
	local points = shots :: { unknown }
	for index = 1, #points - 1, 2 do
		local from = points[index]
		local to = points[index + 1]
		if typeof(from) == "Vector3" and typeof(to) == "Vector3" then
			showTracer(from, to)
		end
	end
end)
