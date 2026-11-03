--[[
    bot_sniper.lua
    Автономный бот Dota 2 за Sniper.

    Инфраструктура: blackboard.lua + behavior_tree.lua (bots/).
    Логика полностью реализована под Sniper:
      - Shrapnel (замедление/урон по области)
      - Assassinate (снайперский выстрел по герою)
      - Позиционирование на дистанции, кайтинг
      - Ластхит/дени
      - Отступление при низком HP
]]

require("blackboard")
require("behavior_tree")

local Blackboard = require("blackboard")
local BT         = require("behavior_tree")

local thisBot = nil
local rootTree = nil
local bInit = false

-- Константы способностей
local ABILITY_SHRAPNEL    = "sniper_shrapnel"
local ABILITY_HEADSHOT    = "sniper_headshot"
local ABILITY_TAKE_AIM    = "sniper_take_aim"
local ABILITY_ASSASSINATE = "sniper_assassinate"

-- Вспомогательные функции
local function FindAbility(bot, name)
    if bot == nil or name == nil then return nil end
    for i = 0, 23 do
        local ab = bot:GetAbilityInSlot(i)
        if ab ~= nil and ab:GetName() == name then
            return ab
        end
    end
    return nil
end

local function FindLowestHPUnit(units)
    if units == nil or #units == 0 then return nil end
    local best = nil
    local bestHP = 1e9
    for i = 1, #units do
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

local function Distance(a, b)
    if a == nil or b == nil then return 99999 end
    return (a - b):Length2D()
end

local function GetFountainLoc(bot)
    local team = bot:GetTeam()
    -- GetFountainLocation доступна в Bot API
    local ok, loc = pcall(GetFountainLocation, team)
    if ok and loc ~= nil then return loc end
    return nil
end

-- Инициализация
local function InitializeBot()
    if bInit then return true end
    thisBot = GetBot()
    if thisBot == nil then return false end
    Blackboard:Init()
    Blackboard:SetBotRef(thisBot)
    rootTree = BuildBehaviorTree()
    bInit = true
    return true
end

----------------------------------------------------------------
-- DATA PROVIDER (только извлечение из движка, БЕЗ РЕШЕНИЙ)
----------------------------------------------------------------

local function SyncBlackboard()
    if thisBot == nil then return end

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
    for i = 0, 23 do
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

    Blackboard:Set("TacticalState", "TargetEnemyHero", FindLowestHPUnit(enemyHeroes))
    Blackboard:Set("TacticalState", "TargetLowestHPEnemyCreep", FindLowestHPUnit(enemyCreeps))
    Blackboard:Set("TacticalState", "TargetLowestHPAllyCreep", FindLowestHPUnit(allyCreeps))

    local threat = 0
    if #enemyHeroes >= 3 then threat = 2
    elseif #enemyHeroes >= 1 then threat = 1 end
    Blackboard:Set("TacticalState", "ActiveThreatLevel", threat)

    -- MacroState
    Blackboard:Set("MacroState", "ActiveLane", thisBot:GetLane and thisBot:GetLane() or nil)
end

----------------------------------------------------------------
-- BUILD BEHAVIOR TREE
----------------------------------------------------------------

