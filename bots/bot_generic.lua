--[[
    bot_generic.lua
    Точка входа автономного бота Dota 2

    Обязанности:
    - require модулей blackboard.lua и behavior_tree.lua
    - Нативный Data Provider: наполнение Blackboard из GetBot() + методов движка
    - Построение Behavior Tree строго по заданной иерархии
    - Хук Think() - единственная "петля" принятия решений
]]

require( "blackboard" )
require( "behavior_tree" )

local Blackboard = require( "blackboard" )
local BT         = require( "behavior_tree" )

local thisBot = nil
local rootTree = nil
local bInit = false

local function InitializeBot()
    if bInit then
        return true
    end

    thisBot = GetBot()
    if thisBot == nil then
        return false
    end

    Blackboard:Init()
    Blackboard:SetBotRef(thisBot)

    rootTree = BuildBehaviorTree()

    bInit = true
    return true
end

----------------------------------------------------------------
-- DATA PROVIDER (только извлечение из движка, БЕЗ РЕШЕНИЙ)
----------------------------------------------------------------

local function FindLowestHPUnit(units)
    if units == nil or #units == 0 then
        return nil
    end
    local best = nil
    local bestHP = 1e9
    for i=1, #units do
        local u = units[i]
        if u ~= nil and u:IsAlive() then
            local hp = u:GetHealth()
            if hp < bestHP then
                bestHP = hp
                best = u
            end
        end
    end
    return best
end

