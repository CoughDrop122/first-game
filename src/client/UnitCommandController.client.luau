--!strict
-- Command bar. Everything is driven by GameConfig (unit and fortification
-- registries) and by state the server replicates as attributes on the trench
-- Models and on ReplicatedStorage.TeamState.
--
-- Layout:
--   Deploy row  : [ Supplies ] [ one button per unit type in GameConfig.Units ]
--   Trench row  : [ Trench 1 ] ... [ Trench N ]         <- pick a trench
--   Orders row  : [ Retreat ] [ Advance ] [ Charge ] [ one Build button per fortification ]
--                 (orders apply to the selected trench)

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

local TEAM: GameConfig.Team = "Allies"
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

local trenchesFolder = Workspace:WaitForChild("Trenches")
local trenchModels: { Instance } = {}
for trenchIndex = 1, GameConfig.TRENCH_COUNT do
	trenchModels[trenchIndex] = trenchesFolder:WaitForChild(`Trench_{trenchIndex}`)
end

local teamState = ReplicatedStorage:WaitForChild(GameConfig.TEAM_STATE_FOLDER)

local unitTypes = GameConfig.GetSortedKeys(GameConfig.Units)
local fortTypes = GameConfig.GetSortedKeys(GameConfig.Fortifications)
local homeTrench = GameConfig.GetHomeTrenchIndex(TEAM)
local advanceDirection = GameConfig.GetAdvanceDirection(TEAM)

local selectedTrench = homeTrench

-- Replicated state ------------------------------------------------------------

local function getTeamNumber(attribute: string): number
	local value = teamState:GetAttribute(`{TEAM}{attribute}`)
	return if typeof(value) == "number" then value else 0
end

local function getTrenchNumber(trenchIndex: number, attribute: string): number
	local value = trenchModels[trenchIndex]:GetAttribute(attribute)
	return if typeof(value) == "number" then value else 0
end

local function getTrenchFlag(trenchIndex: number, attribute: string): boolean
	return trenchModels[trenchIndex]:GetAttribute(attribute) == true
end

local function isValidTrenchIndex(trenchIndex: number): boolean
	return trenchIndex >= 1 and trenchIndex <= GameConfig.TRENCH_COUNT
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
	local width = (1 - CELL_PADDING * (cellCount - 1)) / cellCount
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

-- Trench row
local trenchCellSize = getCellSize(GameConfig.TRENCH_COUNT)
local trenchButtons: { TextButton } = {}
for trenchIndex = 1, GameConfig.TRENCH_COUNT do
	trenchButtons[trenchIndex] = makeButton(`Trench_{trenchIndex}`, trenchIndex, trenchCellSize, trenchRow)
end
local unselectedColor = trenchButtons[1].BackgroundColor3

