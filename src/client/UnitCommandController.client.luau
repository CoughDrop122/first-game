--!strict
-- Command bar. Everything is driven by GameConfig (unit and fortification
-- registries), by Shared.MapLoader (which trenches exist and how they link),
-- and by state the server replicates as attributes on the trench Models and on
-- ReplicatedStorage.TeamState.
--
-- Layout:
--   Deploy row  : [ Supplies ] [ one button per unit type in GameConfig.Units ]
--   Trench row  : [ one button per trench on the map ]   <- pick a trench
--   Orders row  : [ Retreat ] [ Advance ] [ Charge ] [ one Build button per fortification ]
--                 (orders apply to the selected trench)

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local MapLoader = require(Shared:WaitForChild("MapLoader"))

local TEAM: GameConfig.Team = "Allies"
local OTHER_TEAM: GameConfig.Team = "Enemies"
local DEPLOY_ACTION = "DeployUnit"
local CELL_PADDING = 0.01 -- gap between buttons, as a fraction of the row width
local MAX_CELL_WIDTH = 0.19
local REFRESH_INTERVAL = 0.5 -- seconds; keeps cooldown countdowns ticking
local SELECTED_COLOR = Color3.fromRGB(255, 225, 140)

local player = Players.LocalPlayer :: Player
local playerGui = player:WaitForChild("PlayerGui")

local remotes = ReplicatedStorage:WaitForChild(GameConfig.REMOTES_FOLDER)
local deployRemote = remotes:WaitForChild(GameConfig.REMOTE_DEPLOY_UNIT) :: RemoteEvent
local advanceRemote = remotes:WaitForChild(GameConfig.REMOTE_ADVANCE_TRENCH) :: RemoteEvent
local retreatRemote = remotes:WaitForChild(GameConfig.REMOTE_RETREAT_TRENCH) :: RemoteEvent
local chargeRemote = remotes:WaitForChild(GameConfig.REMOTE_TRIGGER_CHARGE) :: RemoteEvent
local buildRemote = remotes:WaitForChild(GameConfig.REMOTE_BUILD_FORTIFICATION) :: RemoteEvent

local teamState = ReplicatedStorage:WaitForChild(GameConfig.TEAM_STATE_FOLDER)

MapLoader.WaitUntilReady()

local unitTypes = GameConfig.GetSortedKeys(GameConfig.Units)
local fortTypes = GameConfig.GetSortedKeys(GameConfig.Fortifications)

-- Id of the trench the orders row applies to, or nil if the map has none.
local selectedTrench: number? = MapLoader.GetHomeTrenchId(TEAM)

-- Replicated state ------------------------------------------------------------

local function getTeamNumber(attribute: string): number
	local value = teamState:GetAttribute(`{TEAM}{attribute}`)
	return if typeof(value) == "number" then value else 0
end

local function getTrenchNumber(trenchId: number, attribute: string): number
	local trench = MapLoader.GetTrenchModel(trenchId)
	local value = trench and trench:GetAttribute(attribute)
	return if typeof(value) == "number" then value else 0
end

local function getTrenchFlag(trenchId: number, attribute: string): boolean
	local trench = MapLoader.GetTrenchModel(trenchId)
	return trench ~= nil and trench:GetAttribute(attribute) == true
end

-- UI --------------------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "UnitCommandGui"
screenGui.ResetOnSpawn = false

local bar = Instance.new("Frame")
bar.Name = "CommandBar"
bar.AnchorPoint = Vector2.new(0.5, 1)
bar.Position = UDim2.fromScale(0.5, 0.97)
bar.Size = UDim2.fromScale(0.9, 0.2)
bar.BackgroundTransparency = 1
bar.Parent = screenGui

local function makeRow(name: string, yScale: number): Frame
	local row = Instance.new("Frame")
	row.Name = name
	row.Position = UDim2.fromScale(0, yScale)
	row.Size = UDim2.fromScale(1, 0.31)
	row.BackgroundTransparency = 1
	row.Parent = bar

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(CELL_PADDING, 0)
	layout.Parent = row
	return row
end

-- Size for each of `cellCount` equal cells sharing a row.
local function getCellSize(cellCount: number): UDim2
	local count = math.max(cellCount, 1)
	local width = (1 - CELL_PADDING * (count - 1)) / count
	return UDim2.fromScale(math.min(width, MAX_CELL_WIDTH), 1)
end

local function makeButton(name: string, layoutOrder: number, size: UDim2, row: Frame): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.LayoutOrder = layoutOrder
	button.Size = size
	button.TextScaled = true
	button.Parent = row
	return button
end

local function setEnabled(button: TextButton, enabled: boolean)
	button.Active = enabled
	button.AutoButtonColor = enabled
	button.TextTransparency = if enabled then 0 else 0.6
end

local deployRow = makeRow("DeployRow", 0)
local trenchRow = makeRow("TrenchRow", 0.345)
local ordersRow = makeRow("OrdersRow", 0.69)