local function SyncBlackboard()
    if thisBot == nil then
        return
    end

    local curTime = GameTime()
    Blackboard:Set("MacroState", "CurrentGameTime", curTime)

    -- SelfState
    local maxHP = thisBot:GetMaxHealth()
    local maxMP = thisBot:GetMaxMana()
    local curHP = thisBot:GetHealth()
    local curMP = thisBot:GetMana()

    Blackboard:Set("SelfState", "HP", (maxHP > 0) and (curHP / maxHP) or 1.0)
    Blackboard:Set("SelfState", "MP", (maxMP > 0) and (curMP / maxMP) or 1.0)
    Blackboard:Set("SelfState", "Gold", thisBot:GetGold())
    Blackboard:Set("SelfState", "Level", thisBot:GetLevel())
    Blackboard:Set("SelfState", "Position", thisBot:GetLocation())
    Blackboard:Set("SelfState", "IsStunned", thisBot:IsStunned())
    Blackboard:Set("SelfState", "IsHexed", thisBot:IsHexed())
    Blackboard:Set("SelfState", "IsSilenced", thisBot:IsSilenced())
    Blackboard:Set("SelfState", "IsChanneling", thisBot:IsChanneling())
    Blackboard:Set("SelfState", "IsUsingAbility", thisBot:IsUsingAbility())

    -- Abilities
    local abilityReady = {}
    local abilityManaCost = {}
    local abilityRange = {}
    local abilityName = {}
    local abilityLevels = {}
    local abilityCD = {}
    for i=0, 23 do
        local ab = thisBot:GetAbilityInSlot(i)
        if ab ~= nil then
            abilityName[i] = ab:GetName()
            abilityLevels[i] = ab:GetLevel()
            abilityCD[i] = ab:GetCooldownTimeRemaining()
            abilityReady[i] = (ab:GetCooldownTimeRemaining() <= 0) and (ab:GetLevel() > 0)
            abilityManaCost[i] = ab:GetManaCost()
            abilityRange[i] = ab:GetCastRange()
        else
            abilityName[i] = nil
            abilityLevels[i] = 0
            abilityCD[i] = 0
            abilityReady[i] = false
            abilityManaCost[i] = 0
            abilityRange[i] = 0
        end
    end
    Blackboard:Set("SelfState", "AbilityCooldowns", abilityCD)
    Blackboard:Set("SelfState", "AbilityReady", abilityReady)
    Blackboard:Set("SelfState", "AbilityManaCost", abilityManaCost)
    Blackboard:Set("SelfState", "AbilityRange", abilityRange)
    Blackboard:Set("SelfState", "AbilityName", abilityName)
    Blackboard:Set("SelfState", "AbilityLevels", abilityLevels)

    -- TacticalState
    local enemyHeroes = thisBot:GetNearbyHeroes(1600, true) or {}
    local enemyCreeps = thisBot:GetNearbyCreeps(1600, true) or {}
    local allyCreeps  = thisBot:GetNearbyCreeps(1600, false) or {}
    local allyHeroes  = thisBot:GetNearbyHeroes(1600, false) or {}

    Blackboard:Set("TacticalState", "NearbyEnemyHeroes", enemyHeroes)
    Blackboard:Set("TacticalState", "NearbyEnemyCreeps", enemyCreeps)
    Blackboard:Set("TacticalState", "NearbyAllyCreeps", allyCreeps)
    Blackboard:Set("TacticalState", "NearbyAllyHeroes", allyHeroes)
    Blackboard:Set("TacticalState", "EnemyHeroCount", #enemyHeroes)
    Blackboard:Set("TacticalState", "EnemyCreepCount", #enemyCreeps)

    Blackboard:Set("TacticalState", "TargetEnemyHero", enemyHeroes[1])
    Blackboard:Set("TacticalState", "TargetLowestHPEnemyCreep", FindLowestHPUnit(enemyCreeps))
    Blackboard:Set("TacticalState", "TargetLowestHPAllyCreep", FindLowestHPUnit(allyCreeps))

    -- Threat level: простая эвристика (количество врагов в радиусе)
    local threat = 0
    if #enemyHeroes >= 3 then
        threat = 2
    elseif #enemyHeroes >= 1 then
        threat = 1
    end
    Blackboard:Set("TacticalState", "ActiveThreatLevel", threat)
end

----------------------------------------------------------------
-- BUILD BEHAVIOR TREE (иерархия строго по ТЗ)
----------------------------------------------------------------

function BuildBehaviorTree()
    -- Condition Nodes
    local condLowHP = BT.Condition:new({
        name = "CheckLowHealth",
        eval = function(npcBot, blackboard)
            local hp = blackboard:Get("SelfState", "HP") or 1.0
            return hp < 0.25
        end
    })

    local condEnemyHero = BT.Condition:new({
        name = "CheckEnemyHeroPresent",
        eval = function(npcBot, blackboard)
            local t = blackboard:Get("TacticalState", "TargetEnemyHero")
            return t ~= nil
        end
    })

    local condCreeps = BT.Condition:new({
        name = "CheckCreepsInRadius",
        eval = function(npcBot, blackboard)
            local creeps = blackboard:Get("TacticalState", "NearbyEnemyCreeps") or {}
            return #creeps > 0
        end
    })

    -- Action Stubs (логика переопределяется в bot_sniper.lua при require)
    local actRetreat = BT.Action:new({
        name = "ExecuteRetreat",
        execute = function(npcBot, blackboard)
            -- USER LOGIC HERE: TP to fountain / move to fountain
            return BT.FAILURE
        end
    })

    local actCombo = BT.Action:new({
        name = "ExecuteAbilityCombo",
        execute = function(npcBot, blackboard)
            -- USER LOGIC HERE: ability combo
            return BT.FAILURE
        end
    })

    local actLastHit = BT.Action:new({
        name = "ExecuteLastHitDeny",
        execute = function(npcBot, blackboard)
            -- USER LOGIC HERE: last hit / deny
            return BT.FAILURE
        end
    })

    local actLaning = BT.Action:new({
        name = "ExecuteLaningPosition",
        execute = function(npcBot, blackboard)
            -- USER LOGIC HERE: laning positioning
            return BT.FAILURE
        end
    })

    -- Sequences
    local seqRetreat = BT.BuildSequence("EmergencyRetreat", {
        condLowHP, actRetreat
    })

    local seqCombat = BT.BuildSequence("MicroCombat", {
        condEnemyHero, actCombo
    })

    local seqCreep = BT.BuildSequence("CreepMicro", {
        condCreeps, actLastHit
    })

    local seqLaning = BT.BuildSequence("IdleLaningMacro", {
        actLaning
    })

    -- Root Selector
    local root = BT.BuildSelector("RootSelector", {
        seqRetreat, seqCombat, seqCreep, seqLaning
    })

    return root
end

----------------------------------------------------------------
-- ENGINE HOOKS
----------------------------------------------------------------

function Think()
    if not InitializeBot() then
        return
    end

    SyncBlackboard()

    if rootTree ~= nil then
        rootTree:Tick(thisBot, Blackboard)
    end
end

function MinionThink(hMinionUnit)
    -- Заглушка: логика контроля крипов/иллюзий
    -- USER LOGIC HERE
end

function GetDesire()
    -- Базовое желание; переопределяется при необходимости
    return BOT_MODE_DESIRE_NONE
end

return {}
