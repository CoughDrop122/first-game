--!strict
-- Toggles between the standard third-person camera and a scripted tactical
-- camera that overlooks the battlefield and pans along the front line (X-axis).

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MapLoader = require(Shared:WaitForChild("MapLoader"))

local TOGGLE_ACTION = "ToggleTacticalCamera"
local PAN_ACTION = "TacticalCameraPan"
local RENDER_STEP_NAME = "TacticalCamera"

local TILT_DEGREES = 55 -- downward pitch of the tactical camera
local CAMERA_DISTANCE = 160 -- studs from the camera to its ground focus point
local PAN_SPEED = 90 -- studs per second for key / d-pad / thumbstick panning
local THUMBSTICK_DEADZONE = 0.2

local LABEL_STANDARD = "View: 3rd Person"
local LABEL_TACTICAL = "View: Tactical"

local player = Players.LocalPlayer :: Player
local playerGui = player:WaitForChild("PlayerGui")

local isTactical = false
local panX = 0 -- world X the tactical camera is centred on
local panLeftHeld = false
local panRightHeld = false
local thumbstickX = 0
local dragInput: InputObject? = nil
local lastDragPosition: Vector3? = nil

-- UI ---------------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "CameraToggleGui"
screenGui.ResetOnSpawn = false

local toggleButton = Instance.new("TextButton")
toggleButton.Name = "ToggleViewButton"
toggleButton.AnchorPoint = Vector2.new(0.5, 0)
toggleButton.Position = UDim2.fromScale(0.9, 0.05)
toggleButton.Size = UDim2.fromScale(0.16, 0.06)
toggleButton.TextScaled = true
toggleButton.Text = LABEL_STANDARD
toggleButton.Parent = screenGui

screenGui.Parent = playerGui

-- Character controls -----------------------------------------------------

-- Movement is suspended in tactical mode so the pan keys don't also walk the
-- character around.
local controls: any = nil
task.spawn(function()
	local playerModule = player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 10)
	if playerModule then
		local ok, result = pcall(function()
			return (require :: any)(playerModule):GetControls()
		end)
		if ok then
			controls = result
			if isTactical then
				controls:Disable()
			end
		end
	end
end)

-- Tactical camera --------------------------------------------------------

local function getTacticalCFrame(): CFrame
	local tilt = math.rad(TILT_DEGREES)
	local boundsMin, boundsMax = MapLoader.GetBounds()
	local focus = Vector3.new(panX, MapLoader.GetGroundY(), (boundsMin.Z + boundsMax.Z) / 2)
	-- Sit on the +Z side looking toward -Z so world +X is screen-right:
	-- Allies on the left, Enemies on the right.
	local offset = Vector3.new(0, math.sin(tilt), math.cos(tilt)) * CAMERA_DISTANCE
	return CFrame.lookAt(focus + offset, focus)
end

local function setPanX(x: number)
	local boundsMin, boundsMax = MapLoader.GetBounds()
	panX = math.clamp(x, boundsMin.X, boundsMax.X)
end

