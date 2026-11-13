--!strict
-- Server-side team economy. Each team has a pool of Supplies that grows every
-- second (a base amount plus a bonus per trench it owns) and is spent on units,
-- charges and fortifications.
--
-- Balances are replicated as attributes on ReplicatedStorage.TeamState so
-- clients can display them:
--   AlliesSupplies / EnemiesSupplies : current balance
--   AlliesIncome   / EnemiesIncome   : supplies gained per second
--   AlliesTrenchesOwned / EnemiesTrenchesOwned, AlliesCommandTier /
--   EnemiesCommandTier : inputs to GameConfig.IsUnitUnlocked

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

type Team = GameConfig.Team
type TeamState = GameConfig.TeamState

local TEAMS: { Team } = { "Allies", "Enemies" }
local INCOME_TICK = 1 -- seconds

local Economy = {}

local supplies: { [Team]: number } = {
	Allies = GameConfig.STARTING_SUPPLIES,
	Enemies = GameConfig.STARTING_SUPPLIES,
}

local teamState = Instance.new("Folder")
teamState.Name = GameConfig.TEAM_STATE_FOLDER

local trenchesFolder = Workspace:WaitForChild("Trenches")

function Economy.GetTrenchesOwned(team: Team): number
	local ownedTrenches = 0
	for _, trench in trenchesFolder:GetChildren() do
		if trench:GetAttribute("Owner") == team then
			ownedTrenches += 1
		end
	end
	return ownedTrenches
end

-- Supplies a team gains per second, from its base income and owned trenches.
function Economy.GetIncome(team: Team): number
	return GameConfig.BASE_INCOME + Economy.GetTrenchesOwned(team) * GameConfig.INCOME_PER_TRENCH
end

-- Current inputs for unlock rules (see GameConfig.IsUnitUnlocked).
function Economy.GetTeamState(team: Team): TeamState
	return {
		TrenchesOwned = Economy.GetTrenchesOwned(team),
		CommandTier = GameConfig.STARTING_COMMAND_TIER,
	}
end

local function replicate(team: Team)
	local state = Economy.GetTeamState(team)
	teamState:SetAttribute(`{team}Supplies`, supplies[team])
	teamState:SetAttribute(`{team}Income`, Economy.GetIncome(team))
	teamState:SetAttribute(`{team}TrenchesOwned`, state.TrenchesOwned)
	teamState:SetAttribute(`{team}CommandTier`, state.CommandTier)
end

function Economy.GetSupplies(team: Team): number
	return supplies[team]
end

function Economy.CanAfford(team: Team, cost: number): boolean
	return supplies[team] >= cost
end

function Economy.Add(team: Team, amount: number)
	supplies[team] += amount
	replicate(team)
end

-- Deducts `cost` if the team can afford it. Returns whether it was paid.
function Economy.TrySpend(team: Team, cost: number): boolean
	if supplies[team] < cost then
		return false
	end
	supplies[team] -= cost
	replicate(team)
	return true
end

for _, team in TEAMS do
	replicate(team)
end
teamState.Parent = ReplicatedStorage

task.spawn(function()
	while true do
		task.wait(INCOME_TICK)
		for _, team in TEAMS do
			Economy.Add(team, Economy.GetIncome(team) * INCOME_TICK)
		end
	end
end)

return Economy