function BuildBehaviorTree()
    -- Conditions
    local condLowHP = BT.Condition:new({
        name = "CheckLowHealth",
        eval = function(npcBot, blackboard)
            local hp = blackboard:Get("SelfState", "HP") or 1.0
            return hp < 0.30
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

    -- Actions
    local actRetreat = BT.Action:new({
        name = "ExecuteRetreat",
        execute = function(npcBot, blackboard)
            local hp = blackboard:Get("SelfState", "HP") or 1.0
            if hp >= 0.30 then return BT.FAILURE end

            -- Попытка использовать TP-свиток
            local tp = nil
            for i = 0, 5 do
                local item = npcBot:GetItemInSlot(i)
                if item ~= nil and item:GetName() == "item_tpscroll" then
                    tp = item
                    break
                end
            end

            local fountain = GetFountainLoc(npcBot)
            if tp ~= nil then
                if fountain ~= nil then
                    npcBot:Action_UseAbilityOnLocation(tp, fountain)
                    return BT.RUNNING
                end
            end

            if fountain ~= nil then
                npcBot:Action_MoveToLocation(fountain)
                return BT.RUNNING
            end

            return BT.FAILURE
        end
    })

    local actCombo = BT.Action:new({
        name = "ExecuteAbilityCombo",
        execute = function(npcBot, blackboard)
            local target = blackboard:Get("TacticalState", "TargetEnemyHero")
            if target == nil or not target:IsAlive() then return BT.FAILURE end

            local myPos = npcBot:GetLocation()
            local tPos = target:GetLocation()
            local dist = Distance(myPos, tPos)

            -- Assassinate: дальний снайперский выстрел по герою с низким HP
            local assassinate = FindAbility(npcBot, ABILITY_ASSASSINATE)
            if assassinate ~= nil and assassinate:GetLevel() > 0 then
                local ready = assassinate:GetCooldownTimeRemaining() <= 0
                local manaOk = npcBot:GetMana() >= assassinate:GetManaCost()
                local inRange = dist <= assassinate:GetCastRange()
                -- Стреляем, если цель уязвима (HP < 40%) или просто доступна
                local targetLow = (target:GetHealth() / target:GetMaxHealth()) < 0.45
                if ready and manaOk and inRange and targetLow and target:IsVisible() then
                    npcBot:Action_UseAbilityOnEntity(assassinate, target)
                    return BT.RUNNING
                end
            end

            -- Shrapnel: замедление/урон по области на цель
            local shrapnel = FindAbility(npcBot, ABILITY_SHRAPNEL)
            if shrapnel ~= nil and shrapnel:GetLevel() > 0 then
                local ready = shrapnel:GetCooldownTimeRemaining() <= 0
                local manaOk = npcBot:GetMana() >= shrapnel:GetManaCost()
                local inRange = dist <= shrapnel:GetCastRange()
                if ready and manaOk and inRange then
                    npcBot:Action_UseAbilityOnLocation(shrapnel, tPos)
                    return BT.RUNNING
                end
            end

            -- Кайтинг: если враг близко, отступаем
            local attackRange = npcBot:GetAttackRange()
            if dist < 450 then
                local away = myPos + (myPos - tPos):Normalized() * 300
                npcBot:Action_MoveToLocation(away)
                return BT.RUNNING
            end

            -- Атака цели, если в радиусе атаки
            if dist <= attackRange + 50 then
                npcBot:Action_AttackUnit(target, true)
                return BT.RUNNING
            else
                npcBot:Action_MoveToLocation(tPos)
                return BT.RUNNING
            end
        end
    })

    local actLastHit = BT.Action:new({
        name = "ExecuteLastHitDeny",
        execute = function(npcBot, blackboard)
            local attackRange = npcBot:GetAttackRange()
            local myDmg = npcBot:GetAttackDamage()

            -- Ластхит вражеского крипа
            local enemyCreeps = blackboard:Get("TacticalState", "NearbyEnemyCreeps") or {}
            local lhTarget = nil
            for i = 1, #enemyCreeps do
                local c = enemyCreeps[i]
                if c ~= nil and c:IsAlive() then
                    local d = Distance(npcBot:GetLocation(), c:GetLocation())
                    if d <= attackRange + 50 then
                        if c:GetHealth() <= myDmg + 5 then
                            lhTarget = c
                            break
                        end
                    end
                end
            end
            if lhTarget ~= nil then
                npcBot:Action_AttackUnit(lhTarget, true)
                return BT.RUNNING
            end

            -- Дени союзного крипа
            local allyCreeps = blackboard:Get("TacticalState", "NearbyAllyCreeps") or {}
            local denyTarget = nil
            for i = 1, #allyCreeps do
                local c = allyCreeps[i]
                if c ~= nil and c:IsAlive() then
                    local d = Distance(npcBot:GetLocation(), c:GetLocation())
                    if d <= attackRange + 50 then
                        -- Дени, если HP достаточно низкое (около 50% и ниже для дени)
                        if c:GetHealth() <= myDmg + 5 and c:GetHealth() / c:GetMaxHealth() < 0.5 then
                            denyTarget = c
                            break
                        end
                    end
                end
            end
            if denyTarget ~= nil then
                npcBot:Action_AttackUnit(denyTarget, true)
                return BT.RUNNING
            end

            return BT.FAILURE
        end
    })

    local actLaning = BT.Action:new({
        name = "ExecuteLaningPosition",
        execute = function(npcBot, blackboard)
            -- Если рядом есть союзные крипы, держимся за ними (позади фронта)
            local allyCreeps = blackboard:Get("TacticalState", "NearbyAllyCreeps") or {}
            local enemyCreeps = blackboard:Get("TacticalState", "NearbyEnemyCreeps") or {}

            if #allyCreeps > 0 then
                -- Двигаемся к центру союзного крип-вейва, но держим дистанцию
                local sumX, sumY, n = 0, 0, 0
                for i = 1, #allyCreeps do
                    local c = allyCreeps[i]
                    if c ~= nil and c:IsAlive() then
                        local l = c:GetLocation()
                        sumX = sumX + l.x
                        sumY = sumY + l.y
                        n = n + 1
                    end
                end
                if n > 0 then
                    local center = Vector(sumX / n, sumY / n, 0)
                    -- Держимся чуть позади крип-вейва
                    local myPos = npcBot:GetLocation()
                    local dir = (center - myPos)
                    if dir:Length2D() > 100 then
                        npcBot:Action_MoveToLocation(center)
                        return BT.RUNNING
                    end
                end
            end

            -- Если нет крипов, двигаемся в сторону линии (mid по умолчанию)
            -- Пытаемся получить точку линии через GetLaneFrontLocation если доступно
            local team = npcBot:GetTeam()
            local lane = blackboard:Get("MacroState", "ActiveLane")
            if lane == nil then lane = LANE_MID end

            local ok, front = pcall(GetLaneFrontLocation, team, lane, 0.5)
            if ok and front ~= nil then
                npcBot:Action_MoveToLocation(front)
                return BT.RUNNING
            end

            return BT.RUNNING
        end
    })

    -- Sequences
    local seqRetreat = BT.BuildSequence("EmergencyRetreat", { condLowHP, actRetreat })
    local seqCombat  = BT.BuildSequence("MicroCombat", { condEnemyHero, actCombo })
    local seqCreep   = BT.BuildSequence("CreepMicro", { condCreeps, actLastHit })
    local seqLaning  = BT.BuildSequence("IdleLaningMacro", { actLaning })

    -- Root Selector
    local root = BT.BuildSelector("RootSelector", { seqRetreat, seqCombat, seqCreep, seqLaning })
    return root
end

----------------------------------------------------------------
-- ENGINE HOOKS
----------------------------------------------------------------

function Think()
    if not InitializeBot() then return end
    SyncBlackboard()
    if rootTree ~= nil then
        rootTree:Tick(thisBot, Blackboard)
    end
end

function MinionThink(hMinionUnit)
    -- Логика контроля крипов/иллюзий (заглушка)
end

function CourierThink(hCourierUnit)
    -- Логика курьера (заглушка)
end

function GetDesire()
    return BOT_MODE_DESIRE_NONE
end

return {}