local function updateTacticalCamera(deltaTime: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	local direction = thumbstickX
	if panLeftHeld then
		direction -= 1
	end
	if panRightHeld then
		direction += 1
	end
	setPanX(panX + math.clamp(direction, -1, 1) * PAN_SPEED * deltaTime)

	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = getTacticalCFrame()
end

local function handlePan(_actionName: string, inputState: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	local keyCode = input.KeyCode
	if keyCode == Enum.KeyCode.Thumbstick1 then
		local x = if inputState == Enum.UserInputState.Change then input.Position.X else 0
		thumbstickX = if math.abs(x) > THUMBSTICK_DEADZONE then x else 0
		return Enum.ContextActionResult.Sink
	end

	local held = inputState == Enum.UserInputState.Begin
	if keyCode == Enum.KeyCode.A or keyCode == Enum.KeyCode.Left or keyCode == Enum.KeyCode.DPadLeft then
		panLeftHeld = held
	elseif keyCode == Enum.KeyCode.D or keyCode == Enum.KeyCode.Right or keyCode == Enum.KeyCode.DPadRight then
		panRightHeld = held
	end
	-- W / S / D-Pad up / down are bound only so they are swallowed here.
	return Enum.ContextActionResult.Sink
end

local function resetPanInput()
	panLeftHeld = false
	panRightHeld = false
	thumbstickX = 0
	dragInput = nil
	lastDragPosition = nil
end

-- Mode switching ---------------------------------------------------------

local function enterTactical()
	isTactical = true
	resetPanInput()
	if controls then
		controls:Disable()
	end

	ContextActionService:BindAction(
		PAN_ACTION,
		handlePan,
		false,
		Enum.KeyCode.W,
		Enum.KeyCode.A,
		Enum.KeyCode.S,
		Enum.KeyCode.D,
		Enum.KeyCode.Left,
		Enum.KeyCode.Right,
		Enum.KeyCode.DPadLeft,
		Enum.KeyCode.DPadRight,
		Enum.KeyCode.DPadUp,
		Enum.KeyCode.DPadDown,
		Enum.KeyCode.Thumbstick1
	)
	RunService:BindToRenderStep(RENDER_STEP_NAME, Enum.RenderPriority.Camera.Value + 1, updateTacticalCamera)
	toggleButton.Text = LABEL_TACTICAL
end

local function enterStandard()
	isTactical = false
	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	ContextActionService:UnbindAction(PAN_ACTION)
	resetPanInput()
	if controls then
		controls:Enable()
	end

	local camera = Workspace.CurrentCamera
	if camera then
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			camera.CameraSubject = humanoid
		end
		camera.CameraType = Enum.CameraType.Custom
	end
	toggleButton.Text = LABEL_STANDARD
end

local function toggleMode()
	if isTactical then
		enterStandard()
	else
		enterTactical()
	end
end

toggleButton.Activated:Connect(toggleMode)

ContextActionService:BindAction(TOGGLE_ACTION, function(_actionName: string, inputState: Enum.UserInputState)
	if inputState == Enum.UserInputState.Begin then
		toggleMode()
	end
	return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.V, Enum.KeyCode.ButtonY)

-- Drag panning (mouse or touch) -------------------------------------------

-- World studs covered by one screen pixel at the camera's focus distance.
local function getStudsPerPixel(): number
	local camera = Workspace.CurrentCamera
	if not camera or camera.ViewportSize.Y <= 0 then
		return 0
	end
	local visibleHeight = 2 * CAMERA_DISTANCE * math.tan(math.rad(camera.FieldOfView) / 2)
	return visibleHeight / camera.ViewportSize.Y
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if not isTactical or gameProcessed or dragInput then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragInput = input
		lastDragPosition = input.Position
	end
end)

UserInputService.InputChanged:Connect(function(input: InputObject)
	local activeDrag = dragInput
	local lastPosition = lastDragPosition
	if not isTactical or not activeDrag or not lastPosition then
		return
	end

	-- A touch reports movement on its own InputObject; a mouse drag reports it
	-- through separate MouseMovement inputs.
	local isTouchDrag = activeDrag.UserInputType == Enum.UserInputType.Touch and input == activeDrag
	local isMouseDrag = activeDrag.UserInputType == Enum.UserInputType.MouseButton1
		and input.UserInputType == Enum.UserInputType.MouseMovement
	if not (isTouchDrag or isMouseDrag) then
		return
	end

	-- Dragging right pulls the battlefield right, i.e. the camera moves left.
	local deltaX = input.Position.X - lastPosition.X
	setPanX(panX - deltaX * getStudsPerPixel())
	lastDragPosition = input.Position
end)

UserInputService.InputEnded:Connect(function(input: InputObject)
	if input == dragInput then
		dragInput = nil
		lastDragPosition = nil
	end
end)

-- Start in the standard third-person camera.
enterStandard()