-- Deploy row
local deployCellSize = getCellSize(1 + #unitTypes)

local suppliesLabel = Instance.new("TextLabel")
suppliesLabel.Name = "SuppliesLabel"
suppliesLabel.LayoutOrder = 0
suppliesLabel.Size = deployCellSize
suppliesLabel.TextScaled = true
suppliesLabel.Parent = deployRow

local deployButtons: { [string]: TextButton } = {}
for order, unitType in unitTypes do
	deployButtons[unitType] = makeButton(`Deploy_{unitType}`, order, deployCellSize, deployRow)
end

-- Orders row
local ordersCellSize = getCellSize(3 + #fortTypes)
local retreatButton = makeButton("RetreatButton", 1, ordersCellSize, ordersRow)
local advanceButton = makeButton("AdvanceButton", 2, ordersCellSize, ordersRow)
local chargeButton = makeButton("ChargeButton", 3, ordersCellSize, ordersRow)
local unselectedColor = retreatButton.BackgroundColor3

local buildButtons: { [string]: TextButton } = {}
for order, fortType in fortTypes do
	buildButtons[fortType] = makeButton(`Build_{fortType}`, 3 + order, ordersCellSize, ordersRow)
end

-- Trench row: one button per trench on the map, rebuilt whenever the map
-- changes (see rebuildTrenchRow).
local trenchButtons: { [number]: TextButton } = {}
local trenchConnections: { RBXScriptConnection } = {}

-- Refresh -----------------------------------------------------------------------

local function refreshDeployRow(supplies: number)
	suppliesLabel.Text = `Supplies: {supplies} (+{getTeamNumber("Income")}/s)`

	local unlockState: GameConfig.TeamState = {
		TrenchesOwned = getTeamNumber("TrenchesOwned"),
		CommandTier = getTeamNumber("CommandTier"),
	}
	local homeTrench = MapLoader.GetHomeTrenchId(TEAM)
	local homeFull = true
	if homeTrench then
		local homeCount = getTrenchNumber(homeTrench, `{TEAM}Count`) + getTrenchNumber(homeTrench, `{OTHER_TEAM}Count`)
		homeFull = homeCount >= MapLoader.GetSlotCount(homeTrench)
	end

	for unitType, button in deployButtons do
		local definition = GameConfig.Units[unitType]
		if not homeTrench then
			button.Text = `{definition.DisplayName}: no home trench`
			setEnabled(button, false)
		elseif not GameConfig.IsUnitUnlocked(unitType, unlockState) then
			button.Text = `{definition.DisplayName}: {GameConfig.DescribeUnlock(unitType)}`
			setEnabled(button, false)
		elseif homeFull and definition.OccupiesTrenchSlot then
			button.Text = `{definition.DisplayName}: Trench {homeTrench} full`
			setEnabled(button, false)
		else
			button.Text = `Deploy {definition.DisplayName} ({definition.Cost})`
			setEnabled(button, supplies >= definition.Cost)
		end
	end
end

local function refreshTrenchRow()
	for trenchId, button in trenchButtons do
		local count = getTrenchNumber(trenchId, `{TEAM}Count`)
		local hasOfficer = getTrenchFlag(trenchId, `{TEAM}CanCharge`) or getTrenchFlag(trenchId, `{TEAM}CanBuild`)
		button.Text = `Trench {trenchId}: {count}{if hasOfficer then " + Officer" else ""}`
		button.BackgroundColor3 = if trenchId == selectedTrench then SELECTED_COLOR else unselectedColor
	end
end

local function refreshOrdersRow(supplies: number)
	local charge = GameConfig.Charge
	local trenchId = selectedTrench
	if not trenchId then
		retreatButton.Text = "Retreat"
		advanceButton.Text = "Advance"
		chargeButton.Text = charge.DisplayName
		setEnabled(retreatButton, false)
		setEnabled(advanceButton, false)
		setEnabled(chargeButton, false)
		for fortType, button in buildButtons do
			button.Text = GameConfig.Fortifications[fortType].DisplayName
			setEnabled(button, false)
		end
		return
	end

	local count = getTrenchNumber(trenchId, `{TEAM}Count`)
	local ahead = MapLoader.GetNeighbor(trenchId, TEAM, false)
	local behind = MapLoader.GetNeighbor(trenchId, TEAM, true)

	if behind then
		retreatButton.Text = `Retreat {trenchId} > {behind}`
		setEnabled(retreatButton, count > 0)
	else
		retreatButton.Text = "Retreat: none behind"
		setEnabled(retreatButton, false)
	end

	if ahead then
		-- Moving into a trench with enemy units in it is an assault.
		local verb = if getTrenchNumber(ahead, `{OTHER_TEAM}Count`) > 0 then "Assault" else "Advance"
		advanceButton.Text = `{verb} {trenchId} > {ahead}`
		setEnabled(advanceButton, count > 0)
	else
		advanceButton.Text = "Advance: none ahead"
		setEnabled(advanceButton, false)
	end

	local cooldownLeft = getTrenchNumber(trenchId, `{TEAM}ChargeReadyAt`) - Workspace:GetServerTimeNow()
	if not ahead then
		chargeButton.Text = `{charge.DisplayName}: none ahead`
		setEnabled(chargeButton, false)
	elseif not getTrenchFlag(trenchId, `{TEAM}CanCharge`) then
		chargeButton.Text = `{charge.DisplayName}: needs Officer`
		setEnabled(chargeButton, false)
	elseif cooldownLeft > 0 then
		chargeButton.Text = `{charge.DisplayName}: {math.ceil(cooldownLeft)}s`
		setEnabled(chargeButton, false)
	else
		chargeButton.Text = `{charge.DisplayName}! ({charge.Cost})`
		setEnabled(chargeButton, supplies >= charge.Cost)
	end

	local canBuild = getTrenchFlag(trenchId, `{TEAM}CanBuild`)
	local trench = MapLoader.GetTrenchModel(trenchId)
	local ownsTrench = trench ~= nil and trench:GetAttribute("Owner") == TEAM
	for fortType, button in buildButtons do
		local definition = GameConfig.Fortifications[fortType]
		local built = getTrenchNumber(trenchId, `Fort_{fortType}_Count`)
		local building = getTrenchNumber(trenchId, `Fort_{fortType}_Building`)
		if building > 0 then
			button.Text = `{definition.DisplayName}: {if canBuild then "building" else "paused, needs Officer"}`
			setEnabled(button, false)
		elseif built >= definition.MaxPerTrench then
			button.Text = `{definition.DisplayName}: built`
			setEnabled(button, false)
		elseif not ownsTrench then
			button.Text = `{definition.DisplayName}: trench not held`
			setEnabled(button, false)
		elseif not canBuild then
			button.Text = `{definition.DisplayName}: needs Officer`
			setEnabled(button, false)
		else
			button.Text = `Build {definition.DisplayName} ({definition.Cost})`
			setEnabled(button, supplies >= definition.Cost)
		end
	end
end

local function refresh()
	local supplies = math.floor(getTeamNumber("Supplies"))
	refreshDeployRow(supplies)
	refreshTrenchRow()
	refreshOrdersRow(supplies)
end

-- Rebuilds the trench buttons from the current map and re-subscribes to each
-- trench's replicated state.
local function rebuildTrenchRow()
	for _, connection in trenchConnections do
		connection:Disconnect()
	end
	table.clear(trenchConnections)
	for _, button in trenchButtons do
		button:Destroy()
	end
	table.clear(trenchButtons)

	local trenchIds = MapLoader.GetTrenchIds()
	local cellSize = getCellSize(#trenchIds)
	for order, trenchId in trenchIds do
		local button = makeButton(`Trench_{trenchId}`, order, cellSize, trenchRow)
		trenchButtons[trenchId] = button
		button.Activated:Connect(function()
			selectedTrench = trenchId
			refresh()
		end)

		local trench = MapLoader.GetTrenchModel(trenchId)
		if trench then
			table.insert(trenchConnections, trench.AttributeChanged:Connect(refresh))
		end
	end

	-- Keep the selection on a trench that still exists.
	if not selectedTrench or not MapLoader.HasTrench(selectedTrench) then
		selectedTrench = MapLoader.GetHomeTrenchId(TEAM) or trenchIds[1]
	end
	refresh()
end

-- Input ---------------------------------------------------------------------------

local function requestDeploy(unitType: string)
	local button = deployButtons[unitType]
	if button and button.Active then
		deployRemote:FireServer(unitType)
	end
end

for unitType, button in deployButtons do
	button.Activated:Connect(function()
		requestDeploy(unitType)
	end)
end

-- Fires `remote` for the selected trench when an enabled order button is used.
local function connectOrder(button: TextButton, remote: RemoteEvent, extraArgument: string?)
	button.Activated:Connect(function()
		if button.Active and selectedTrench then
			remote:FireServer(selectedTrench, extraArgument)
		end
	end)
end

connectOrder(retreatButton, retreatRemote)
connectOrder(advanceButton, advanceRemote)
connectOrder(chargeButton, chargeRemote)
for fortType, button in buildButtons do
	connectOrder(button, buildRemote, fortType)
end

-- E / ButtonX deploys the first unit type in the registry.
ContextActionService:BindAction(DEPLOY_ACTION, function(_actionName: string, inputState: Enum.UserInputState)
	if inputState == Enum.UserInputState.Begin and unitTypes[1] then
		requestDeploy(unitTypes[1])
	end
	return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.E, Enum.KeyCode.ButtonX)

teamState.AttributeChanged:Connect(refresh)
MapLoader.Changed:Connect(rebuildTrenchRow)

rebuildTrenchRow()
screenGui.Parent = playerGui

task.spawn(function()
	while true do
		task.wait(REFRESH_INTERVAL)
		refresh()
	end
end)