-- Orders row
local ordersCellSize = getCellSize(3 + #fortTypes)
local retreatButton = makeButton("RetreatButton", 1, ordersCellSize, ordersRow)
local advanceButton = makeButton("AdvanceButton", 2, ordersCellSize, ordersRow)
local chargeButton = makeButton("ChargeButton", 3, ordersCellSize, ordersRow)

local buildButtons: { [string]: TextButton } = {}
for order, fortType in fortTypes do
	buildButtons[fortType] = makeButton(`Build_{fortType}`, 3 + order, ordersCellSize, ordersRow)
end

-- Refresh -----------------------------------------------------------------------

local function refreshDeployRow(supplies: number)
	suppliesLabel.Text = `Supplies: {supplies} (+{getTeamNumber("Income")}/s)`

	local unlockState: GameConfig.TeamState = {
		TrenchesOwned = getTeamNumber("TrenchesOwned"),
		CommandTier = getTeamNumber("CommandTier"),
	}
	local homeCount = getTrenchNumber(homeTrench, "AlliesCount") + getTrenchNumber(homeTrench, "EnemiesCount")
	local homeFull = homeCount >= GameConfig.SLOTS_PER_TRENCH

	for unitType, button in deployButtons do
		local definition = GameConfig.Units[unitType]
		local blockedByTrench = homeFull and definition.OccupiesTrenchSlot
		if not GameConfig.IsUnitUnlocked(unitType, unlockState) then
			button.Text = `{definition.DisplayName}: {GameConfig.DescribeUnlock(unitType)}`
			setEnabled(button, false)
		elseif blockedByTrench then
			button.Text = `{definition.DisplayName}: Trench {homeTrench} full`
			setEnabled(button, false)
		else
			button.Text = `Deploy {definition.DisplayName} ({definition.Cost})`
			setEnabled(button, supplies >= definition.Cost)
		end
	end
end

local function refreshTrenchRow()
	for trenchIndex, button in trenchButtons do
		local count = getTrenchNumber(trenchIndex, `{TEAM}Count`)
		local hasOfficer = getTrenchFlag(trenchIndex, `{TEAM}CanCharge`) or getTrenchFlag(trenchIndex, `{TEAM}CanBuild`)
		button.Text = `Trench {trenchIndex}: {count}{if hasOfficer then " + Officer" else ""}`
		button.BackgroundColor3 = if trenchIndex == selectedTrench then SELECTED_COLOR else unselectedColor
	end
end

local function refreshOrdersRow(supplies: number)
	local trenchIndex = selectedTrench
	local count = getTrenchNumber(trenchIndex, `{TEAM}Count`)
	local ahead = trenchIndex + advanceDirection
	local behind = trenchIndex - advanceDirection
	local otherTeamCount = if TEAM == "Allies" then "EnemiesCount" else "AlliesCount"

	if isValidTrenchIndex(behind) then
		retreatButton.Text = `Retreat {trenchIndex} > {behind}`
		setEnabled(retreatButton, count > 0)
	else
		retreatButton.Text = "Retreat: none behind"
		setEnabled(retreatButton, false)
	end

	if isValidTrenchIndex(ahead) then
		-- Moving into a trench with enemy units in it is an assault.
		local verb = if getTrenchNumber(ahead, otherTeamCount) > 0 then "Assault" else "Advance"
		advanceButton.Text = `{verb} {trenchIndex} > {ahead}`
		setEnabled(advanceButton, count > 0)
	else
		advanceButton.Text = "Advance: none ahead"
		setEnabled(advanceButton, false)
	end

	local charge = GameConfig.Charge
	local cooldownLeft = getTrenchNumber(trenchIndex, `{TEAM}ChargeReadyAt`) - Workspace:GetServerTimeNow()
	if not isValidTrenchIndex(ahead) then
		chargeButton.Text = `{charge.DisplayName}: none ahead`
		setEnabled(chargeButton, false)
	elseif not getTrenchFlag(trenchIndex, `{TEAM}CanCharge`) then
		chargeButton.Text = `{charge.DisplayName}: needs Officer`
		setEnabled(chargeButton, false)
	elseif cooldownLeft > 0 then
		chargeButton.Text = `{charge.DisplayName}: {math.ceil(cooldownLeft)}s`
		setEnabled(chargeButton, false)
	else
		chargeButton.Text = `{charge.DisplayName}! ({charge.Cost})`
		setEnabled(chargeButton, supplies >= charge.Cost)
	end

	local canBuild = getTrenchFlag(trenchIndex, `{TEAM}CanBuild`)
	local ownsTrench = trenchModels[trenchIndex]:GetAttribute("Owner") == TEAM
	for fortType, button in buildButtons do
		local definition = GameConfig.Fortifications[fortType]
		local built = getTrenchNumber(trenchIndex, `Fort_{fortType}_Count`)
		local building = getTrenchNumber(trenchIndex, `Fort_{fortType}_Building`)
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

for trenchIndex, button in trenchButtons do
	button.Activated:Connect(function()
		selectedTrench = trenchIndex
		refresh()
	end)
end

-- Fires `remote` for the selected trench when an enabled order button is used.
local function connectOrder(button: TextButton, remote: RemoteEvent, extraArgument: string?)
	button.Activated:Connect(function()
		if button.Active then
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

for _, trench in trenchModels do
	trench.AttributeChanged:Connect(refresh)
end
teamState.AttributeChanged:Connect(refresh)

refresh()
screenGui.Parent = playerGui

task.spawn(function()
	while true do
		task.wait(REFRESH_INTERVAL)
		refresh()
	end
end)
