--[[
    bot_sniper.lua
    Автономный бот Dota 2 за Sniper — тяжёлая логика.

    Слои:
      - Data Provider: полное считывание состояния движка (герои, крипы, нейтралы,
        башни, казармы, предметы, руны, Рошан).
      - Macro: фаза игры, выбор линии фарма, push/defend, оценка угроз.
      - Economy: автоматическая покупка предметов по билду, TP-свитки, buyback.
      - Combat: поиск убиваемых героев, burst-урон (Shrapnel + Assassinate + атаки),
        кайтинг, позиционирование на дистанции.
      - Farming: ластхит, дени, джангл, контроль равновесия линии.
      - Map awareness: пропавшие враги, отступление при ганке, защита базы.
]]

require("blackboard")
require("behavior_tree")

local Blackboard = require("blackboard")
local BT         = require("behavior_tree")

local thisBot = nil
local rootTree = nil
local bInit = false

-- Константы способностей Sniper
local ABILITY_SHRAPNEL    = "sniper_shrapnel"
local ABILITY_HEADSHOT    = "sniper_headshot"
local ABILITY_TAKE_AIM    = "sniper_take_aim"
local ABILITY_ASSASSINATE = "sniper_assassinate"

-- Билд предметов Sniper (по порядку)
local ITEM_BUILD = {
    "item_wraith_band",
    "item_power_treads",
    "item_dragon_lance",
    "item_maelstrom",
    "item_black_king_bar",
    "item_daedalus",
    "item_hurricane_pike",
    "item_satanic",
    "item_monkey_king_bar",
    "item_ultimate_scepter",
}

-- Локации рун (приблизительные, river)
local RUNE_SPOTS = {
    Vector(-2200, -1700, 0),
    Vector(2200, 1700, 0),
    Vector(-1000, 2600, 0),
    Vector(1000, -2600, 0),
}

-- =========================================================================
-- УТИЛИТЫ
-- =========================================================================
local function FindAbility(bot, name)
    if bot == nil or name == nil then return nil end
    for i = 0, 23 do
        local ab = bot:GetAbilityInSlot(i)
        if ab ~= nil and ab:GetName() == name then return ab end
    end
    return nil
end

local function FindLowestHPUnit(units)
    if units == nil or #units == 0 then return nil end
    local best, bestHP = nil, 1e9
    for i = 1, #units do
        local u = units[i]
        if u ~= nil and u:IsAlive() then
            local hp = u:GetHealth()
            if hp < bestHP then bestHP = hp; best = u end
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
    local ok, loc = pcall(GetFountainLocation, team)
    if ok and loc ~= nil then return loc end
    return nil
end

local function HasItem(bot, name)
    for i = 0, 15 do
        local it = bot:GetItemInSlot(i)
        if it ~= nil and it:GetName() == name then return it, i end
    end
    return nil, -1
end

local function FreeSlot(bot)
    for i = 0, 5 do
        if bot:GetItemInSlot(i) == nil then return i end
    end
    return -1
end

local function ItemCost(name)
    local ok, c = pcall(GetItemCost, name)
    if ok and type(c) == "number" then return c end
    return 0
end

-- =========================================================================
-- ИНИЦИАЛИЗАЦИЯ
-- =========================================================================
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

-- =========================================================================
-- DATA PROVIDER — полное считывание движка
-- =========================================================================
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
    Blackboard:Set("SelfState", "AttackDamage", thisBot:GetAttackDamage())
    Blackboard:Set("SelfState", "AttackRange", thisBot:GetAttackRange())
    local spa = 1.0
    local ok, v = pcall(function() return thisBot:GetSecondsPerAttack() end)
    if ok and type(v) == "number" then spa = v end
    Blackboard:Set("SelfState", "SecondsPerAttack", spa)

    -- Abilities
    local abilityReady, abilityManaCost, abilityRange = {}, {}, {}
    local abilityName, abilityLevels, abilityCD = {}, {}, {}
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
            abilityName[i] = nil; abilityLevels[i] = 0; abilityCD[i] = 0
            abilityReady[i] = false; abilityManaCost[i] = 0; abilityRange[i] = 0
        end
    end
    Blackboard:Set("SelfState", "AbilityCooldowns", abilityCD)
    Blackboard:Set("SelfState", "AbilityReady", abilityReady)
    Blackboard:Set("SelfState", "AbilityManaCost", abilityManaCost)
    Blackboard:Set("SelfState", "AbilityRange", abilityRange)
    Blackboard:Set("SelfState", "AbilityName", abilityName)
    Blackboard:Set("SelfState", "AbilityLevels", abilityLevels)

    -- Inventory
    local inv = {}
    local hasTP = false
    for i = 0, 15 do
        local it = thisBot:GetItemInSlot(i)
        if it ~= nil then
            inv[i] = it:GetName()
            if it:GetName() == "item_tpscroll" then hasTP = true end
        end
    end
    Blackboard:Set("SelfState", "Inventory", inv)
    Blackboard:Set("SelfState", "HasTP", hasTP)

    local bb = false
    local ok2, v2 = pcall(function() return thisBot:HasBuyback() end)
    if ok2 then bb = (v2 == true) end
    Blackboard:Set("SelfState", "BuybackAvailable", bb)

    -- TacticalState
    local enemyHeroes = thisBot:GetNearbyHeroes(1600, true) or {}
    local enemyCreeps = thisBot:GetNearbyCreeps(1600, true) or {}
    local allyCreeps  = thisBot:GetNearbyCreeps(1600, false) or {}
    local allyHeroes  = thisBot:GetNearbyHeroes(1600, false) or {}

    local neutralCreeps = {}
    local okN, nc = pcall(function() return thisBot:GetNearbyNeutralCreeps(1600) end)
    if okN and nc ~= nil then neutralCreeps = nc end

    local enemyTowers = {}
    local allyTowers = {}
    local okT, et = pcall(function() return thisBot:GetNearbyTowers(1600, true) end)
    if okT and et ~= nil then enemyTowers = et end
    local okT2, at = pcall(function() return thisBot:GetNearbyTowers(1600, false) end)
    if okT2 and at ~= nil then allyTowers = at end

    Blackboard:Set("TacticalState", "NearbyEnemyHeroes", enemyHeroes)
    Blackboard:Set("TacticalState", "NearbyEnemyCreeps", enemyCreeps)
    Blackboard:Set("TacticalState", "NearbyAllyCreeps", allyCreeps)
    Blackboard:Set("TacticalState", "NearbyAllyHeroes", allyHeroes)
    Blackboard:Set("TacticalState", "NearbyNeutralCreeps", neutralCreeps)
    Blackboard:Set("TacticalState", "NearbyEnemyTowers", enemyTowers)
    Blackboard:Set("TacticalState", "NearbyAllyTowers", allyTowers)
    Blackboard:Set("TacticalState", "EnemyHeroCount", #enemyHeroes)
    Blackboard:Set("TacticalState", "EnemyCreepCount", #enemyCreeps)
    Blackboard:Set("TacticalState", "AllyHeroCount", #allyHeroes)

    Blackboard:Set("TacticalState", "TargetEnemyHero", FindLowestHPUnit(enemyHeroes))
    Blackboard:Set("TacticalState", "TargetLowestHPEnemyCreep", FindLowestHPUnit(enemyCreeps))
    Blackboard:Set("TacticalState", "TargetLowestHPAllyCreep", FindLowestHPUnit(allyCreeps))

    -- Threat level
    local threat = 0
    if #enemyHeroes >= 3 then threat = 2
    elseif #enemyHeroes >= 1 then threat = 1 end
    -- Ганк-угроза: если врагов больше союзников рядом
    if #enemyHeroes > #allyHeroes + 1 then threat = 2 end
    Blackboard:Set("TacticalState", "ActiveThreatLevel", threat)

    -- Team fight detection
    local inTF = (#allyHeroes >= 2 and #enemyHeroes >= 2)
    Blackboard:Set("TacticalState", "IsInTeamFight", inTF)

    -- MacroState
    local lane = nil
    local okL, lv = pcall(function() return thisBot:GetLane() end)
    if okL then lane = lv end
    Blackboard:Set("MacroState", "ActiveLane", lane)

    -- Game phase
    local phase = "laning"
    if curTime > 900 then phase = "midgame" end
    if curTime > 2100 then phase = "lategame" end
    Blackboard:Set("MacroState", "GamePhase", phase)

    -- Missing enemies check: если врагов мало рядом при живых союзниках — возможный ганк
    local missing = 0
    -- приблизительно: если threat==0 но game phase midgame, всё ок
    Blackboard:Set("MacroState", "ShouldDefend", (#enemyCreeps == 0 and #allyCreeps == 0 and #enemyHeroes == 0) == false and false or false)
end

-- =========================================================================
-- ЛОГИКА: MACRO
-- =========================================================================
local Logic = {}

function Logic.UpdateMacro(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return end
    local hp = bb:Get("SelfState", "HP") or 1.0
    local gold = bb:Get("SelfState", "Gold") or 0
    local time = bb:Get("MacroState", "CurrentGameTime") or 0

    -- Отступление если HP низкое
    bb:Set("MacroState", "IsRetreating", hp < 0.30)

    -- Push если есть крипы и нет героев рядом
    local ec = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    local eh = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    bb:Set("MacroState", "ShouldPush", (#ec > 0 and #eh == 0 and hp > 0.6))

    -- Defend если вражеские крипы у нашей башни
    local et = bb:Get("TacticalState", "NearbyEnemyTowers") or {}
    -- упрощённо: защищаемся если враги у наших строений
    bb:Set("MacroState", "ShouldDefend", false)
end

-- =========================================================================
-- ЛОГИКА: ECONOMY
-- =========================================================================
function Logic.BuyItems(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return end
    if bot:IsChanneling() or bot:IsUsingAbility() then return end

    local gold = bb:Get("SelfState", "Gold") or 0

    -- Всегда держим TP-свиток
    local hasTP = bb:Get("SelfState", "HasTP")
    if not hasTP then
        local cost = ItemCost("item_tpscroll")
        if gold >= cost then
            local ok = pcall(function() bot:Action_PurchaseItem("item_tpscroll") end)
            if ok then return end
        end
    end

    -- Покупаем по билду
    for _, itemName in ipairs(ITEM_BUILD) do
        local it, slot = HasItem(bot, itemName)
        if it == nil then
            -- проверяем, не куплен ли уже апгрейд/компонент
            local cost = ItemCost(itemName)
            if cost > 0 and gold >= cost then
                -- проверяем свободный слот
                if FreeSlot(bot) >= 0 then
                    local ok = pcall(function() bot:Action_PurchaseItem(itemName) end)
                    if ok then return end
                end
            end
            break -- покупаем по порядку, не пропускаем
        end
    end
end

-- =========================================================================
-- ЛОГИКА: KILL TARGET
-- =========================================================================
function Logic.FindKillTarget(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return nil end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local atkDmg = bb:Get("SelfState", "AttackDamage") or 0
    local spa = bb:Get("SelfState", "SecondsPerAttack") or 1.0
    local shrapnel = FindAbility(bot, ABILITY_SHRAPNEL)
    local assassinate = FindAbility(bot, ABILITY_ASSASSINATE)

    local shrapDmg = 0
    if shrapnel ~= nil and shrapnel:GetLevel() > 0 then
        -- приблизительный урон Shrapnel (зависит от уровня)
        shrapDmg = 30 * shrapnel:GetLevel() + 15 * shrapnel:GetLevel()
    end
    local assassDmg = 0
    if assassinate ~= nil and assassinate:GetLevel() > 0 then
        assassDmg = 250 + 100 * (assassinate:GetLevel() - 1)
    end

    local best = nil
    local bestScore = 0
    for i = 1, #enemies do
        local e = enemies[i]
        if e ~= nil and e:IsAlive() and not e:IsInvulnerable() then
            local eHP = e:GetHealth()
            local eMaxHP = e:GetMaxHealth()
            local dist = Distance(bot:GetLocation(), e:GetLocation())
            local visible = e:IsVisible()

            -- Оценка урона, который можем нанести
            local burst = atkDmg * 4  -- 4 удара
            -- Shrapnel если в радиусе
            local shrRange = (shrapnel ~= nil) and shrapnel:GetCastRange() or 0
            if shrapnel ~= nil and shrapnel:GetLevel() > 0 and shrapnel:GetCooldownTimeRemaining() <= 0
               and bot:GetMana() >= shrapnel:GetManaCost() and dist <= shrRange then
                burst = burst + shrapDmg
            end
            -- Assassinate если в радиусе
            local assRange = (assassinate ~= nil) and assassinate:GetCastRange() or 0
            if assassinate ~= nil and assassinate:GetLevel() > 0 and assassinate:GetCooldownTimeRemaining() <= 0
               and bot:GetMana() >= assassinate:GetManaCost() and dist <= assRange and visible then
                burst = burst + assassDmg
            end

            if eHP <= burst then
                -- приоритет: ниже HP = выше приоритет; также ближе
                local score = (1 - eHP / eMaxHP) * 100 - dist / 100
                if score > bestScore then
                    bestScore = score
                    best = e
                end
            end
        end
    end
    bb:Set("TacticalState", "KillTarget", best)
    bb:Set("TacticalState", "CanKillAnyHero", best ~= nil)
    return best
end

-- =========================================================================
-- ЛОГИКА: COMBAT
-- =========================================================================
function Logic.Combat(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local target = bb:Get("TacticalState", "KillTarget")
    if target == nil then
        target = bb:Get("TacticalState", "TargetEnemyHero")
    end
    if target == nil or not target:IsAlive() then return BT.FAILURE end

    local myPos = bot:GetLocation()
    local tPos = target:GetLocation()
    local dist = Distance(myPos, tPos)
    local attackRange = bb:Get("SelfState", "AttackRange") or 550

    -- Кайтинг: если враг близко — отступаем
    if dist < 400 then
        local away = myPos + (myPos - tPos):Normalized() * 350
        bot:Action_MoveToLocation(away)
        return BT.RUNNING
    end

    -- Assassinate: дальний снайперский выстрел
    local assassinate = FindAbility(bot, ABILITY_ASSASSINATE)
    if assassinate ~= nil and assassinate:GetLevel() > 0 then
        local ready = assassinate:GetCooldownTimeRemaining() <= 0
        local manaOk = bot:GetMana() >= assassinate:GetManaCost()
        local inRange = dist <= assassinate:GetCastRange()
        local visible = target:IsVisible()
        local lowHP = (target:GetHealth() / target:GetMaxHealth()) < 0.5
        if ready and manaOk and inRange and visible then
            -- стреляем если цель низкого HP или это килл-таргет
            if lowHP or (bb:Get("TacticalState", "KillTarget") == target) then
                bot:Action_UseAbilityOnEntity(assassinate, target)
                return BT.RUNNING
            end
        end
    end

    -- Shrapnel: замедление на цель
    local shrapnel = FindAbility(bot, ABILITY_SHRAPNEL)
    if shrapnel ~= nil and shrapnel:GetLevel() > 0 then
        local ready = shrapnel:GetCooldownTimeRemaining() <= 0
        local manaOk = bot:GetMana() >= shrapnel:GetManaCost()
        local inRange = dist <= shrapnel:GetCastRange()
        if ready and manaOk and inRange then
            bot:Action_UseAbilityOnLocation(shrapnel, tPos)
            return BT.RUNNING
        end
    end

    -- Атака
    if dist <= attackRange + 80 then
        bot:Action_AttackUnit(target, true)
        return BT.RUNNING
    else
        bot:Action_MoveToLocation(tPos)
        return BT.RUNNING
    end
end

-- =========================================================================
-- ЛОГИКА: FARMING
-- =========================================================================
function Logic.Farm(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local attackRange = bb:Get("SelfState", "AttackRange") or 550
    local atkDmg = bb:Get("SelfState", "AttackDamage") or 0

    -- Ластхит вражеского крипа
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    local lhTarget = nil
    for i = 1, #enemyCreeps do
        local c = enemyCreeps[i]
        if c ~= nil and c:IsAlive() then
            local d = Distance(bot:GetLocation(), c:GetLocation())
            if d <= attackRange + 60 and c:GetHealth() <= atkDmg + 8 then
                lhTarget = c
                break
            end
        end
    end
    if lhTarget ~= nil then
        bot:Action_AttackUnit(lhTarget, true)
        return BT.RUNNING
    end

    -- Дени союзного крипа
    local allyCreeps = bb:Get("TacticalState", "NearbyAllyCreeps") or {}
    local denyTarget = nil
    for i = 1, #allyCreeps do
        local c = allyCreeps[i]
        if c ~= nil and c:IsAlive() then
            local d = Distance(bot:GetLocation(), c:GetLocation())
            if d <= attackRange + 60 and c:GetHealth() <= atkDmg + 8
               and (c:GetHealth() / c:GetMaxHealth()) < 0.55 then
                denyTarget = c
                break
            end
        end
    end
    if denyTarget ~= nil then
        bot:Action_AttackUnit(denyTarget, true)
        return BT.RUNNING
    end

    -- Джангл: атакуем нейтрального крипа с наименьшим HP
    local neutrals = bb:Get("TacticalState", "NearbyNeutralCreeps") or {}
    if #neutrals > 0 then
        local nTarget = FindLowestHPUnit(neutrals)
        if nTarget ~= nil then
            local d = Distance(bot:GetLocation(), nTarget:GetLocation())
            if d <= attackRange + 60 then
                bot:Action_AttackUnit(nTarget, true)
                return BT.RUNNING
            else
                bot:Action_MoveToLocation(nTarget:GetLocation())
                return BT.RUNNING
            end
        end
    end

    -- Если ничего не делать — харасим вражеского героя автоатакой, если безопасно
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local threat = bb:Get("TacticalState", "ActiveThreatLevel") or 0
    if #enemies > 0 and threat == 0 then
        local e = enemies[1]
        if e ~= nil and e:IsAlive() then
            local d = Distance(bot:GetLocation(), e:GetLocation())
            if d <= attackRange + 80 then
                bot:Action_AttackUnit(e, true)
                return BT.RUNNING
            end
        end
    end

    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: RETREAT
-- =========================================================================
function Logic.Retreat(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0

    -- Buyback если мёртв/очень низко — handled by engine respawn; здесь только отступление
    local fountain = GetFountainLoc(bot)
    if fountain == nil then return BT.FAILURE end

    -- Если есть TP — используем
    local hasTP = bb:Get("SelfState", "HasTP")
    if hasTP and hp < 0.20 then
        local tp, _ = HasItem(bot, "item_tpscroll")
        if tp ~= nil then
            bot:Action_UseAbilityOnLocation(tp, fountain)
            return BT.RUNNING
        end
    end

    bot:Action_MoveToLocation(fountain)
    return BT.RUNNING
end

-- =========================================================================
-- ЛОГИКА: LANING / POSITIONING
-- =========================================================================
function Logic.Lane(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local allyCreeps = bb:Get("TacticalState", "NearbyAllyCreeps") or {}
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local hp = bb:Get("SelfState", "HP") or 1.0

    -- Если враги рядом и HP низкое — держим дистанцию
    if #enemies > 0 and hp < 0.5 then
        local e = enemies[1]
        local away = bot:GetLocation() + (bot:GetLocation() - e:GetLocation()):Normalized() * 400
        bot:Action_MoveToLocation(away)
        return BT.RUNNING
    end

    -- Держимся за союзным крип-вейвом
    if #allyCreeps > 0 then
        local sumX, sumY, n = 0, 0, 0
        for i = 1, #allyCreeps do
            local c = allyCreeps[i]
            if c ~= nil and c:IsAlive() then
                local l = c:GetLocation()
                sumX = sumX + l.x; sumY = sumY + l.y; n = n + 1
            end
        end
        if n > 0 then
            local center = Vector(sumX / n, sumY / n, 0)
            -- стоять чуть позади крипов
            local myPos = bot:GetLocation()
            local toCenter = center - myPos
            if toCenter:Length2D() > 120 then
                -- двигаемся к точке позади центра вейва
                local back = center + (myPos - center):Normalized() * 200
                bot:Action_MoveToLocation(back)
                return BT.RUNNING
            end
        end
    end

    -- Если нет крипов — двигаемся к линии
    local team = bot:GetTeam()
    local lane = bb:Get("MacroState", "ActiveLane")
    if lane == nil then lane = LANE_MID end
    local ok, front = pcall(GetLaneFrontLocation, team, lane, 0.45)
    if ok and front ~= nil then
        bot:Action_MoveToLocation(front)
        return BT.RUNNING
    end

    return BT.RUNNING
end

-- =========================================================================
-- ЛОГИКА: WARDS (наблюдение/сторожевые)
-- =========================================================================
local WARD_SPOTS = {
    -- ключевые точки карты (приблизительно)
    Vector(-4200, -3800, 0), Vector(4200, 3800, 0),
    Vector(-1800, 1200, 0), Vector(1800, -1200, 0),
    Vector(0, 0, 0),
}

function Logic.PlaceWard(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    -- Ищем вард в инвентаре
    local wardItem = nil
    for i = 0, 15 do
        local it = bot:GetItemInSlot(i)
        if it ~= nil then
            local n = it:GetName()
            if n == "item_ward_observer" or n == "item_ward_sentry" then
                wardItem = it
                break
            end
        end
    end
    if wardItem == nil then return BT.FAILURE end

    -- Выбираем точку варда: ближайшая из WARD_SPOTS, где нет видимости
    local myPos = bot:GetLocation()
    local bestSpot, bestDist = nil, 1e9
    for i = 1, #WARD_SPOTS do
        local sp = WARD_SPOTS[i]
        local d = Distance(myPos, sp)
        if d < bestDist and d <= 1600 then
            -- проверяем видимость
            local vis = true
            local ok, v = pcall(IsLocationVisible, sp)
            if ok then vis = v end
            if not vis then
                bestDist = d
                bestSpot = sp
            end
        end
    end
    if bestSpot == nil then return BT.FAILURE end

    -- ставим вард если в радиусе каста
    local d = Distance(myPos, bestSpot)
    if d <= 500 then
        bot:Action_UseAbilityOnLocation(wardItem, bestSpot)
        return BT.RUNNING
    else
        bot:Action_MoveToLocation(bestSpot)
        return BT.RUNNING
    end
end

-- =========================================================================
-- ЛОГИКА: RUNES
-- =========================================================================
function Logic.CollectRune(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    -- Проверяем руны поблизости (bounty/powerup)
    local runes = {}
    local ok, r = pcall(function() return GetRuneLocations() end)
    if ok and r ~= nil then runes = r end

    local myPos = bot:GetLocation()
    local bestRune, bestDist = nil, 1e9
    for i = 1, #runes do
        local rl = runes[i]
        local loc = nil
        if type(rl) == "table" then loc = rl.location or rl end
        if loc ~= nil then
            local d = Distance(myPos, loc)
            if d < bestDist and d <= 2000 then
                bestDist = d
                bestRune = loc
            end
        end
    end
    if bestRune == nil then return BT.FAILURE end
    if bestDist <= 150 then
        -- просто подойти; руна подбирается автоматически
        bot:Action_MoveToLocation(bestRune)
        return BT.RUNNING
    end
    bot:Action_MoveToLocation(bestRune)
    return BT.RUNNING
end

-- =========================================================================
-- ЛОГИКА: ROSHAN
-- =========================================================================
function Logic.Roshan(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local allies = bb:Get("TacticalState", "NearbyAllyHeroes") or {}
    -- Идём на Рошана только если достаточно союзников и нет врагов рядом
    if #allies < 2 then return BT.FAILURE end
    if #enemies > 0 then return BT.FAILURE end

    local ok, rloc = pcall(function() return GetRoshanLocation() end)
    if not ok or rloc == nil then return BT.FAILURE end

    local myPos = bot:GetLocation()
    local d = Distance(myPos, rloc)
    if d <= 300 then
        -- атакуем Рошана
        -- находим Roshan unit
        local rosh = nil
        local ok2, units = pcall(function() return GetUnitList(UNIT_LIST_ALL) end)
        if ok2 and units ~= nil then
            for i = 1, #units do
                local u = units[i]
                if u ~= nil and u:GetName() == "npc_dota_roshan" and u:IsAlive() then
                    rosh = u
                    break
                end
            end
        end
        if rosh ~= nil then
            bot:Action_AttackUnit(rosh, true)
            return BT.RUNNING
        end
    else
        bot:Action_MoveToLocation(rloc)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: OBJECTIVE / PUSH
-- =========================================================================
function Logic.PushObjective(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    if hp < 0.5 then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies > 0 then return BT.FAILURE end

    -- Ищем ближайшую вражескую башню
    local towers = bb:Get("TacticalState", "NearbyEnemyTowers") or {}
    if #towers == 0 then
        -- поиск по всей карте
        local ok, all = pcall(function() return GetUnitList(UNIT_LIST_ENEMY) end)
        if ok and all ~= nil then
            for i = 1, #all do
                local u = all[i]
                if u ~= nil and u:IsAlive() and u:IsTower() then
                    table.insert(towers, u)
                end
            end
        end
    end
    if #towers == 0 then return BT.FAILURE end
    local t = FindLowestHPUnit(towers)
    if t == nil then return BT.FAILURE end

    local myPos = bot:GetLocation()
    local d = Distance(myPos, t:GetLocation())
    local attackRange = bb:Get("SelfState", "AttackRange") or 550
    if d <= attackRange + 80 then
        bot:Action_AttackUnit(t, true)
        return BT.RUNNING
    else
        bot:Action_MoveToLocation(t:GetLocation())
        return BT.RUNNING
    end
end

-- =========================================================================
-- ЛОГИКА: DEFEND BASE
-- =========================================================================
function Logic.DefendBase(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    -- Если вражеские крипы у нашей базы/фонтана
    local allyTowers = bb:Get("TacticalState", "NearbyAllyTowers") or {}
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    local fountain = GetFountainLoc(bot)
    if fountain == nil then return BT.FAILURE end

    -- Если крипы близко к фонтану
    local danger = false
    for i = 1, #enemyCreeps do
        local c = enemyCreeps[i]
        if c ~= nil and c:IsAlive() then
            if Distance(c:GetLocation(), fountain) < 2500 then
                danger = true
                break
            end
        end
    end
    if not danger then return BT.FAILURE end

    -- Атакуем ближайшего вражеского крипа
    local target = FindLowestHPUnit(enemyCreeps)
    if target ~= nil then
        bot:Action_AttackUnit(target, true)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: TEAM FIGHT POSITIONING
-- =========================================================================
function Logic.TeamFight(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local allies = bb:Get("TacticalState", "NearbyAllyHeroes") or {}
    if #enemies < 2 or #allies < 2 then return BT.FAILURE end

    -- Sniper держится на максимальной дистанции атаки от ближайшего врага
    local nearestEnemy = nil
    local nearDist = 1e9
    for i = 1, #enemies do
        local e = enemies[i]
        if e ~= nil and e:IsAlive() then
            local d = Distance(bot:GetLocation(), e:GetLocation())
            if d < nearDist then nearDist = d; nearestEnemy = e end
        end
    end
    if nearestEnemy == nil then return BT.FAILURE end

    local attackRange = bb:Get("SelfState", "AttackRange") or 550
    local myPos = bot:GetLocation()
    local ePos = nearestEnemy:GetLocation()

    -- Если враг близко — отступаем
    if nearDist < attackRange * 0.6 then
        local away = myPos + (myPos - ePos):Normalized() * 400
        bot:Action_MoveToLocation(away)
        return BT.RUNNING
    end

    -- Если цель вне радиуса атаки — двигаемся к ней, но держим дистанцию
    local killTarget = bb:Get("TacticalState", "KillTarget")
    local target = killTarget or bb:Get("TacticalState", "TargetEnemyHero")
    if target ~= nil and target:IsAlive() then
        local d = Distance(myPos, target:GetLocation())
        if d > attackRange then
            bot:Action_MoveToLocation(target:GetLocation())
            return BT.RUNNING
        else
            -- Shrapnel + атака
            local shrapnel = FindAbility(bot, ABILITY_SHRAPNEL)
            if shrapnel ~= nil and shrapnel:GetLevel() > 0
               and shrapnel:GetCooldownTimeRemaining() <= 0
               and bot:GetMana() >= shrapnel:GetManaCost() then
                bot:Action_UseAbilityOnLocation(shrapnel, target:GetLocation())
                return BT.RUNNING
            end
            bot:Action_AttackUnit(target, true)
            return BT.RUNNING
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: SKILL BUILD
-- =========================================================================
local SKILL_BUILD = {
    "sniper_shrapnel",
    "sniper_take_aim",
    "sniper_shrapnel",
    "sniper_headshot",
    "sniper_shrapnel",
    "sniper_assassinate",
    "sniper_shrapnel",
    "sniper_take_aim",
    "sniper_take_aim",
    "sniper_headshot",
    "sniper_assassinate",
    "sniper_take_aim",
    "sniper_headshot",
    "sniper_headshot",
    "sniper_take_aim",
    "sniper_assassinate",
    "sniper_headshot",
    "sniper_take_aim",
    "sniper_headshot",
    "sniper_take_aim",
    "sniper_headshot",
    "sniper_take_aim",
    "sniper_headshot",
    "sniper_take_aim",
}

function Logic.LevelAbilities(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return end
    local pts = 0
    local ok, p = pcall(function() return bot:GetAbilityPoints() end)
    if ok and type(p) == "number" then pts = p end
    if pts <= 0 then return end
    local level = bot:GetLevel()
    local idx = math.min(level, #SKILL_BUILD)
    local wanted = SKILL_BUILD[idx]
    if wanted == nil then return end
    -- уровень способности если не прокачана
    local ab = FindAbility(bot, wanted)
    if ab ~= nil then
        local curLvl = ab:GetLevel()
        local targetLvl = 0
        -- посчитаем сколько раз wanted встречается до idx
        for i = 1, idx do
            if SKILL_BUILD[i] == wanted then targetLvl = targetLvl + 1 end
        end
        if curLvl < targetLvl then
            pcall(function() bot:Action_LevelAbility(wanted) end)
        end
    end
end

-- =========================================================================
-- ЛОГИКА: ITEM USAGE (BKB, Hurricane Pike, Satanic и т.д.)
-- =========================================================================
function Logic.UseItems(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    if bot:IsChanneling() or bot:IsUsingAbility() then return BT.FAILURE end

    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local hp = bb:Get("SelfState", "HP") or 1.0
    local myPos = bot:GetLocation()

    -- BKB: активируем при угрозе или стане
    local bkb, _ = HasItem(bot, "item_black_king_bar")
    if bkb ~= nil then
        local ready = bkb:GetCooldownTimeRemaining() <= 0
        local threat = bb:Get("TacticalState", "ActiveThreatLevel") or 0
        if ready and (threat >= 2 or #enemies >= 2) and hp < 0.7 then
            pcall(function() bot:Action_UseAbility(bkb) end)
            return BT.RUNNING
        end
    end

    -- Hurricane Pike: отскок от близкого врага
    local pike, _ = HasItem(bot, "item_hurricane_pike")
    if pike ~= nil then
        local ready = pike:GetCooldownTimeRemaining() <= 0
        if ready and #enemies > 0 then
            local nearest = enemies[1]
            local d = Distance(myPos, nearest:GetLocation())
            if d < 350 then
                pcall(function() bot:Action_UseAbilityOnEntity(pike, nearest) end)
                return BT.RUNNING
            end
        end
    end

    -- Satanic: активируем при низком HP в бою
    local satanic, _ = HasItem(bot, "item_satanic")
    if satanic ~= nil then
        local ready = satanic:GetCooldownTimeRemaining() <= 0
        if ready and hp < 0.4 and #enemies > 0 then
            pcall(function() bot:Action_UseAbility(satanic) end)
            return BT.RUNNING
        end
    end

    -- Shadow Blade / Silver Edge: инициация/побег
    local sb, _ = HasItem(bot, "item_shadow_blade")
    if sb == nil then sb, _ = HasItem(bot, "item_silver_edge") end
    if sb ~= nil then
        local ready = sb:GetCooldownTimeRemaining() <= 0
        if ready then
            -- побег при низком HP
            if hp < 0.25 and #enemies > 0 then
                pcall(function() bot:Action_UseAbility(sb) end)
                return BT.RUNNING
            end
        end
    end

    -- Mjollnir active (если есть)
    local mj, _ = HasItem(bot, "item_mjollnir")
    if mj ~= nil then
        local ready = mj:GetCooldownTimeRemaining() <= 0
        if ready and #enemies >= 2 then
            pcall(function() bot:Action_UseAbilityOnEntity(mj, bot) end)
            return BT.RUNNING
        end
    end

    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: CONSUMABLES
-- =========================================================================
function Logic.BuyConsumables(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return end
    local gold = bb:Get("SelfState", "Gold") or 0
    local hp = bb:Get("SelfState", "HP") or 1.0
    local mp = bb:Get("SelfState", "MP") or 1.0

    -- Tango если HP низкое и нет танго
    local hasTango = false
    for i = 0, 15 do
        local it = bot:GetItemInSlot(i)
        if it ~= nil and it:GetName() == "item_tango" then hasTango = true end
    end
    if not hasTango and gold >= ItemCost("item_tango") and hp < 0.7 then
        pcall(function() bot:Action_PurchaseItem("item_tango") end)
    end

    -- Healing Salve
    local hasSalve = false
    for i = 0, 15 do
        local it = bot:GetItemInSlot(i)
        if it ~= nil and it:GetName() == "item_flask" then hasSalve = true end
    end
    if not hasSalve and gold >= ItemCost("item_flask") and hp < 0.4 then
        pcall(function() bot:Action_PurchaseItem("item_flask") end)
    end

    -- Clarity
    local hasClarity = false
    for i = 0, 15 do
        local it = bot:GetItemInSlot(i)
        if it ~= nil and it:GetName() == "item_clarity" then hasClarity = true end
    end
    if not hasClarity and gold >= ItemCost("item_clarity") and mp < 0.4 then
        pcall(function() bot:Action_PurchaseItem("item_clarity") end)
    end

    -- Observer ward если нет
    local hasWard = false
    for i = 0, 15 do
        local it = bot:GetItemInSlot(i)
        if it ~= nil and it:GetName() == "item_ward_observer" then hasWard = true end
    end
    if not hasWard and gold >= ItemCost("item_ward_observer") then
        -- покупаем только если есть слот и золота достаточно
        if FreeSlot(bot) >= 0 then
            pcall(function() bot:Action_PurchaseItem("item_ward_observer") end)
        end
    end

    -- Smoke of Deceit
    local hasSmoke = false
    for i = 0, 15 do
        local it = bot:GetItemInSlot(i)
        if it ~= nil and it:GetName() == "item_smoke_of_deceit" then hasSmoke = true end
    end
    if not hasSmoke and gold >= ItemCost("item_smoke_of_deceit") and FreeSlot(bot) >= 0 then
        pcall(function() bot:Action_PurchaseItem("item_smoke_of_deceit") end)
    end
end

-- =========================================================================
-- ЛОГИКА: ORB-WALKING (анимация-кансел)
-- =========================================================================
function Logic.OrbWalk(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local target = bb:Get("TacticalState", "TargetEnemyHero")
    if target == nil or not target:IsAlive() then return BT.FAILURE end
    local attackRange = bb:Get("SelfState", "AttackRange") or 550
    local myPos = bot:GetLocation()
    local tPos = target:GetLocation()
    local dist = Distance(myPos, tPos)

    if dist <= attackRange + 40 then
        -- атакуем
        bot:Action_AttackUnit(target, true)
        return BT.RUNNING
    else
        -- двигаемся к цели
        bot:Action_MoveToLocation(tPos)
        return BT.RUNNING
    end
end

-- =========================================================================
-- ЛОГИКА: LAST HIT С УЧЁТОМ ВРЕМЕНИ ПОЛЁТА СНАРЯДА
-- =========================================================================
function Logic.PredictedLastHit(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local attackRange = bb:Get("SelfState", "AttackRange") or 550
    local atkDmg = bb:Get("SelfState", "AttackDamage") or 0
    local projSpeed = 3000
    local ok, ps = pcall(function() return bot:GetProjectileSpeed() end)
    if ok and type(ps) == "number" and ps > 0 then projSpeed = ps end

    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    local bestTarget, bestTime = nil, 1e9
    for i = 1, #enemyCreeps do
        local c = enemyCreeps[i]
        if c ~= nil and c:IsAlive() then
            local d = Distance(bot:GetLocation(), c:GetLocation())
            if d <= attackRange + 60 then
                local travelTime = d / projSpeed
                local creepHP = c:GetHealth()
                -- урон крипа по себе (реген) за время полёта пренебрегаем
                if creepHP <= atkDmg and travelTime < bestTime then
                    bestTime = travelTime
                    bestTarget = c
                end
            end
        end
    end
    if bestTarget ~= nil then
        bot:Action_AttackUnit(bestTarget, true)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: TOWER DIVING SAFETY
-- =========================================================================
function Logic.TowerDiveCheck(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return false end
    local enemyTowers = bb:Get("TacticalState", "NearbyEnemyTowers") or {}
    local hp = bb:Get("SelfState", "HP") or 1.0
    for i = 1, #enemyTowers do
        local t = enemyTowers[i]
        if t ~= nil and t:IsAlive() then
            local d = Distance(bot:GetLocation(), t:GetLocation())
            if d <= 900 and hp < 0.7 then
                return false -- не дайвим
            end
        end
    end
    return true
end

-- =========================================================================
-- ЛОГИКА: LANE SELECTION (выбор линии при старте)
-- =========================================================================
function Logic.SelectLane(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return end
    local lane = bb:Get("MacroState", "ActiveLane")
    if lane ~= nil then return end
    -- Sniper обычно идёт на сейф-лейн (бот/топ в зависимости от стороны)
    local team = bot:GetTeam()
    -- Radiant: сейф лейн = бот; Dire: сейф лейн = топ
    local safeLane = (team == TEAM_RADIANT) and LANE_BOT or LANE_TOP
    bb:Set("MacroState", "ActiveLane", safeLane)
    bb:Set("MacroState", "FarmLane", safeLane)
end

-- =========================================================================
-- ЛОГИКА: BUYBACK DECISION
-- =========================================================================
function Logic.BuybackDecision(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return end
    local hasBB = bb:Get("SelfState", "BuybackAvailable")
    if not hasBB then return end
    -- Логика buyback принимается движком при смерти; здесь только флаг
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    -- если враги пушат базу и есть buyback — помечаем
    local fountain = GetFountainLoc(bot)
    if fountain ~= nil then
        local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
        local nearBase = false
        for i = 1, #enemyCreeps do
            local c = enemyCreeps[i]
            if c ~= nil and c:IsAlive() and Distance(c:GetLocation(), fountain) < 3000 then
                nearBase = true
                break
            end
        end
        if nearBase then
            bb:Set("MacroState", "BuybackStatus", true)
        end
    end
end

-- =========================================================================
-- ЛОГИКА: ECONOMY UPGRADE PATH
-- =========================================================================
local UPGRADE_PATH = {
    ["item_wraith_band"] = "item_null_talisman",
}

function Logic.UpgradeItems(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return end
    local gold = bb:Get("SelfState", "Gold") or 0
    for i = 0, 5 do
        local it = bot:GetItemInSlot(i)
        if it ~= nil then
            local name = it:GetName()
            -- Dragon Lance -> Hurricane Pike (recipe)
            if name == "item_dragon_lance" then
                local hasPike = (HasItem(bot, "item_hurricane_pike") ~= nil)
                if not hasPike then
                    local recipeCost = ItemCost("item_hurricane_pike") - ItemCost("item_dragon_lance") - ItemCost("item_force_staff")
                    if gold >= recipeCost and recipeCost > 0 then
                        -- покупаем force_staff если нет
                        local fs, _ = HasItem(bot, "item_force_staff")
                        if fs == nil and gold >= ItemCost("item_force_staff") then
                            pcall(function() bot:Action_PurchaseItem("item_force_staff") end)
                        end
                    end
                end
            end
        end
    end
end

-- =========================================================================
-- ЛОГИКА: CREEP AGGRO / LANE EQUILIBRIUM
-- =========================================================================
function Logic.ManageCreepAggro(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    local allyCreeps = bb:Get("TacticalState", "NearbyAllyCreeps") or {}
    if #enemyCreeps == 0 then return BT.FAILURE end

    -- Если союзных крипов больше вражеских — атакуем вражеских чтобы пушить
    -- Если меньше — не атакуем крипов, ждём
    local attackRange = bb:Get("SelfState", "AttackRange") or 550
    if #allyCreeps >= #enemyCreeps then
        -- пушим: атакуем ближайшего вражеского крипа
        local t = FindLowestHPUnit(enemyCreeps)
        if t ~= nil then
            local d = Distance(bot:GetLocation(), t:GetLocation())
            if d <= attackRange + 60 then
                bot:Action_AttackUnit(t, true)
                return BT.RUNNING
            end
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: STACKING CAMPS
-- =========================================================================
function Logic.StackCamps(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    -- Стекаем нейтральный кемп за ~53 секунды до полной минуты
    local time = bb:Get("MacroState", "CurrentGameTime") or 0
    local sec = time % 60
    if sec < 50 or sec > 56 then return BT.FAILURE end

    local neutrals = bb:Get("TacticalState", "NearbyNeutralCreeps") or {}
    if #neutrals == 0 then return BT.FAILURE end

    -- находим кемп (первый нейтрал)
    local camp = neutrals[1]
    if camp == nil then return BT.FAILURE end
    local cLoc = camp:GetLocation()
    -- отводим крипов от кемпа за 5 сек до минуты
    local away = cLoc + (bot:GetLocation() - cLoc):Normalized() * 400
    -- если крипы рядом с нами — отводим
    local nDist = Distance(bot:GetLocation(), cLoc)
    if nDist < 200 then
        bot:Action_MoveToLocation(away)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: PULLING
-- =========================================================================
function Logic.Pull(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    local allyCreeps = bb:Get("TacticalState", "NearbyAllyCreeps") or {}
    -- Пуллим если есть союзные и вражеские крипы на линии
    if #allyCreeps == 0 or #enemyCreeps == 0 then return BT.FAILURE end

    -- атакуем вражеского крипа чтобы привлечь внимание, потом отводим
    local target = FindLowestHPUnit(enemyCreeps)
    if target == nil then return BT.FAILURE end
    local d = Distance(bot:GetLocation(), target:GetLocation())
    local attackRange = bb:Get("SelfState", "AttackRange") or 550
    if d <= attackRange + 60 then
        bot:Action_AttackUnit(target, true)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: GANKING (smoke + TP)
-- =========================================================================
function Logic.Gank(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    if hp < 0.6 then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    -- ганкаем если нет врагов рядом (мы в дыму или вне видимости)
    if #enemies > 0 then return BT.FAILURE end

    -- Используем smoke если есть
    local smoke, _ = HasItem(bot, "item_smoke_of_deceit")
    if smoke ~= nil and smoke:GetCooldownTimeRemaining() <= 0 then
        pcall(function() bot:Action_UseAbility(smoke) end)
        return BT.RUNNING
    end

    -- Ищем цель для ганка: вражеский герой с низким HP на карте
    -- Используем GetUnitList
    local target = nil
    local ok, units = pcall(function() return GetUnitList(UNIT_LIST_ENEMY_HEROES) end)
    if ok and units ~= nil then
        for i = 1, #units do
            local u = units[i]
            if u ~= nil and u:IsAlive() and not u:IsInvulnerable() then
                local uHP = u:GetHealth() / u:GetMaxHealth()
                if uHP < 0.5 then
                    target = u
                    break
                end
            end
        end
    end
    if target == nil then return BT.FAILURE end

    -- TP к ближайшей башне/союзному герою рядом с целью
    local tp, _ = HasItem(bot, "item_tpscroll")
    if tp ~= nil and tp:GetCooldownTimeRemaining() <= 0 then
        -- TP к локации цели (приблизительно)
        pcall(function() bot:Action_UseAbilityOnLocation(tp, target:GetLocation()) end)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: MAP AWARENESS (пропавшие враги)
-- =========================================================================
function Logic.MapAwareness(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local allies = bb:Get("TacticalState", "NearbyAllyHeroes") or {}
    local hp = bb:Get("SelfState", "HP") or 1.0

    -- Если врагов мало рядом, но игра в мид/лейт — возможный ганк
    local phase = bb:Get("MacroState", "GamePhase") or "laning"
    if phase ~= "laning" and #enemies == 0 and #allies <= 1 then
        -- отступаем к безопасной позиции
        local fountain = GetFountainLoc(bot)
        if fountain ~= nil and hp < 0.6 then
            bot:Action_MoveToLocation(fountain)
            return BT.RUNNING
        end
    end

    -- Если врагов много рядом — отступаем
    if #enemies >= 3 and #allies < #enemies then
        local fountain = GetFountainLoc(bot)
        if fountain ~= nil then
            bot:Action_MoveToLocation(fountain)
            return BT.RUNNING
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: REACTIVE ITEMS (Manta, Linken и т.д.)
-- =========================================================================
function Logic.ReactiveItems(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    -- Manta: снимаем сайленс/хекс
    local manta, _ = HasItem(bot, "item_manta")
    if manta ~= nil then
        local ready = manta:GetCooldownTimeRemaining() <= 0
        if ready and (bot:IsSilenced() or bot:IsHexed()) then
            pcall(function() bot:Action_UseAbility(manta) end)
            return BT.RUNNING
        end
    end
    -- Eul's: снимаем сайленс на себя или врага
    local euls, _ = HasItem(bot, "item_cyclone")
    if euls ~= nil then
        local ready = euls:GetCooldownTimeRemaining() <= 0
        if ready and bot:IsSilenced() then
            pcall(function() bot:Action_UseAbilityOnEntity(euls, bot) end)
            return BT.RUNNING
        end
    end
    -- Glimmer Cape: невидимость при угрозе
    local glimmer, _ = HasItem(bot, "item_glimmer_cape")
    if glimmer ~= nil then
        local ready = glimmer:GetCooldownTimeRemaining() <= 0
        local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
        local hp = bb:Get("SelfState", "HP") or 1.0
        if ready and #enemies > 0 and hp < 0.4 then
            pcall(function() bot:Action_UseAbilityOnEntity(glimmer, bot) end)
            return BT.RUNNING
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- BUILD BEHAVIOR TREE
-- =========================================================================
function BuildBehaviorTree()
    local condLowHP = BT.Condition:new({
        name = "CheckLowHealth",
        eval = function(npcBot, blackboard)
            local hp = blackboard:Get("SelfState", "HP") or 1.0
            return hp < 0.30
        end
    })

    local condKillTarget = BT.Condition:new({
        name = "CheckKillTarget",
        eval = function(npcBot, blackboard)
            return blackboard:Get("TacticalState", "CanKillAnyHero") == true
        end
    })

    local condEnemyHero = BT.Condition:new({
        name = "CheckEnemyHeroPresent",
        eval = function(npcBot, blackboard)
            return blackboard:Get("TacticalState", "TargetEnemyHero") ~= nil
        end
    })

    local condCreeps = BT.Condition:new({
        name = "CheckCreepsInRadius",
        eval = function(npcBot, blackboard)
            local creeps = blackboard:Get("TacticalState", "NearbyEnemyCreeps") or {}
            local neutrals = blackboard:Get("TacticalState", "NearbyNeutralCreeps") or {}
            return #creeps > 0 or #neutrals > 0
        end
    })

    local condTeamFight = BT.Condition:new({
        name = "CheckTeamFight",
        eval = function(npcBot, blackboard)
            return blackboard:Get("TacticalState", "IsInTeamFight") == true
        end
    })

    local condShouldPush = BT.Condition:new({
        name = "CheckShouldPush",
        eval = function(npcBot, blackboard)
            return blackboard:Get("MacroState", "ShouldPush") == true
        end
    })

    local condShouldDefend = BT.Condition:new({
        name = "CheckShouldDefend",
        eval = function(npcBot, blackboard)
            local ec = blackboard:Get("TacticalState", "NearbyEnemyCreeps") or {}
            local fountain = nil
            -- defend if enemy creeps near base (checked in Logic.DefendBase)
            return #ec > 0
        end
    })

    -- Actions
    local actRetreat = BT.Action:new({
        name = "ExecuteRetreat",
        execute = function(npcBot, blackboard)
            return Logic.Retreat(blackboard)
        end
    })

    local actItems = BT.Action:new({
        name = "ExecuteUseItems",
        execute = function(npcBot, blackboard) return Logic.UseItems(blackboard) end
    })
    local actReactive = BT.Action:new({
        name = "ExecuteReactiveItems",
        execute = function(npcBot, blackboard) return Logic.ReactiveItems(blackboard) end
    })
    local actWard2 = BT.Action:new({
        name = "ExecutePlaceWard2",
        execute = function(npcBot, blackboard) return Logic.PlaceWard(blackboard) end
    })
    local actRune2 = BT.Action:new({
        name = "ExecuteCollectRune2",
        execute = function(npcBot, blackboard) return Logic.CollectRune(blackboard) end
    })
    local actRoshan2 = BT.Action:new({
        name = "ExecuteRoshan2",
        execute = function(npcBot, blackboard) return Logic.Roshan(blackboard) end
    })
    local actPush2 = BT.Action:new({
        name = "ExecutePushObjective2",
        execute = function(npcBot, blackboard) return Logic.PushObjective(blackboard) end
    })
    local actDefend2 = BT.Action:new({
        name = "ExecuteDefendBase2",
        execute = function(npcBot, blackboard) return Logic.DefendBase(blackboard) end
    })
    local actTeamFight2 = BT.Action:new({
        name = "ExecuteTeamFight2",
        execute = function(npcBot, blackboard) return Logic.TeamFight(blackboard) end
    })
    local actMapAware = BT.Action:new({
        name = "ExecuteMapAwareness",
        execute = function(npcBot, blackboard) return Logic.MapAwareness(blackboard) end
    })
    local actGank = BT.Action:new({
        name = "ExecuteGank",
        execute = function(npcBot, blackboard) return Logic.Gank(blackboard) end
    })
    local actCreepAggro = BT.Action:new({
        name = "ExecuteCreepAggro",
        execute = function(npcBot, blackboard) return Logic.ManageCreepAggro(blackboard) end
    })
    local actStack = BT.Action:new({
        name = "ExecuteStackCamps",
        execute = function(npcBot, blackboard) return Logic.StackCamps(blackboard) end
    })
    local actPull = BT.Action:new({
        name = "ExecutePull",
        execute = function(npcBot, blackboard) return Logic.Pull(blackboard) end
    })

    local actCombat = BT.Action:new({
        name = "ExecuteCombat",
        execute = function(npcBot, blackboard)
            Logic.FindKillTarget(blackboard)
            return Logic.Combat(blackboard)
        end
    })

    local actFarm = BT.Action:new({
        name = "ExecuteFarm",
        execute = function(npcBot, blackboard)
            return Logic.Farm(blackboard)
        end
    })

    local actLane = BT.Action:new({
        name = "ExecuteLaningPosition",
        execute = function(npcBot, blackboard)
            return Logic.Lane(blackboard)
        end
    })

    -- Actions (new)
    local actWard = BT.Action:new({
        name = "ExecutePlaceWard",
        execute = function(npcBot, blackboard) return Logic.PlaceWard(blackboard) end
    })
    local actRune = BT.Action:new({
        name = "ExecuteCollectRune",
        execute = function(npcBot, blackboard) return Logic.CollectRune(blackboard) end
    })
    local actRoshan = BT.Action:new({
        name = "ExecuteRoshan",
        execute = function(npcBot, blackboard) return Logic.Roshan(blackboard) end
    })
    local actPush = BT.Action:new({
        name = "ExecutePushObjective",
        execute = function(npcBot, blackboard) return Logic.PushObjective(blackboard) end
    })
    local actDefend = BT.Action:new({
        name = "ExecuteDefendBase",
        execute = function(npcBot, blackboard) return Logic.DefendBase(blackboard) end
    })
    local actTeamFight = BT.Action:new({
        name = "ExecuteTeamFight",
        execute = function(npcBot, blackboard) return Logic.TeamFight(blackboard) end
    })

    -- Conditions
    local condHasWard = BT.Condition:new({
        name = "CheckHasWard",
        eval = function(npcBot, blackboard)
            local bot = blackboard:GetBotRef()
            if bot == nil then return false end
            for i = 0, 15 do
                local it = bot:GetItemInSlot(i)
                if it ~= nil then
                    local n = it:GetName()
                    if n == "item_ward_observer" or n == "item_ward_sentry" then return true end
                end
            end
            return false
        end
    })

    -- Conditions
    local condHasWard2 = BT.Condition:new({
        name = "CheckHasWard2",
        eval = function(npcBot, blackboard)
            local bot = blackboard:GetBotRef()
            if bot == nil then return false end
            for i = 0, 15 do
                local it = bot:GetItemInSlot(i)
                if it ~= nil then
                    local n = it:GetName()
                    if n == "item_ward_observer" or n == "item_ward_sentry" then return true end
                end
            end
            return false
        end
    })

    -- Sequences
    local seqRetreat = BT.BuildSequence("EmergencyRetreat", { condLowHP, actRetreat })
    local seqReactive = BT.BuildSequence("ReactiveItems", { actReactive })
    local seqKill    = BT.BuildSequence("KillHero", { condKillTarget, actCombat })
    local seqTeamFight = BT.BuildSequence("TeamFight", { condTeamFight, actTeamFight2 })
    local seqDefend  = BT.BuildSequence("DefendBase", { actDefend2 })
    local seqPush    = BT.BuildSequence("PushObjective", { condShouldPush, actPush2 })
    local seqGank    = BT.BuildSequence("Gank", { actGank })
    local seqMapAware = BT.BuildSequence("MapAwareness", { actMapAware })
    local seqRoshan  = BT.BuildSequence("Roshan", { actRoshan2 })
    local seqCombat  = BT.BuildSequence("MicroCombat", { condEnemyHero, actCombat })
    local seqWard    = BT.BuildSequence("PlaceWard", { condHasWard2, actWard2 })
    local seqRune    = BT.BuildSequence("CollectRune", { actRune2 })
    local seqCreepAggro = BT.BuildSequence("CreepAggro", { actCreepAggro })
    local seqStack   = BT.BuildSequence("StackCamps", { actStack })
    local seqPull    = BT.BuildSequence("Pull", { actPull })
    local seqItems   = BT.BuildSequence("UseItems", { actItems })
    local seqCreep   = BT.BuildSequence("CreepMicro", { condCreeps, actFarm })
    local seqLane    = BT.BuildSequence("IdleLaningMacro", { actLane })

    -- Root Selector
    local root = BT.BuildSelector("RootSelector", {
        seqRetreat, seqReactive, seqKill, seqTeamFight, seqDefend, seqPush,
        seqGank, seqMapAware, seqRoshan, seqCombat, seqWard, seqRune,
        seqCreepAggro, seqStack, seqPull, seqItems, seqCreep, seqLane
    })
    return root
end

-- =========================================================================
-- ENGINE HOOKS
-- =========================================================================
-- =========================================================================
-- ЛОГИКА: BLINK INITIATION
-- =========================================================================
function Logic.BlinkInitiate(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local blink, _ = HasItem(bot, "item_blink")
    if blink == nil then return BT.FAILURE end
    if blink:GetCooldownTimeRemaining() > 0 then return BT.FAILURE end
    local target = bb:Get("TacticalState", "KillTarget")
    if target == nil then return BT.FAILURE end
    local myPos = bot:GetLocation()
    local tPos = target:GetLocation()
    local dist = Distance(myPos, tPos)
    local attackRange = bb:Get("SelfState", "AttackRange") or 550
    -- блинкуем если цель вне радиуса атаки но в радиусе блинка
    if dist > attackRange + 100 and dist <= 1200 then
        local blinkPos = tPos + (myPos - tPos):Normalized() * (attackRange - 100)
        pcall(function() bot:Action_UseAbilityOnLocation(blink, blinkPos) end)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: REFRESHER USAGE
-- =========================================================================
function Logic.UseRefresher(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local ref, _ = HasItem(bot, "item_refresher")
    if ref == nil then return BT.FAILURE end
    if ref:GetCooldownTimeRemaining() > 0 then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local hp = bb:Get("SelfState", "HP") or 1.0
    -- используем если в бою и HP достаточно
    if #enemies >= 2 and hp > 0.5 then
        -- проверяем что assassinate на кд
        local assassinate = FindAbility(bot, ABILITY_ASSASSINATE)
        if assassinate ~= nil and assassinate:GetCooldownTimeRemaining() > 5 then
            pcall(function() bot:Action_UseAbility(ref) end)
            return BT.RUNNING
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: MOON SHARD USAGE
-- =========================================================================
function Logic.UseMoonShard(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local ms, _ = HasItem(bot, "item_moon_shard")
    if ms == nil then return BT.FAILURE end
    -- используем если не на максте атакспида
    local ok, as = pcall(function() return bot:GetAttackSpeed() end)
    if ok and type(as) == "number" and as < 400 then
        pcall(function() bot:Action_UseAbilityOnEntity(ms, bot) end)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: CHEESE USAGE
-- =========================================================================
function Logic.UseCheese(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local cheese, _ = HasItem(bot, "item_cheese")
    if cheese == nil then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    local mp = bb:Get("SelfState", "MP") or 1.0
    if hp < 0.3 or mp < 0.3 then
        pcall(function() bot:Action_UseAbility(cheese) end)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: AEGIS PICKUP
-- =========================================================================
function Logic.PickupAegis(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    -- ищем Aegis на земле
    local ok, units = pcall(function() return GetUnitList(UNIT_LIST_ALL) end)
    if not ok or units == nil then return BT.FAILURE end
    for i = 1, #units do
        local u = units[i]
        if u ~= nil and u:GetName() == "item_aegis" then
            local d = Distance(bot:GetLocation(), u:GetLocation())
            if d <= 300 then
                bot:Action_PickUpItem(u)
                return BT.RUNNING
            elseif d <= 1500 then
                bot:Action_MoveToLocation(u:GetLocation())
                return BT.RUNNING
            end
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: HIGH GROUND ADVANTAGE
-- =========================================================================
function Logic.HighGround(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local myPos = bot:GetLocation()
    -- проверяем высоту (Z координата)
    local highGround = myPos.z > 100
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if highGround and #enemies > 0 then
        -- держим позицию, не спускаемся
        return BT.SUCCESS
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: PRECISE KILL COMBO
-- =========================================================================
function Logic.PreciseKillCombo(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local target = bb:Get("TacticalState", "KillTarget")
    if target == nil or not target:IsAlive() then return BT.FAILURE end
    local myPos = bot:GetLocation()
    local tPos = target:GetLocation()
    local dist = Distance(myPos, tPos)
    local attackRange = bb:Get("SelfState", "AttackRange") or 550

    -- Комбо: Shrapnel -> Assassinate -> атаки
    local shrapnel = FindAbility(bot, ABILITY_SHRAPNEL)
    local assassinate = FindAbility(bot, ABILITY_ASSASSINATE)

    -- 1. Shrapnel если в радиусе
    if shrapnel ~= nil and shrapnel:GetLevel() > 0
       and shrapnel:GetCooldownTimeRemaining() <= 0
       and bot:GetMana() >= shrapnel:GetManaCost()
       and dist <= shrapnel:GetCastRange() then
        bot:Action_UseAbilityOnLocation(shrapnel, tPos)
        return BT.RUNNING
    end

    -- 2. Assassinate если в радиусе и видим
    if assassinate ~= nil and assassinate:GetLevel() > 0
       and assassinate:GetCooldownTimeRemaining() <= 0
       and bot:GetMana() >= assassinate:GetManaCost()
       and dist <= assassinate:GetCastRange()
       and target:IsVisible() then
        bot:Action_UseAbilityOnEntity(assassinate, target)
        return BT.RUNNING
    end

    -- 3. Атака
    if dist <= attackRange + 60 then
        bot:Action_AttackUnit(target, true)
        return BT.RUNNING
    else
        bot:Action_MoveToLocation(tPos)
        return BT.RUNNING
    end
end

-- =========================================================================
-- ЛОГИКА: DENY TOWER
-- =========================================================================
function Logic.DenyTower(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local allyTowers = bb:Get("TacticalState", "NearbyAllyTowers") or {}
    for i = 1, #allyTowers do
        local t = allyTowers[i]
        if t ~= nil and t:IsAlive() then
            local hpPct = t:GetHealth() / t:GetMaxHealth()
            if hpPct < 0.15 then
                local d = Distance(bot:GetLocation(), t:GetLocation())
                local attackRange = bb:Get("SelfState", "AttackRange") or 550
                if d <= attackRange + 60 then
                    bot:Action_AttackUnit(t, true)
                    return BT.RUNNING
                end
            end
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: CREEP BLOCK (блокировка крипов при старте)
-- =========================================================================
function Logic.CreepBlock(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local time = bb:Get("MacroState", "CurrentGameTime") or 0
    if time > 30 then return BT.FAILURE end
    -- блокируем крипов: двигаемся навстречу крип-вейву
    local allyCreeps = bb:Get("TacticalState", "NearbyAllyCreeps") or {}
    if #allyCreeps > 0 then
        local c = allyCreeps[1]
        local cLoc = c:GetLocation()
        -- двигаемся чуть вперед крипа
        local forward = cLoc + (cLoc - bot:GetLocation()):Normalized() * 100
        bot:Action_MoveToLocation(forward)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: WARD SPOT OPTIMIZATION
-- =========================================================================
function Logic.OptimalWardSpot(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    -- расширенный список точек вардов
    local spots = {
        Vector(-5800, -3800, 256), Vector(5800, 3800, 256),
        Vector(-2800, 2200, 256), Vector(2800, -2200, 256),
        Vector(0, 0, 256),
        Vector(-4800, 0, 256), Vector(4800, 0, 256),
        Vector(0, -4800, 256), Vector(0, 4800, 256),
    }
    local myPos = bot:GetLocation()
    local bestSpot, bestDist = nil, 1e9
    for i = 1, #spots do
        local sp = spots[i]
        local d = Distance(myPos, sp)
        if d < bestDist then
            local vis = true
            local ok, v = pcall(IsLocationVisible, sp)
            if ok then vis = v end
            if not vis then
                bestDist = d
                bestSpot = sp
            end
        end
    end
    if bestSpot == nil then return BT.FAILURE end
    -- проверяем есть ли вард
    local wardItem = nil
    for i = 0, 15 do
        local it = bot:GetItemInSlot(i)
        if it ~= nil then
            local n = it:GetName()
            if n == "item_ward_observer" then wardItem = it; break end
        end
    end
    if wardItem == nil then return BT.FAILURE end
    if Distance(myPos, bestSpot) <= 500 then
        bot:Action_UseAbilityOnLocation(wardItem, bestSpot)
        return BT.RUNNING
    else
        bot:Action_MoveToLocation(bestSpot)
        return BT.RUNNING
    end
end

-- =========================================================================
-- ЛОГИКА: DAMAGE CALCULATION ENGINE
-- =========================================================================
function Logic.CalculateDamage(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return 0 end
    local atkDmg = bb:Get("SelfState", "AttackDamage") or 0
    local level = bb:Get("SelfState", "Level") or 1
    -- базовый урон с предметами (приблизительно)
    local totalDmg = atkDmg
    -- крит (Daedalus 2.4x с шансом 30%)
    local daed, _ = HasItem(bot, "item_daedalus")
    if daed ~= nil then
        totalDmg = totalDmg + atkDmg * 0.3 * 1.4  -- ожидаемый крит
    end
    -- Monkey King Bar (мини-стан)
    local mkb, _ = HasItem(bot, "item_monkey_king_bar")
    if mkb ~= nil then
        totalDmg = totalDmg * 1.05
    end
    bb:Set("SelfState", "EffectiveDamage", totalDmg)
    return totalDmg
end

-- =========================================================================
-- ЛОГИКА: TARGET PRIORITY SCORING
-- =========================================================================
function Logic.ScoreTarget(bb, target)
    if target == nil or not target:IsAlive() then return 0 end
    local bot = bb:GetBotRef()
    if bot == nil then return 0 end
    local score = 0
    -- низкое HP = высокий приоритет
    local hpPct = target:GetHealth() / target:GetMaxHealth()
    score = score + (1 - hpPct) * 50
    -- дальность
    local dist = Distance(bot:GetLocation(), target:GetLocation())
    score = score - dist / 50
    -- убиваемость
    local effDmg = bb:Get("SelfState", "EffectiveDamage") or 0
    local attacksNeeded = math.ceil(target:GetHealth() / math.max(effDmg, 1))
    score = score - attacksNeeded * 5
    -- приоритет керри/саппортам
    local name = target:GetName() or ""
    if string.find(name, "sniper") or string.find(name, "drow") or string.find(name, "medusa") then
        score = score + 20
    end
    -- видимость
    if target:IsVisible() then score = score + 10 end
    -- инвул
    if target:IsInvulnerable() then score = score - 100 end
    return score
end

-- =========================================================================
-- ЛОГИКА: BEST TARGET SELECTION
-- =========================================================================
function Logic.SelectBestTarget(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return nil end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local best, bestScore = nil, -1e9
    for i = 1, #enemies do
        local e = enemies[i]
        if e ~= nil and e:IsAlive() then
            local sc = Logic.ScoreTarget(bb, e)
            if sc > bestScore then
                bestScore = sc
                best = e
            end
        end
    end
    bb:Set("TacticalState", "TargetEnemyHero", best)
    return best
end

-- =========================================================================
-- ЛОГИКА: SHRAPNEL ZONE OPTIMIZATION
-- =========================================================================
function Logic.OptimalShrapnel(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local shrapnel = FindAbility(bot, ABILITY_SHRAPNEL)
    if shrapnel == nil or shrapnel:GetLevel() <= 0 then return BT.FAILURE end
    if shrapnel:GetCooldownTimeRemaining() > 0 then return BT.FAILURE end
    if bot:GetMana() < shrapnel:GetManaCost() then return BT.FAILURE end

    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    -- ищем точку с максимальным числом врагов в радиусе Shrapnel (360)
    local bestPos, bestCount = nil, 0
    local candidates = {}
    for i = 1, #enemies do
        if enemies[i] ~= nil then table.insert(candidates, enemies[i]:GetLocation()) end
    end
    for i = 1, #enemyCreeps do
        if enemyCreeps[i] ~= nil then table.insert(candidates, enemyCreeps[i]:GetLocation()) end
    end

    for ci = 1, #candidates do
        local pos = candidates[ci]
        local count = 0
        for i = 1, #enemies do
            if enemies[i] ~= nil and Distance(enemies[i]:GetLocation(), pos) <= 360 then count = count + 1 end
        end
        for i = 1, #enemyCreeps do
            if enemyCreeps[i] ~= nil and Distance(enemyCreeps[i]:GetLocation(), pos) <= 360 then count = count + 1 end
        end
        if count > bestCount then
            bestCount = count
            bestPos = pos
        end
    end
    if bestPos ~= nil and bestCount >= 1 then
        bot:Action_UseAbilityOnLocation(shrapnel, bestPos)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: ASSASSINATE PRIORITY
-- =========================================================================
function Logic.AssassinatePriority(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local assassinate = FindAbility(bot, ABILITY_ASSASSINATE)
    if assassinate == nil or assassinate:GetLevel() <= 0 then return BT.FAILURE end
    if assassinate:GetCooldownTimeRemaining() > 0 then return BT.FAILURE end
    if bot:GetMana() < assassinate:GetManaCost() then return BT.FAILURE end

    local enemies = {}
    local ok, units = pcall(function() return GetUnitList(UNIT_LIST_ENEMY_HEROES) end)
    if ok and units ~= nil then
        for i = 1, #units do
            local u = units[i]
            if u ~= nil and u:IsAlive() and not u:IsInvulnerable() and u:IsVisible() then
                local dist = Distance(bot:GetLocation(), u:GetLocation())
                if dist <= assassinate:GetCastRange() then
                    table.insert(enemies, u)
                end
            end
        end
    end
    if #enemies == 0 then return BT.FAILURE end

    -- выбираем цель с наименьшим HP (гарантированный килл)
    local best = FindLowestHPUnit(enemies)
    if best ~= nil then
        local hpPct = best:GetHealth() / best:GetMaxHealth()
        if hpPct < 0.4 then
            bot:Action_UseAbilityOnEntity(assassinate, best)
            return BT.RUNNING
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: POSITIONING — стоять на краю радиуса атаки
-- =========================================================================
function Logic.OptimalPositioning(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies == 0 then return BT.FAILURE end
    local attackRange = bb:Get("SelfState", "AttackRange") or 550
    local myPos = bot:GetLocation()

    -- находим ближайшего врага
    local nearest = nil
    local nearDist = 1e9
    for i = 1, #enemies do
        local e = enemies[i]
        if e ~= nil and e:IsAlive() then
            local d = Distance(myPos, e:GetLocation())
            if d < nearDist then nearDist = d; nearest = e end
        end
    end
    if nearest == nil then return BT.FAILURE end

    -- если слишком близко — отступаем
    if nearDist < attackRange * 0.5 then
        local away = myPos + (myPos - nearest:GetLocation()):Normalized() * 300
        bot:Action_MoveToLocation(away)
        return BT.RUNNING
    end
    -- если слишком далеко — подходим
    if nearDist > attackRange then
        bot:Action_MoveToLocation(nearest:GetLocation())
        return BT.RUNNING
    end
    -- в оптимальной зоне — стоим
    return BT.SUCCESS
end

-- =========================================================================
-- ЛОГИКА: ANTI-GANK (детекция пропавших врагов)
-- =========================================================================
function Logic.AntiGank(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local time = bb:Get("MacroState", "CurrentGameTime") or 0
    if time < 300 then return BT.FAILURE end

    local allies = bb:Get("TacticalState", "NearbyAllyHeroes") or {}
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}

    -- если на линии нет врагов, но игра в мидгейме — возможный ганк
    local phase = bb:Get("MacroState", "GamePhase") or "laning"
    if phase ~= "laning" and #enemies == 0 and #allies <= 1 then
        -- проверяем, не пропали ли все враги
        local ok, allEnemies = pcall(function() return GetUnitList(UNIT_LIST_ENEMY_HEROES) end)
        if ok and allEnemies ~= nil then
            local visibleCount = 0
            for i = 1, #allEnemies do
                local u = allEnemies[i]
                if u ~= nil and u:IsAlive() and u:IsVisible() then
                    visibleCount = visibleCount + 1
                end
            end
            if visibleCount == 0 then
                -- все враги в тумане — отступаем к башне
                local fountain = GetFountainLoc(bot)
                if fountain ~= nil then
                    bot:Action_MoveToLocation(fountain)
                    return BT.RUNNING
                end
            end
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: FARM PRIORITY (джангл vs линия)
-- =========================================================================
function Logic.FarmPriority(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    local mp = bb:Get("SelfState", "MP") or 1.0
    local time = bb:Get("MacroState", "CurrentGameTime") or 0

    -- ранняя игра: линия
    if time < 600 then return BT.FAILURE end

    -- если HP низкое — линия (безопаснее)
    if hp < 0.5 then return BT.FAILURE end

    -- проверяем нейтральные кемпы
    local neutrals = bb:Get("TacticalState", "NearbyNeutralCreeps") or {}
    if #neutrals >= 3 then
        -- джанглим
        local target = FindLowestHPUnit(neutrals)
        if target ~= nil then
            local d = Distance(bot:GetLocation(), target:GetLocation())
            local attackRange = bb:Get("SelfState", "AttackRange") or 550
            if d <= attackRange + 60 then
                bot:Action_AttackUnit(target, true)
                return BT.RUNNING
            else
                bot:Action_MoveToLocation(target:GetLocation())
                return BT.RUNNING
            end
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: WAVE CLEAR
-- =========================================================================
function Logic.WaveClear(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies > 0 then return BT.FAILURE end  -- не клирим если враги рядом
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    if #enemyCreeps < 3 then return BT.FAILURE end

    local shrapnel = FindAbility(bot, ABILITY_SHRAPNEL)
    if shrapnel ~= nil and shrapnel:GetLevel() > 0
       and shrapnel:GetCooldownTimeRemaining() <= 0
       and bot:GetMana() >= shrapnel:GetManaCost() then
        -- кастуем shrapnel на центр вейва
        local sumX, sumY, n = 0, 0, 0
        for i = 1, #enemyCreeps do
            local c = enemyCreeps[i]
            if c ~= nil and c:IsAlive() then
                local l = c:GetLocation()
                sumX = sumX + l.x; sumY = sumY + l.y; n = n + 1
            end
        end
        if n > 0 then
            bot:Action_UseAbilityOnLocation(shrapnel, Vector(sumX / n, sumY / n, 0))
            return BT.RUNNING
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: LANE EQUILIBRIUM (контроль равновесия линии)
-- =========================================================================
function Logic.LaneEquilibrium(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    local allyCreeps = bb:Get("TacticalState", "NearbyAllyCreeps") or {}
    local attackRange = bb:Get("SelfState", "AttackRange") or 550

    -- Если союзных крипов больше — атакуем вражеских (пушим)
    -- Если меньше — только ластхит, не пушим
    if #allyCreeps > #enemyCreeps + 2 then
        -- пушим: атакуем ближайшего вражеского крипа
        local t = FindLowestHPUnit(enemyCreeps)
        if t ~= nil then
            local d = Distance(bot:GetLocation(), t:GetLocation())
            if d <= attackRange + 60 then
                bot:Action_AttackUnit(t, true)
                return BT.RUNNING
            end
        end
    end
    -- если вражеских больше — отступаем к башне
    if #enemyCreeps > #allyCreeps + 3 then
        local allyTowers = bb:Get("TacticalState", "NearbyAllyTowers") or {}
        if #allyTowers > 0 then
            bot:Action_MoveToLocation(allyTowers[1]:GetLocation())
            return BT.RUNNING
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: SMOKE GANK EXECUTION
-- =========================================================================
function Logic.ExecuteSmokeGank(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local smoke, _ = HasItem(bot, "item_smoke_of_deceit")
    if smoke == nil or smoke:GetCooldownTimeRemaining() > 0 then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies > 0 then return BT.FAILURE end  -- не ганкаем если враги рядом

    -- ищем цель
    local target = nil
    local ok, units = pcall(function() return GetUnitList(UNIT_LIST_ENEMY_HEROES) end)
    if ok and units ~= nil then
        for i = 1, #units do
            local u = units[i]
            if u ~= nil and u:IsAlive() and not u:IsInvulnerable() then
                local hpPct = u:GetHealth() / u:GetMaxHealth()
                if hpPct < 0.6 then
                    target = u
                    break
                end
            end
        end
    end
    if target == nil then return BT.FAILURE end

    -- используем smoke
    pcall(function() bot:Action_UseAbility(smoke) end)
    -- двигаемся к цели
    bot:Action_MoveToLocation(target:GetLocation())
    return BT.RUNNING
end

-- =========================================================================
-- ЛОГИКА: AUTO-COURIER MANAGEMENT
-- =========================================================================
function Logic.CourierManagement(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local couriers = {}
    local ok, units = pcall(function() return GetUnitList(UNIT_LIST_ALLIED) end)
    if ok and units ~= nil then
        for i = 1, #units do
            local u = units[i]
            if u ~= nil and u:IsCourier() then
                table.insert(couriers, u)
            end
        end
    end
    if #couriers == 0 then return BT.FAILURE end
    local courier = couriers[1]
    if courier == nil then return BT.FAILURE end

    -- если курьер имеет предметы — доставляем
    local hasItems = false
    for i = 0, 15 do
        if courier:GetItemInSlot(i) ~= nil then hasItems = true; break end
    end
    if hasItems then
        pcall(function() courier:Action_TransferItems(bot) end)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: DYNAMIC ITEM BUILD
-- =========================================================================
function Logic.DynamicItemBuild(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return end
    local enemies = {}
    local ok, units = pcall(function() return GetUnitList(UNIT_LIST_ENEMY_HEROES) end)
    if ok and units ~= nil then
        for i = 1, #units do
            local u = units[i]
            if u ~= nil and u:IsAlive() then table.insert(enemies, u:GetName()) end
        end
    end
    -- если много магов — BKB приоритет
    local magicCount = 0
    for i = 1, #enemies do
        local n = enemies[i] or ""
        if string.find(n, "lion") or string.find(n, "lina") or string.find(n, "zeus")
           or string.find(n, "skywrath") or string.find(n, "queenofpain") then
            magicCount = magicCount + 1
        end
    end
    -- сохраняем флаг
    bb:Set("MacroState", "MagicHeavy", magicCount >= 2)
end

-- =========================================================================
-- ЛОГИКА: ROshan TIMING & AEGIS
-- =========================================================================
function Logic.RoshanTiming(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local time = bb:Get("MacroState", "CurrentGameTime") or 0
    -- Рошан обычно спавнится ~8-11 мин, респавн 8-11 мин
    if time < 480 then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local allies = bb:Get("TacticalState", "NearbyAllyHeroes") or {}
    -- идём только если союзников >= 3 и врагов нет рядом
    if #allies < 2 then return BT.FAILURE end
    if #enemies > 0 then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    if hp < 0.6 then return BT.FAILURE end

    local ok, rloc = pcall(function() return GetRoshanLocation() end)
    if not ok or rloc == nil then return BT.FAILURE end
    local d = Distance(bot:GetLocation(), rloc)
    if d > 3000 then return BT.FAILURE end
    if d <= 400 then
        -- атакуем Рошана
        local rosh = nil
        local ok2, units = pcall(function() return GetUnitList(UNIT_LIST_ALL) end)
        if ok2 and units ~= nil then
            for i = 1, #units do
                local u = units[i]
                if u ~= nil and u:IsAlive() and u:GetName() == "npc_dota_roshan" then
                    rosh = u; break
                end
            end
        end
        if rosh ~= nil then
            bot:Action_AttackUnit(rosh, true)
            return BT.RUNNING
        end
    else
        bot:Action_MoveToLocation(rloc)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: OUTPOST CONTROL
-- =========================================================================
function Logic.OutpostControl(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies > 0 then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    if hp < 0.5 then return BT.FAILURE end

    -- ищем нейтральный/вражеский аванпост
    local ok, units = pcall(function() return GetUnitList(UNIT_LIST_ALL) end)
    if not ok or units == nil then return BT.FAILURE end
    local outpost = nil
    for i = 1, #units do
        local u = units[i]
        if u ~= nil and u:IsAlive() and string.find(u:GetName() or "", "outpost") then
            outpost = u; break
        end
    end
    if outpost == nil then return BT.FAILURE end
    local d = Distance(bot:GetLocation(), outpost:GetLocation())
    if d <= 200 then
        bot:Action_AttackUnit(outpost, true)
        return BT.RUNNING
    elseif d <= 2000 then
        bot:Action_MoveToLocation(outpost:GetLocation())
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: TORMENTOR (торментор)
-- =========================================================================
function Logic.Tormentor(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local time = bb:Get("MacroState", "CurrentGameTime") or 0
    if time < 1200 then return BT.FAILURE end  -- торментор с 20 мин
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local allies = bb:Get("TacticalState", "NearbyAllyHeroes") or {}
    if #allies < 2 then return BT.FAILURE end
    if #enemies > 0 then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    if hp < 0.5 then return BT.FAILURE end

    local ok, units = pcall(function() return GetUnitList(UNIT_LIST_ALL) end)
    if not ok or units == nil then return BT.FAILURE end
    local tor = nil
    for i = 1, #units do
        local u = units[i]
        if u ~= nil and u:IsAlive() and string.find(u:GetName() or "", "tormentor") then
            tor = u; break
        end
    end
    if tor == nil then return BT.FAILURE end
    local d = Distance(bot:GetLocation(), tor:GetLocation())
    if d <= 400 then
        bot:Action_AttackUnit(tor, true)
        return BT.RUNNING
    elseif d <= 3000 then
        bot:Action_MoveToLocation(tor:GetLocation())
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: LOTUS POOL (лотос)
-- =========================================================================
function Logic.LotusPool(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    local mp = bb:Get("SelfState", "MP") or 1.0
    if hp > 0.8 and mp > 0.8 then return BT.FAILURE end

    local ok, units = pcall(function() return GetUnitList(UNIT_LIST_ALL) end)
    if not ok or units == nil then return BT.FAILURE end
    local lotus = nil
    for i = 1, #units do
        local u = units[i]
        if u ~= nil and u:IsAlive() and string.find(u:GetName() or "", "lotus") then
            lotus = u; break
        end
    end
    if lotus == nil then return BT.FAILURE end
    local d = Distance(bot:GetLocation(), lotus:GetLocation())
    if d <= 200 then
        bot:Action_MoveToLocation(lotus:GetLocation())
        return BT.RUNNING
    elseif d <= 2000 then
        bot:Action_MoveToLocation(lotus:GetLocation())
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: SENTRY WARD DEWARDING
-- =========================================================================
function Logic.Dewarding(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    -- ищем sentry в инвентаре
    local sentry = nil
    for i = 0, 15 do
        local it = bot:GetItemInSlot(i)
        if it ~= nil and it:GetName() == "item_ward_sentry" then
            sentry = it; break
        end
    end
    if sentry == nil then return BT.FAILURE end
    if sentry:GetCooldownTimeRemaining() > 0 then return BT.FAILURE end

    -- ищем невидимые варды врага (приблизительно по локациям)
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies > 0 then return BT.FAILURE end  -- не дewardим если враги рядом

    -- ставим sentry в ключевой точке
    local spots = {
        Vector(-2000, 0, 0), Vector(2000, 0, 0),
        Vector(0, 2000, 0), Vector(0, -2000, 0),
    }
    local myPos = bot:GetLocation()
    local bestSpot, bestDist = nil, 1e9
    for i = 1, #spots do
        local sp = spots[i]
        local d = Distance(myPos, sp)
        if d < bestDist and d <= 1600 then
            bestDist = d
            bestSpot = sp
        end
    end
    if bestSpot == nil then return BT.FAILURE end
    if Distance(myPos, bestSpot) <= 500 then
        bot:Action_UseAbilityOnLocation(sentry, bestSpot)
        return BT.RUNNING
    else
        bot:Action_MoveToLocation(bestSpot)
        return BT.RUNNING
    end
end

-- =========================================================================
-- ЛОГИКА: DUST USAGE
-- =========================================================================
function Logic.UseDust(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local dust, _ = HasItem(bot, "item_dust")
    if dust == nil or dust:GetCooldownTimeRemaining() > 0 then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    -- используем если есть невидимые враги рядом
    local invisibleNearby = false
    for i = 1, #enemies do
        local e = enemies[i]
        if e ~= nil and e:IsAlive() and not e:IsVisible() then
            invisibleNearby = true
            break
        end
    end
    if invisibleNearby then
        pcall(function() bot:Action_UseAbility(dust) end)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: GEM CARRY (если есть гем — не умирать)
-- =========================================================================
function Logic.GemSafety(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local gem, _ = HasItem(bot, "item_gem")
    if gem == nil then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if hp < 0.4 and #enemies > 0 then
        -- отступаем с гемом
        local fountain = GetFountainLoc(bot)
        if fountain ~= nil then
            bot:Action_MoveToLocation(fountain)
            return BT.RUNNING
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: BOUNTY RUNE CONTROL
-- =========================================================================
function Logic.BountyRune(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local time = bb:Get("MacroState", "CurrentGameTime") or 0
    -- баунти руны каждые 3 мин начиная с 0
    local nextRune = math.floor(time / 180) * 180 + 180
    if math.abs(time - nextRune) > 15 then return BT.FAILURE end
    -- идём к ближайшей баунти руне
    local runes = {}
    local ok, r = pcall(function() return GetRuneLocations() end)
    if ok and r ~= nil then runes = r end
    if #runes == 0 then return BT.FAILURE end
    local myPos = bot:GetLocation()
    local best, bestDist = nil, 1e9
    for i = 1, #runes do
        local rl = runes[i]
        local loc = (type(rl) == "table") and (rl.location or rl) or rl
        if loc ~= nil then
            local d = Distance(myPos, loc)
            if d < bestDist then bestDist = d; best = loc end
        end
    end
    if best == nil then return BT.FAILURE end
    bot:Action_MoveToLocation(best)
    return BT.RUNNING
end

-- =========================================================================
-- ЛОГИКА: POWER RUNE CONTROL
-- =========================================================================
function Logic.PowerRune(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local time = bb:Get("MacroState", "CurrentGameTime") or 0
    -- power runes каждые 2 мин начиная с 6:00
    if time < 360 then return BT.FAILURE end
    local rem = (time - 360) % 120
    if rem > 15 then return BT.FAILURE end
    local runes = {}
    local ok, r = pcall(function() return GetRuneLocations() end)
    if ok and r ~= nil then runes = r end
    if #runes == 0 then return BT.FAILURE end
    local myPos = bot:GetLocation()
    local best, bestDist = nil, 1e9
    for i = 1, #runes do
        local rl = runes[i]
        local loc = (type(rl) == "table") and (rl.location or rl) or rl
        if loc ~= nil then
            local d = Distance(myPos, loc)
            if d < bestDist then bestDist = d; best = loc end
        end
    end
    if best == nil then return BT.FAILURE end
    bot:Action_MoveToLocation(best)
    return BT.RUNNING
end

-- =========================================================================
-- ЛОГИКА: WISDOM RUNE (мудрость)
-- =========================================================================
function Logic.WisdomRune(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local time = bb:Get("MacroState", "CurrentGameTime") or 0
    if time < 420 then return BT.FAILURE end
    local rem = (time - 420) % 420
    if rem > 15 then return BT.FAILURE end
    local runes = {}
    local ok, r = pcall(function() return GetRuneLocations() end)
    if ok and r ~= nil then runes = r end
    if #runes == 0 then return BT.FAILURE end
    local myPos = bot:GetLocation()
    local best, bestDist = nil, 1e9
    for i = 1, #runes do
        local rl = runes[i]
        local loc = (type(rl) == "table") and (rl.location or rl) or rl
        if loc ~= nil then
            local d = Distance(myPos, loc)
            if d < bestDist then bestDist = d; best = loc end
        end
    end
    if best == nil then return BT.FAILURE end
    bot:Action_MoveToLocation(best)
    return BT.RUNNING
end

-- =========================================================================
-- ЛОГИКА: TP REACTION (реакция на TP врага)
-- =========================================================================
function Logic.TPReaction(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    for i = 1, #enemies do
        local e = enemies[i]
        if e ~= nil and e:IsAlive() and e:IsChanneling() then
            -- враг телепортируется — можем прервать Assassinate
            local assassinate = FindAbility(bot, ABILITY_ASSASSINATE)
            if assassinate ~= nil and assassinate:GetLevel() > 0
               and assassinate:GetCooldownTimeRemaining() <= 0
               and bot:GetMana() >= assassinate:GetManaCost() then
                local dist = Distance(bot:GetLocation(), e:GetLocation())
                if dist <= assassinate:GetCastRange() then
                    bot:Action_UseAbilityOnEntity(assassinate, e)
                    return BT.RUNNING
                end
            end
            -- или Shrapnel
            local shrapnel = FindAbility(bot, ABILITY_SHRAPNEL)
            if shrapnel ~= nil and shrapnel:GetLevel() > 0
               and shrapnel:GetCooldownTimeRemaining() <= 0
               and bot:GetMana() >= shrapnel:GetManaCost() then
                local dist = Distance(bot:GetLocation(), e:GetLocation())
                if dist <= shrapnel:GetCastRange() then
                    bot:Action_UseAbilityOnLocation(shrapnel, e:GetLocation())
                    return BT.RUNNING
                end
            end
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: CREEP CUT (перехват крипов)
-- =========================================================================
function Logic.CreepCut(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local time = bb:Get("MacroState", "CurrentGameTime") or 0
    if time < 120 then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies > 0 then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    if hp < 0.5 then return BT.FAILURE end

    -- идём в джунгли/ривер чтобы перехватить крипов
    local neutrals = bb:Get("TacticalState", "NearbyNeutralCreeps") or {}
    if #neutrals > 0 then
        local t = FindLowestHPUnit(neutrals)
        if t ~= nil then
            bot:Action_MoveToLocation(t:GetLocation())
            return BT.RUNNING
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: LANE DOMINANCE
-- =========================================================================
function Logic.LaneDominance(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies == 0 then return BT.FAILURE end
    local enemy = enemies[1]
    local myPos = bot:GetLocation()
    local ePos = enemy:GetLocation()
    local dist = Distance(myPos, ePos)
    local attackRange = bb:Get("SelfState", "AttackRange") or 550
    local hp = bb:Get("SelfState", "HP") or 1.0

    -- если враг близко и HP достаточно — харасим
    if dist <= attackRange + 100 and hp > 0.5 then
        -- Shrapnel если готов
        local shrapnel = FindAbility(bot, ABILITY_SHRAPNEL)
        if shrapnel ~= nil and shrapnel:GetLevel() > 0
           and shrapnel:GetCooldownTimeRemaining() <= 0
           and bot:GetMana() >= shrapnel:GetManaCost() then
            bot:Action_UseAbilityOnLocation(shrapnel, ePos)
            return BT.RUNNING
        end
        bot:Action_AttackUnit(enemy, true)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: DEFENSIVE POSITIONING (позиция при пуше)
-- =========================================================================
function Logic.DefensivePositioning(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local allies = bb:Get("TacticalState", "NearbyAllyHeroes") or {}
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies == 0 then return BT.FAILURE end
    if #allies < 2 then return BT.FAILURE end

    -- держимся за союзниками, не выходим вперёд
    local sumX, sumY, n = 0, 0, 0
    for i = 1, #allies do
        local a = allies[i]
        if a ~= nil and a:IsAlive() then
            local l = a:GetLocation()
            sumX = sumX + l.x; sumY = sumY + l.y; n = n + 1
        end
    end
    if n > 0 then
        local center = Vector(sumX / n, sumY / n, 0)
        local myPos = bot:GetLocation()
        -- стоять позади центра союзников
        local back = center + (myPos - center):Normalized() * 200
        if Distance(myPos, back) > 100 then
            bot:Action_MoveToLocation(back)
            return BT.RUNNING
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: ESCAPE (побег с помощью предметов)
-- =========================================================================
function Logic.Escape(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    if hp > 0.25 then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies == 0 then return BT.FAILURE end

    -- Shadow Blade
    local sb, _ = HasItem(bot, "item_shadow_blade")
    if sb == nil then sb, _ = HasItem(bot, "item_silver_edge") end
    if sb ~= nil and sb:GetCooldownTimeRemaining() <= 0 then
        pcall(function() bot:Action_UseAbility(sb) end)
        return BT.RUNNING
    end
    -- Glimmer Cape
    local glimmer, _ = HasItem(bot, "item_glimmer_cape")
    if glimmer ~= nil and glimmer:GetCooldownTimeRemaining() <= 0 then
        pcall(function() bot:Action_UseAbilityOnEntity(glimmer, bot) end)
        return BT.RUNNING
    end
    -- Force Staff (отталкивание от врага)
    local fs, _ = HasItem(bot, "item_force_staff")
    if fs ~= nil and fs:GetCooldownTimeRemaining() <= 0 then
        local away = bot:GetLocation() + (bot:GetLocation() - enemies[1]:GetLocation()):Normalized() * 600
        pcall(function() bot:Action_UseAbilityOnLocation(fs, away) end)
        return BT.RUNNING
    end
    -- Hurricane Pike
    local pike, _ = HasItem(bot, "item_hurricane_pike")
    if pike ~= nil and pike:GetCooldownTimeRemaining() <= 0 then
        pcall(function() bot:Action_UseAbilityOnEntity(pike, enemies[1]) end)
        return BT.RUNNING
    end
    -- TP
    local tp, _ = HasItem(bot, "item_tpscroll")
    if tp ~= nil and tp:GetCooldownTimeRemaining() <= 0 then
        local fountain = GetFountainLoc(bot)
        if fountain ~= nil then
            bot:Action_UseAbilityOnLocation(tp, fountain)
            return BT.RUNNING
        end
    end
    -- просто бежим
    local fountain = GetFountainLoc(bot)
    if fountain ~= nil then
        bot:Action_MoveToLocation(fountain)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: REINFORCE (подкрепление союзников)
-- =========================================================================
function Logic.Reinforce(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local allies = bb:Get("TacticalState", "NearbyAllyHeroes") or {}
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    -- если союзник в бою и мы не рядом — идём на помощь
    local targetAlly = nil
    local ok, units = pcall(function() return GetUnitList(UNIT_LIST_ALLIED_HEROES) end)
    if ok and units ~= nil then
        for i = 1, #units do
            local u = units[i]
            if u ~= nil and u:IsAlive() and u ~= bot then
                local hpPct = u:GetHealth() / u:GetMaxHealth()
                if hpPct < 0.4 then
                    targetAlly = u
                    break
                end
            end
        end
    end
    if targetAlly == nil then return BT.FAILURE end
    local d = Distance(bot:GetLocation(), targetAlly:GetLocation())
    if d <= 500 then
        -- атакуем врага рядом с союзником
        local nearestEnemy = nil
        local nearDist = 1e9
        for i = 1, #enemies do
            local e = enemies[i]
            if e ~= nil and e:IsAlive() then
                local ed = Distance(e:GetLocation(), targetAlly:GetLocation())
                if ed < nearDist then nearDist = ed; nearestEnemy = e end
            end
        end
        if nearestEnemy ~= nil then
            bot:Action_AttackUnit(nearestEnemy, true)
            return BT.RUNNING
        end
    else
        bot:Action_MoveToLocation(targetAlly:GetLocation())
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: MANA MANAGEMENT
-- =========================================================================
function Logic.ManaManagement(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local mp = bb:Get("SelfState", "MP") or 1.0
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    -- если мана низкая и нет врагов — используем Clarity
    if mp < 0.3 and #enemies == 0 then
        for i = 0, 15 do
            local it = bot:GetItemInSlot(i)
            if it ~= nil and it:GetName() == "item_clarity" then
                pcall(function() bot:Action_UseAbilityOnEntity(it, bot) end)
                return BT.RUNNING
            end
        end
    end
    -- если мана критически низкая — не кастуем способности
    if mp < 0.15 then
        bb:Set("SelfState", "ManaStarved", true)
    else
        bb:Set("SelfState", "ManaStarved", false)
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: ITEM TIMING (использование предметов по таймингу)
-- =========================================================================
function Logic.ItemTiming(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local time = bb:Get("MacroState", "CurrentGameTime") or 0
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies == 0 then return BT.FAILURE end

    -- Maelstrom: авто-атака с молнией — пассив, ничего не делаем
    -- Daedalus: пассив
    -- BKB: используем при инициации
    local bkb, _ = HasItem(bot, "item_black_king_bar")
    if bkb ~= nil and bkb:GetCooldownTimeRemaining() <= 0 then
        local threat = bb:Get("TacticalState", "ActiveThreatLevel") or 0
        if threat >= 2 then
            pcall(function() bot:Action_UseAbility(bkb) end)
            return BT.RUNNING
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: CREEP PULLING ADVANCED
-- =========================================================================
function Logic.AdvancedPull(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local time = bb:Get("MacroState", "CurrentGameTime") or 0
    if time < 60 then return BT.FAILURE end
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    local allyCreeps = bb:Get("TacticalState", "NearbyAllyCreeps") or {}
    if #enemyCreeps == 0 or #allyCreeps == 0 then return BT.FAILURE end

    -- тянем крипов к нейтральному кемпу
    local neutrals = bb:Get("TacticalState", "NearbyNeutralCreeps") or {}
    if #neutrals > 0 then
        local camp = neutrals[1]
        local cLoc = camp:GetLocation()
        -- двигаемся к кемпу, атакуя вражеского крипа
        local target = FindLowestHPUnit(enemyCreeps)
        if target ~= nil then
            local d = Distance(bot:GetLocation(), target:GetLocation())
            if d <= 600 then
                bot:Action_AttackUnit(target, true)
                return BT.RUNNING
            end
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: ANTI-PUSH (защита от пуша)
-- =========================================================================
function Logic.AntiPush(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    if #enemyCreeps < 5 then return BT.FAILURE end
    local allies = bb:Get("TacticalState", "NearbyAllyHeroes") or {}
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #allies < 2 then return BT.FAILURE end
    if #enemies > 0 then return BT.FAILURE end

    -- клирим вейв
    local shrapnel = FindAbility(bot, ABILITY_SHRAPNEL)
    if shrapnel ~= nil and shrapnel:GetLevel() > 0
       and shrapnel:GetCooldownTimeRemaining() <= 0
       and bot:GetMana() >= shrapnel:GetManaCost() then
        local sumX, sumY, n = 0, 0, 0
        for i = 1, #enemyCreeps do
            local c = enemyCreeps[i]
            if c ~= nil and c:IsAlive() then
                local l = c:GetLocation()
                sumX = sumX + l.x; sumY = sumY + l.y; n = n + 1
            end
        end
        if n > 0 then
            bot:Action_UseAbilityOnLocation(shrapnel, Vector(sumX / n, sumY / n, 0))
            return BT.RUNNING
        end
    end
    -- атакуем ближайшего крипа
    local t = FindLowestHPUnit(enemyCreeps)
    if t ~= nil then
        bot:Action_AttackUnit(t, true)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: BASE RACE (рейс на базу)
-- =========================================================================
function Logic.BaseRace(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    -- если враги пушат нашу базу и союзников мало — бежим защищать
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    local fountain = GetFountainLoc(bot)
    if fountain == nil then return BT.FAILURE end
    local nearBase = false
    for i = 1, #enemyCreeps do
        local c = enemyCreeps[i]
        if c ~= nil and c:IsAlive() and Distance(c:GetLocation(), fountain) < 2000 then
            nearBase = true
            break
        end
    end
    if not nearBase then return BT.FAILURE end
    -- атакуем крипов у базы
    local t = FindLowestHPUnit(enemyCreeps)
    if t ~= nil then
        bot:Action_AttackUnit(t, true)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: HIGH GROUND DEFENSE
-- =========================================================================
function Logic.HighGroundDefense(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies == 0 then return BT.FAILURE end
    local myPos = bot:GetLocation()
    -- если мы на хайграунде и враги на лоуграунде — используем преимущество
    if myPos.z > 100 then
        -- атакуем издалека
        local target = bb:Get("TacticalState", "TargetEnemyHero")
        if target ~= nil and target:IsAlive() then
            local shrapnel = FindAbility(bot, ABILITY_SHRAPNEL)
            if shrapnel ~= nil and shrapnel:GetLevel() > 0
               and shrapnel:GetCooldownTimeRemaining() <= 0
               and bot:GetMana() >= shrapnel:GetManaCost() then
                bot:Action_UseAbilityOnLocation(shrapnel, target:GetLocation())
                return BT.RUNNING
            end
            local dist = Distance(myPos, target:GetLocation())
            local attackRange = bb:Get("SelfState", "AttackRange") or 550
            if dist <= attackRange then
                bot:Action_AttackUnit(target, true)
                return BT.RUNNING
            end
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: TEAM COORDINATION
-- =========================================================================
function Logic.TeamCoordination(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local allies = bb:Get("TacticalState", "NearbyAllyHeroes") or {}
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #allies < 2 or #enemies < 2 then return BT.FAILURE end

    -- фокусим цель, которую атакуют союзники
    local focusTarget = nil
    for i = 1, #enemies do
        local e = enemies[i]
        if e ~= nil and e:IsAlive() then
            -- проверяем, атакуют ли союзники этого врага
            for j = 1, #allies do
                local a = allies[j]
                if a ~= nil and a:IsAlive() then
                    -- приблизительно: если союзник близко к врагу
                    if Distance(a:GetLocation(), e:GetLocation()) < 600 then
                        focusTarget = e
                        break
                    end
                end
            end
            if focusTarget ~= nil then break end
        end
    end
    if focusTarget ~= nil then
        local dist = Distance(bot:GetLocation(), focusTarget:GetLocation())
        local attackRange = bb:Get("SelfState", "AttackRange") or 550
        if dist <= attackRange then
            bot:Action_AttackUnit(focusTarget, true)
            return BT.RUNNING
        else
            bot:Action_MoveToLocation(focusTarget:GetLocation())
            return BT.RUNNING
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: OBJECTIVE PRIORITY
-- =========================================================================
function Logic.ObjectivePriority(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local time = bb:Get("MacroState", "CurrentGameTime") or 0
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}

    -- приоритет: если есть враги рядом — бой
    if #enemies > 0 then return BT.FAILURE end

    -- если игра в лейтгейме — пушим
    local phase = bb:Get("MacroState", "GamePhase") or "laning"
    if phase == "lategame" then
        -- идём к трону
        local ok, thrones = pcall(function() return GetUnitList(UNIT_LIST_ENEMY) end)
        if ok and thrones ~= nil then
            for i = 1, #thrones do
                local u = thrones[i]
                if u ~= nil and u:IsAlive() and u:IsAncient() then
                    local d = Distance(bot:GetLocation(), u:GetLocation())
                    if d <= 1600 then
                        bot:Action_AttackUnit(u, true)
                        return BT.RUNNING
                    elseif d <= 4000 then
                        bot:Action_MoveToLocation(u:GetLocation())
                        return BT.RUNNING
                    end
                end
            end
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: SPLIT PUSH
-- =========================================================================
function Logic.SplitPush(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local allies = bb:Get("TacticalState", "NearbyAllyHeroes") or {}
    if #enemies > 0 then return BT.FAILURE end
    if #allies < 2 then return BT.FAILURE end  -- сплитим только если команда в бою

    -- ищем ближайшую вражескую башню на боковой линии
    local ok, units = pcall(function() return GetUnitList(UNIT_LIST_ENEMY) end)
    if not ok or units == nil then return BT.FAILURE end
    local tower = nil
    local bestDist = 1e9
    for i = 1, #units do
        local u = units[i]
        if u ~= nil and u:IsAlive() and u:IsTower() then
            local d = Distance(bot:GetLocation(), u:GetLocation())
            if d < bestDist and d <= 4000 then
                bestDist = d
                tower = u
            end
        end
    end
    if tower == nil then return BT.FAILURE end
    local d = Distance(bot:GetLocation(), tower:GetLocation())
    local attackRange = bb:Get("SelfState", "AttackRange") or 550
    if d <= attackRange + 80 then
        bot:Action_AttackUnit(tower, true)
        return BT.RUNNING
    else
        bot:Action_MoveToLocation(tower:GetLocation())
        return BT.RUNNING
    end
end

-- =========================================================================
-- ЛОГИКА: DEFENSIVE TELEPORT
-- =========================================================================
function Logic.DefensiveTeleport(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local tp, _ = HasItem(bot, "item_tpscroll")
    if tp == nil or tp:GetCooldownTimeRemaining() > 0 then return BT.FAILURE end
    local fountain = GetFountainLoc(bot)
    if fountain == nil then return BT.FAILURE end

    -- если враги пушат нашу базу — телепортируемся
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    local nearBase = false
    for i = 1, #enemyCreeps do
        local c = enemyCreeps[i]
        if c ~= nil and c:IsAlive() and Distance(c:GetLocation(), fountain) < 2500 then
            nearBase = true
            break
        end
    end
    if nearBase then
        pcall(function() bot:Action_UseAbilityOnLocation(tp, fountain) end)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: LANE ROTATION (ротация между линиями)
-- =========================================================================
function Logic.LaneRotation(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local time = bb:Get("MacroState", "CurrentGameTime") or 0
    if time < 600 then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies > 0 then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    if hp < 0.6 then return BT.FAILURE end

    -- ищем пустую линию (где нет союзников)
    local ok, allies = pcall(function() return GetUnitList(UNIT_LIST_ALLIED_HEROES) end)
    if not ok or allies == nil then return BT.FAILURE end
    local laneCounts = { [LANE_TOP] = 0, [LANE_MID] = 0, [LANE_BOT] = 0 }
    for i = 1, #allies do
        local a = allies[i]
        if a ~= nil and a:IsAlive() and a ~= bot then
            local l = a:GetLane and a:GetLane() or nil
            if l ~= nil and laneCounts[l] ~= nil then laneCounts[l] = laneCounts[l] + 1 end
        end
    end
    -- выбираем линию с наименьшим числом союзников
    local bestLane, bestCount = nil, 1e9
    for l, c in pairs(laneCounts) do
        if c < bestCount then bestCount = c; bestLane = l end
    end
    if bestLane ~= nil then
        bb:Set("MacroState", "ActiveLane", bestLane)
        bb:Set("MacroState", "FarmLane", bestLane)
        return BT.SUCCESS
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: WARD REFRESH (обновление вардов)
-- =========================================================================
function Logic.WardRefresh(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local time = bb:Get("MacroState", "CurrentGameTime") or 0
    -- обновляем варды каждые 6 минут (время жизни observer ~6 мин)
    if time % 360 > 30 then return BT.FAILURE end
    -- проверяем есть ли вард
    local hasWard = false
    for i = 0, 15 do
        local it = bot:GetItemInSlot(i)
        if it ~= nil and it:GetName() == "item_ward_observer" then hasWard = true; break end
    end
    if not hasWard then return BT.FAILURE end
    -- ставим вард в оптимальную точку
    return Logic.OptimalWardSpot(bb)
end

-- =========================================================================
-- ЛОГИКА: ITEM BUILD ADAPTATION (адаптация билда)
-- =========================================================================
function Logic.AdaptItemBuild(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return end
    local enemies = {}
    local ok, units = pcall(function() return GetUnitList(UNIT_LIST_ENEMY_HEROES) end)
    if ok and units ~= nil then
        for i = 1, #units do
            local u = units[i]
            if u ~= nil and u:IsAlive() then table.insert(enemies, u:GetName()) end
        end
    end
    -- если много физического урона — покупаем броню
    local physCount = 0
    for i = 1, #enemies do
        local n = enemies[i] or ""
        if string.find(n, "sven") or string.find(n, "ursa") or string.find(n, "phantom")
           or string.find(n, "juggernaut") or string.find(n, "faceless") then
            physCount = physCount + 1
        end
    end
    if physCount >= 2 then
        bb:Set("MacroState", "NeedArmor", true)
    end
    -- если много магического урона — BKB приоритет
    local magicCount = 0
    for i = 1, #enemies do
        local n = enemies[i] or ""
        if string.find(n, "lion") or string.find(n, "lina") or string.find(n, "zeus")
           or string.find(n, "skywrath") or string.find(n, "queenofpain") or string.find(n, "necrophos") then
            magicCount = magicCount + 1
        end
    end
    if magicCount >= 2 then
        bb:Set("MacroState", "NeedBKB", true)
    end
end

-- =========================================================================
-- ЛОГИКА: CREEP STACKING TIMING
-- =========================================================================
function Logic.StackTiming(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local time = bb:Get("MacroState", "CurrentGameTime") or 0
    local sec = time % 60
    -- стекаем за 1-2 секунды до полной минуты
    if sec < 57 or sec > 59 then return BT.FAILURE end
    local neutrals = bb:Get("TacticalState", "NearbyNeutralCreeps") or {}
    if #neutrals == 0 then return BT.FAILURE end
    -- отводим крипов
    local camp = neutrals[1]
    local cLoc = camp:GetLocation()
    local away = cLoc + (bot:GetLocation() - cLoc):Normalized() * 500
    bot:Action_MoveToLocation(away)
    return BT.RUNNING
end

-- =========================================================================
-- ЛОГИКА: LANE PRESSURE (давление на линию)
-- =========================================================================
function Logic.LanePressure(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies > 0 then return BT.FAILURE end
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    if #enemyCreeps == 0 then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    if hp < 0.5 then return BT.FAILURE end

    -- если нет врагов — пушим линию
    local t = FindLowestHPUnit(enemyCreeps)
    if t ~= nil then
        bot:Action_AttackUnit(t, true)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: TP TO LANE (телепорт на линию)
-- =========================================================================
function Logic.TPToLane(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local tp, _ = HasItem(bot, "item_tpscroll")
    if tp == nil or tp:GetCooldownTimeRemaining() > 0 then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies > 0 then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    if hp < 0.8 then return BT.FAILURE end

    -- телепортируемся к ближайшей союзной башне на пустой линии
    local ok, towers = pcall(function() return GetUnitList(UNIT_LIST_ALLIED) end)
    if not ok or towers == nil then return BT.FAILURE end
    local tower = nil
    local bestDist = 1e9
    for i = 1, #towers do
        local u = towers[i]
        if u ~= nil and u:IsAlive() and u:IsTower() then
            local d = Distance(bot:GetLocation(), u:GetLocation())
            if d > 2000 and d < bestDist then
                bestDist = d
                tower = u
            end
        end
    end
    if tower == nil then return BT.FAILURE end
    pcall(function() bot:Action_UseAbilityOnLocation(tp, tower:GetLocation()) end)
    return BT.RUNNING
end

-- =========================================================================
-- ЛОГИКА: JUNGLE FARM EFFICIENCY
-- =========================================================================
function Logic.JungleFarmEfficiency(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local time = bb:Get("MacroState", "CurrentGameTime") or 0
    if time < 300 then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    if hp < 0.4 then return BT.FAILURE end
    local neutrals = bb:Get("TacticalState", "NearbyNeutralCreeps") or {}
    if #neutrals == 0 then return BT.FAILURE end

    -- атакуем самого слабого нейтрала
    local target = FindLowestHPUnit(neutrals)
    if target ~= nil then
        local d = Distance(bot:GetLocation(), target:GetLocation())
        local attackRange = bb:Get("SelfState", "AttackRange") or 550
        if d <= attackRange + 60 then
            bot:Action_AttackUnit(target, true)
            return BT.RUNNING
        else
            bot:Action_MoveToLocation(target:GetLocation())
            return BT.RUNNING
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: BURST DAMAGE CALCULATION
-- =========================================================================
function Logic.BurstDamage(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return 0 end
    local atkDmg = bb:Get("SelfState", "AttackDamage") or 0
    local level = bb:Get("SelfState", "Level") or 1
    local shrapnel = FindAbility(bot, ABILITY_SHRAPNEL)
    local assassinate = FindAbility(bot, ABILITY_ASSASSINATE)

    local burst = atkDmg * 3  -- 3 удара
    if shrapnel ~= nil and shrapnel:GetLevel() > 0 then
        burst = burst + (20 + 15 * shrapnel:GetLevel()) * 7  -- 7 тиков shrapnel
    end
    if assassinate ~= nil and assassinate:GetLevel() > 0 then
        burst = burst + (250 + 100 * (assassinate:GetLevel() - 1))
    end
    -- крит
    local daed, _ = HasItem(bot, "item_daedalus")
    if daed ~= nil then
        burst = burst + atkDmg * 0.3 * 1.4
    end
    bb:Set("SelfState", "BurstDamage", burst)
    return burst
end

-- =========================================================================
-- ЛОГИКА: KILL SECURE
-- =========================================================================
function Logic.KillSecure(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local burst = Logic.BurstDamage(bb)
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local target = nil
    for i = 1, #enemies do
        local e = enemies[i]
        if e ~= nil and e:IsAlive() and not e:IsInvulnerable() then
            if e:GetHealth() <= burst then
                target = e
                break
            end
        end
    end
    if target == nil then return BT.FAILURE end
    -- используем все способности
    local dist = Distance(bot:GetLocation(), target:GetLocation())
    local shrapnel = FindAbility(bot, ABILITY_SHRAPNEL)
    if shrapnel ~= nil and shrapnel:GetLevel() > 0
       and shrapnel:GetCooldownTimeRemaining() <= 0
       and bot:GetMana() >= shrapnel:GetManaCost()
       and dist <= shrapnel:GetCastRange() then
        bot:Action_UseAbilityOnLocation(shrapnel, target:GetLocation())
        return BT.RUNNING
    end
    local assassinate = FindAbility(bot, ABILITY_ASSASSINATE)
    if assassinate ~= nil and assassinate:GetLevel() > 0
       and assassinate:GetCooldownTimeRemaining() <= 0
       and bot:GetMana() >= assassinate:GetManaCost()
       and dist <= assassinate:GetCastRange()
       and target:IsVisible() then
        bot:Action_UseAbilityOnEntity(assassinate, target)
        return BT.RUNNING
    end
    local attackRange = bb:Get("SelfState", "AttackRange") or 550
    if dist <= attackRange then
        bot:Action_AttackUnit(target, true)
        return BT.RUNNING
    else
        bot:Action_MoveToLocation(target:GetLocation())
        return BT.RUNNING
    end
end

-- =========================================================================
-- ЛОГИКА: COOLDOWN TRACKING (отслеживание кд врагов)
-- =========================================================================
function Logic.CooldownTracking(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local enemyCDs = {}
    for i = 1, #enemies do
        local e = enemies[i]
        if e ~= nil and e:IsAlive() then
            local cds = {}
            for j = 0, 5 do
                local ab = e:GetAbilityInSlot(j)
                if ab ~= nil then
                    cds[j] = ab:GetCooldownTimeRemaining()
                end
            end
            enemyCDs[e:GetPlayerID()] = cds
        end
    end
    bb:Set("TacticalState", "EnemyCooldowns", enemyCDs)
end

-- =========================================================================
-- ЛОГИКА: ENEMY ABILITY AWARENESS
-- =========================================================================
function Logic.EnemyAbilityAwareness(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local hp = bb:Get("SelfState", "HP") or 1.0
    -- если враг имеет стан/сайленс и он готов — держим дистанцию
    for i = 1, #enemies do
        local e = enemies[i]
        if e ~= nil and e:IsAlive() then
            for j = 0, 5 do
                local ab = e:GetAbilityInSlot(j)
                if ab ~= nil then
                    local name = ab:GetName() or ""
                    local ready = ab:GetCooldownTimeRemaining() <= 0 and ab:GetLevel() > 0
                    if ready then
                        -- известные станы
                        if string.find(name, "stun") or string.find(name, "hex") or string.find(name, "silence")
                           or string.find(name, "root") or string.find(name, "leash") then
                            -- держим дистанцию
                            local d = Distance(bot:GetLocation(), e:GetLocation())
                            if d < 800 then
                                local away = bot:GetLocation() + (bot:GetLocation() - e:GetLocation()):Normalized() * 400
                                bot:Action_MoveToLocation(away)
                                return BT.RUNNING
                            end
                        end
                    end
                end
            end
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: THREAT ASSESSMENT
-- =========================================================================
function Logic.ThreatAssessment(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local allies = bb:Get("TacticalState", "NearbyAllyHeroes") or {}
    local hp = bb:Get("SelfState", "HP") or 1.0
    local threat = 0
    -- количество врагов
    threat = threat + #enemies
    -- если врагов больше союзников
    if #enemies > #allies + 1 then threat = threat + 2 end
    -- если HP низкое
    if hp < 0.3 then threat = threat + 2 end
    -- если враги имеют ульты
    for i = 1, #enemies do
        local e = enemies[i]
        if e ~= nil and e:IsAlive() then
            local ult = e:GetAbilityInSlot(5)  -- ульт обычно слот 5
            if ult ~= nil and ult:GetLevel() > 0 and ult:GetCooldownTimeRemaining() <= 0 then
                threat = threat + 1
            end
        end
    end
    bb:Set("TacticalState", "ActiveThreatLevel", threat)
end

-- =========================================================================
-- ЛОГИКА: FIGHT OR FLIGHT
-- =========================================================================
function Logic.FightOrFlight(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    local threat = bb:Get("TacticalState", "ActiveThreatLevel") or 0
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local allies = bb:Get("TacticalState", "NearbyAllyHeroes") or {}

    -- flight: если HP низкое и угроза высокая
    if hp < 0.25 and threat >= 3 then
        local fountain = GetFountainLoc(bot)
        if fountain ~= nil then
            bot:Action_MoveToLocation(fountain)
            return BT.RUNNING
        end
    end
    -- fight: если союзников больше и HP достаточно
    if hp > 0.5 and #allies >= #enemies then
        local target = bb:Get("TacticalState", "KillTarget")
        if target ~= nil and target:IsAlive() then
            local dist = Distance(bot:GetLocation(), target:GetLocation())
            local attackRange = bb:Get("SelfState", "AttackRange") or 550
            if dist <= attackRange then
                bot:Action_AttackUnit(target, true)
                return BT.RUNNING
            else
                bot:Action_MoveToLocation(target:GetLocation())
                return BT.RUNNING
            end
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: POSITIONING IN FIGHT
-- =========================================================================
function Logic.PositionInFight(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies == 0 then return BT.FAILURE end
    local attackRange = bb:Get("SelfState", "AttackRange") or 550
    local myPos = bot:GetLocation()

    -- находим ближайшего врага
    local nearest = nil
    local nearDist = 1e9
    for i = 1, #enemies do
        local e = enemies[i]
        if e ~= nil and e:IsAlive() then
            local d = Distance(myPos, e:GetLocation())
            if d < nearDist then nearDist = d; nearest = e end
        end
    end
    if nearest == nil then return BT.FAILURE end

    -- если слишком близко — отступаем
    if nearDist < attackRange * 0.4 then
        local away = myPos + (myPos - nearest:GetLocation()):Normalized() * 400
        bot:Action_MoveToLocation(away)
        return BT.RUNNING
    end
    -- если враг в радиусе атаки — стоим
    if nearDist <= attackRange then
        return BT.SUCCESS
    end
    -- если далеко — подходим
    bot:Action_MoveToLocation(nearest:GetLocation())
    return BT.RUNNING
end

-- =========================================================================
-- ЛОГИКА: AUTO-ATTACK CONTROL
-- =========================================================================
function Logic.AutoAttackControl(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local target = bb:Get("TacticalState", "TargetEnemyHero")
    if target == nil or not target:IsAlive() then return BT.FAILURE end
    local myPos = bot:GetLocation()
    local tPos = target:GetLocation()
    local dist = Distance(myPos, tPos)
    local attackRange = bb:Get("SelfState", "AttackRange") or 550
    local hp = bb:Get("SelfState", "HP") or 1.0

    -- не атакуем если HP низкое
    if hp < 0.2 then return BT.FAILURE end
    -- не атакуем если враг под башней и мы не можем дайвить
    local enemyTowers = bb:Get("TacticalState", "NearbyEnemyTowers") or {}
    for i = 1, #enemyTowers do
        local t = enemyTowers[i]
        if t ~= nil and t:IsAlive() then
            if Distance(t:GetLocation(), tPos) < 800 and not Logic.TowerDiveCheck(bb) then
                return BT.FAILURE
            end
        end
    end
    if dist <= attackRange + 50 then
        bot:Action_AttackUnit(target, true)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: SHRAPNEL ON CREEP WAVE (фарм вейва)
-- =========================================================================
function Logic.ShrapnelOnWave(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    if #enemyCreeps < 3 then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies > 0 then return BT.FAILURE end
    local shrapnel = FindAbility(bot, ABILITY_SHRAPNEL)
    if shrapnel == nil or shrapnel:GetLevel() <= 0 then return BT.FAILURE end
    if shrapnel:GetCooldownTimeRemaining() > 0 then return BT.FAILURE end
    if bot:GetMana() < shrapnel:GetManaCost() then return BT.FAILURE end
    -- кастуем на центр вейва
    local sumX, sumY, n = 0, 0, 0
    for i = 1, #enemyCreeps do
        local c = enemyCreeps[i]
        if c ~= nil and c:IsAlive() then
            local l = c:GetLocation()
            sumX = sumX + l.x; sumY = sumY + l.y; n = n + 1
        end
    end
    if n >= 3 then
        bot:Action_UseAbilityOnLocation(shrapnel, Vector(sumX / n, sumY / n, 0))
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: ASSASSINATE ON LOW TARGET
-- =========================================================================
function Logic.AssassinateLowTarget(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local assassinate = FindAbility(bot, ABILITY_ASSASSINATE)
    if assassinate == nil or assassinate:GetLevel() <= 0 then return BT.FAILURE end
    if assassinate:GetCooldownTimeRemaining() > 0 then return BT.FAILURE end
    if bot:GetMana() < assassinate:GetManaCost() then return BT.FAILURE end
    local enemies = {}
    local ok, units = pcall(function() return GetUnitList(UNIT_LIST_ENEMY_HEROES) end)
    if ok and units ~= nil then
        for i = 1, #units do
            local u = units[i]
            if u ~= nil and u:IsAlive() and not u:IsInvulnerable() and u:IsVisible() then
                local dist = Distance(bot:GetLocation(), u:GetLocation())
                if dist <= assassinate:GetCastRange() then
                    local hpPct = u:GetHealth() / u:GetMaxHealth()
                    if hpPct < 0.35 then
                        bot:Action_UseAbilityOnEntity(assassinate, u)
                        return BT.RUNNING
                    end
                end
            end
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: ITEM USAGE IN COMBAT
-- =========================================================================
function Logic.CombatItemUsage(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies == 0 then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0

    -- BKB
    local bkb, _ = HasItem(bot, "item_black_king_bar")
    if bkb ~= nil and bkb:GetCooldownTimeRemaining() <= 0 and hp < 0.6 then
        pcall(function() bot:Action_UseAbility(bkb) end)
        return BT.RUNNING
    end
    -- Satanic
    local satanic, _ = HasItem(bot, "item_satanic")
    if satanic ~= nil and satanic:GetCooldownTimeRemaining() <= 0 and hp < 0.35 then
        pcall(function() bot:Action_UseAbility(satanic) end)
        return BT.RUNNING
    end
    -- Hurricane Pike
    local pike, _ = HasItem(bot, "item_hurricane_pike")
    if pike ~= nil and pike:GetCooldownTimeRemaining() <= 0 then
        local nearest = enemies[1]
        local d = Distance(bot:GetLocation(), nearest:GetLocation())
        if d < 400 then
            pcall(function() bot:Action_UseAbilityOnEntity(pike, nearest) end)
            return BT.RUNNING
        end
    end
    -- Silver Edge (break passive)
    local se, _ = HasItem(bot, "item_silver_edge")
    if se ~= nil and se:GetCooldownTimeRemaining() <= 0 then
        -- используем на врага с сильным пассивом
        for i = 1, #enemies do
            local e = enemies[i]
            if e ~= nil and e:IsAlive() then
                local name = e:GetName() or ""
                if string.find(name, "bristle") or string.find(name, "huskar") or string.find(name, "spectre") then
                    pcall(function() bot:Action_UseAbilityOnEntity(se, e) end)
                    return BT.RUNNING
                end
            end
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: FARMING EFFICIENCY
-- =========================================================================
function Logic.FarmingEfficiency(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    local neutrals = bb:Get("TacticalState", "NearbyNeutralCreeps") or {}
    local hp = bb:Get("SelfState", "HP") or 1.0
    if hp < 0.4 then return BT.FAILURE end

    -- приоритет: ластхит > джангл > харас
    -- ластхит
    local attackRange = bb:Get("SelfState", "AttackRange") or 550
    local atkDmg = bb:Get("SelfState", "AttackDamage") or 0
    for i = 1, #enemyCreeps do
        local c = enemyCreeps[i]
        if c ~= nil and c:IsAlive() then
            local d = Distance(bot:GetLocation(), c:GetLocation())
            if d <= attackRange + 60 and c:GetHealth() <= atkDmg + 5 then
                bot:Action_AttackUnit(c, true)
                return BT.RUNNING
            end
        end
    end
    -- джангл
    if #neutrals > 0 then
        local t = FindLowestHPUnit(neutrals)
        if t ~= nil then
            local d = Distance(bot:GetLocation(), t:GetLocation())
            if d <= attackRange + 60 then
                bot:Action_AttackUnit(t, true)
                return BT.RUNNING
            else
                bot:Action_MoveToLocation(t:GetLocation())
                return BT.RUNNING
            end
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: LANE CONTROL
-- =========================================================================
function Logic.LaneControl(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    local allyCreeps = bb:Get("TacticalState", "NearbyAllyCreeps") or {}
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies > 0 then return BT.FAILURE end

    -- если союзных крипов больше — пушим
    if #allyCreeps >= #enemyCreeps then
        local t = FindLowestHPUnit(enemyCreeps)
        if t ~= nil then
            bot:Action_AttackUnit(t, true)
            return BT.RUNNING
        end
    end
    -- если вражеских больше — фризим линию (не атакуем)
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: DEFENSIVE RETREAT
-- =========================================================================
function Logic.DefensiveRetreat(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local allies = bb:Get("TacticalState", "NearbyAllyHeroes") or {}
    -- отступаем если HP низкое и врагов больше
    if hp < 0.35 and #enemies > #allies then
        local fountain = GetFountainLoc(bot)
        if fountain ~= nil then
            bot:Action_MoveToLocation(fountain)
            return BT.RUNNING
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: AGGRESSIVE PUSH
-- =========================================================================
function Logic.AggressivePush(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    if hp < 0.6 then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies > 0 then return BT.FAILURE end
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    local enemyTowers = bb:Get("TacticalState", "NearbyEnemyTowers") or {}

    -- сначала клирим крипов
    if #enemyCreeps > 0 then
        local t = FindLowestHPUnit(enemyCreeps)
        if t ~= nil then
            bot:Action_AttackUnit(t, true)
            return BT.RUNNING
        end
    end
    -- потом башню
    if #enemyTowers > 0 then
        local t = FindLowestHPUnit(enemyTowers)
        if t ~= nil then
            bot:Action_AttackUnit(t, true)
            return BT.RUNNING
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: FARM AND FIGHT
-- =========================================================================
function Logic.FarmAndFight(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    local hp = bb:Get("SelfState", "HP") or 1.0

    -- если враг рядом и HP достаточно — сражаемся
    if #enemies > 0 and hp > 0.4 then
        local target = bb:Get("TacticalState", "TargetEnemyHero")
        if target ~= nil and target:IsAlive() then
            local dist = Distance(bot:GetLocation(), target:GetLocation())
            local attackRange = bb:Get("SelfState", "AttackRange") or 550
            if dist <= attackRange then
                bot:Action_AttackUnit(target, true)
                return BT.RUNNING
            else
                bot:Action_MoveToLocation(target:GetLocation())
                return BT.RUNNING
            end
        end
    end
    -- иначе фармим
    if #enemyCreeps > 0 then
        local t = FindLowestHPUnit(enemyCreeps)
        if t ~= nil then
            bot:Action_AttackUnit(t, true)
            return BT.RUNNING
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: DYNAMIC RETREAT THRESHOLD
-- =========================================================================
function Logic.DynamicRetreatThreshold(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return 0.3 end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local allies = bb:Get("TacticalState", "NearbyAllyHeroes") or {}
    local threat = bb:Get("TacticalState", "ActiveThreatLevel") or 0
    local threshold = 0.3
    if #enemies > #allies then threshold = 0.4 end
    if threat >= 3 then threshold = 0.5 end
    if threat >= 5 then threshold = 0.6 end
    bb:Set("SelfState", "RetreatThreshold", threshold)
    return threshold
end

-- =========================================================================
-- ЛОГИКА: FARM EFFICIENCY SCORE
-- =========================================================================
function Logic.FarmEfficiencyScore(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return 0 end
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    local neutrals = bb:Get("TacticalState", "NearbyNeutralCreeps") or {}
    local score = #enemyCreeps * 10 + #neutrals * 5
    local hp = bb:Get("SelfState", "HP") or 1.0
    if hp < 0.5 then score = score * 0.5 end
    bb:Set("SelfState", "FarmScore", score)
    return score
end

-- =========================================================================
-- ЛОГИКА: KILL PROBABILITY
-- =========================================================================
function Logic.KillProbability(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return 0 end
    local target = bb:Get("TacticalState", "TargetEnemyHero")
    if target == nil or not target:IsAlive() then return 0 end
    local burst = bb:Get("SelfState", "BurstDamage") or 0
    local targetHP = target:GetHealth()
    local prob = 0
    if burst >= targetHP then prob = 0.9
    elseif burst >= targetHP * 0.7 then prob = 0.6
    elseif burst >= targetHP * 0.4 then prob = 0.3
    else prob = 0.1 end
    -- корректируем на дистанцию
    local dist = Distance(bot:GetLocation(), target:GetLocation())
    local attackRange = bb:Get("SelfState", "AttackRange") or 550
    if dist > attackRange * 2 then prob = prob * 0.5 end
    bb:Set("TacticalState", "KillProbability", prob)
    return prob
end

-- =========================================================================
-- ЛОГИКА: LANE SWAP
-- =========================================================================
function Logic.LaneSwap(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local time = bb:Get("MacroState", "CurrentGameTime") or 0
    if time < 300 then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies > 0 then return BT.FAILURE end
    -- если на линии слишком много врагов — меняем линию
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    if #enemyCreeps > 8 then
        local currentLane = bb:Get("MacroState", "ActiveLane")
        local newLane = LANE_MID
        if currentLane == LANE_MID then newLane = LANE_TOP end
        if currentLane == LANE_TOP then newLane = LANE_BOT end
        if currentLane == LANE_BOT then newLane = LANE_TOP end
        bb:Set("MacroState", "ActiveLane", newLane)
        bb:Set("MacroState", "FarmLane", newLane)
        return BT.SUCCESS
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: TOWER PROTECT
-- =========================================================================
function Logic.TowerProtect(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local allyTowers = bb:Get("TacticalState", "NearbyAllyTowers") or {}
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    -- если враги атакуют нашу башню
    local towerUnderAttack = false
    for i = 1, #allyTowers do
        local t = allyTowers[i]
        if t ~= nil and t:IsAlive() then
            -- проверяем HP башни
            if t:GetHealth() / t:GetMaxHealth() < 0.5 then
                towerUnderAttack = true
                break
            end
        end
    end
    if not towerUnderAttack then return BT.FAILURE end
    if #enemies > 0 and #enemyCreeps == 0 then return BT.FAILURE end
    -- атакуем вражеских крипов у башни
    local t = FindLowestHPUnit(enemyCreeps)
    if t ~= nil then
        bot:Action_AttackUnit(t, true)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: HIGH GROUND SIEGE
-- =========================================================================
function Logic.HighGroundSiege(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies > 0 then return BT.FAILURE end
    local enemyTowers = bb:Get("TacticalState", "NearbyEnemyTowers") or {}
    if #enemyTowers == 0 then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    if hp < 0.6 then return BT.FAILURE end
    -- атакуем башню
    local t = FindLowestHPUnit(enemyTowers)
    if t ~= nil then
        bot:Action_AttackUnit(t, true)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: FOUNTAIN HEALING
-- =========================================================================
function Logic.FountainHealing(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    local mp = bb:Get("SelfState", "MP") or 1.0
    if hp > 0.9 and mp > 0.9 then return BT.FAILURE end
    local fountain = GetFountainLoc(bot)
    if fountain == nil then return BT.FAILURE end
    local d = Distance(bot:GetLocation(), fountain)
    if d <= 200 then
        -- стоим на фонтане, ждём регена
        return BT.SUCCESS
    end
    if hp < 0.5 or mp < 0.5 then
        bot:Action_MoveToLocation(fountain)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: ITEM SELL (продажа ненужных предметов)
-- =========================================================================
function Logic.SellItems(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return end
    local gold = bb:Get("SelfState", "Gold") or 0
    -- если инвентарь полон и нужен слот — продаём стартовые предметы
    local full = true
    for i = 0, 5 do
        if bot:GetItemInSlot(i) == nil then full = false; break end
    end
    if not full then return end
    -- продаём wraith_band если есть лучший предмет
    for i = 0, 5 do
        local it = bot:GetItemInSlot(i)
        if it ~= nil then
            local n = it:GetName()
            if n == "item_wraith_band" or n == "item_null_talisman" or n == "item_bracer" then
                -- проверяем есть ли более дорогой предмет
                local hasBetter = false
                for j = 0, 5 do
                    local it2 = bot:GetItemInSlot(j)
                    if it2 ~= nil and it2:GetName() ~= n then
                        local c1 = ItemCost(n)
                        local c2 = ItemCost(it2:GetName())
                        if c2 > c1 * 2 then hasBetter = true; break end
                    end
                end
                if hasBetter then
                    pcall(function() bot:Action_SellItem(it) end)
                    return
                end
            end
        end
    end
end

-- =========================================================================
-- ЛОГИКА: CONSUMABLE USAGE
-- =========================================================================
function Logic.UseConsumables(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    local mp = bb:Get("SelfState", "MP") or 1.0
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}

    -- Healing Salve
    if hp < 0.5 and #enemies == 0 then
        for i = 0, 15 do
            local it = bot:GetItemInSlot(i)
            if it ~= nil and it:GetName() == "item_flask" then
                pcall(function() bot:Action_UseAbilityOnEntity(it, bot) end)
                return BT.RUNNING
            end
        end
    end
    -- Tango
    if hp < 0.7 and #enemies == 0 then
        for i = 0, 15 do
            local it = bot:GetItemInSlot(i)
            if it ~= nil and it:GetName() == "item_tango" then
                -- используем на дереве
                local trees = {}
                local ok, t = pcall(function() return bot:GetNearbyTrees(200) end)
                if ok and t ~= nil and #t > 0 then
                    pcall(function() bot:Action_UseAbilityOnTree(it, t[1]) end)
                    return BT.RUNNING
                end
            end
        end
    end
    -- Clarity
    if mp < 0.4 and #enemies == 0 then
        for i = 0, 15 do
            local it = bot:GetItemInSlot(i)
            if it ~= nil and it:GetName() == "item_clarity" then
                pcall(function() bot:Action_UseAbilityOnEntity(it, bot) end)
                return BT.RUNNING
            end
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: SMOKE USAGE
-- =========================================================================
function Logic.UseSmoke(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local smoke, _ = HasItem(bot, "item_smoke_of_deceit")
    if smoke == nil or smoke:GetCooldownTimeRemaining() > 0 then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies > 0 then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    if hp < 0.6 then return BT.FAILURE end
    -- используем smoke для ганка/ротации
    pcall(function() bot:Action_UseAbility(smoke) end)
    return BT.RUNNING
end

-- =========================================================================
-- ЛОГИКА: AEGIS USAGE
-- =========================================================================
function Logic.UseAegis(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    -- Aegis автоматически ресает; ничего не делаем
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: REFRESHER USAGE
-- =========================================================================
function Logic.UseRefresher2(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local ref, _ = HasItem(bot, "item_refresher")
    if ref == nil or ref:GetCooldownTimeRemaining() > 0 then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies < 2 then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    if hp < 0.4 then return BT.FAILURE end
    -- используем если assassinate на кд
    local assassinate = FindAbility(bot, ABILITY_ASSASSINATE)
    if assassinate ~= nil and assassinate:GetCooldownTimeRemaining() > 5 then
        pcall(function() bot:Action_UseAbility(ref) end)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: LANE EQUILIBRIUM ADVANCED
-- =========================================================================
function Logic.LaneEquilibriumAdvanced(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    local allyCreeps = bb:Get("TacticalState", "NearbyAllyCreeps") or {}
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies > 0 then return BT.FAILURE end

    -- если союзных крипов больше — атакуем вражеских (пушим)
    if #allyCreeps > #enemyCreeps + 1 then
        local t = FindLowestHPUnit(enemyCreeps)
        if t ~= nil then
            bot:Action_AttackUnit(t, true)
            return BT.RUNNING
        end
    end
    -- если вражеских больше — фризим (не атакуем крипов, стоим)
    if #enemyCreeps > #allyCreeps + 2 then
        return BT.SUCCESS  -- стоим, ждём
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: CREEP AGGRO CONTROL
-- =========================================================================
function Logic.CreepAggroControl(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    local enemyHeroes = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemyHeroes == 0 then return BT.FAILURE end
    -- если враг рядом, атакуем крипа чтобы не тащить аггро на себя
    local t = FindLowestHPUnit(enemyCreeps)
    if t ~= nil then
        bot:Action_AttackUnit(t, true)
        return BT.RUNNING
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: SMART RETREAT
-- =========================================================================
function Logic.SmartRetreat(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    local threshold = bb:Get("SelfState", "RetreatThreshold") or 0.3
    if hp > threshold then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies == 0 then return BT.FAILURE end

    -- ищем безопасный путь к фонтану
    local fountain = GetFountainLoc(bot)
    if fountain == nil then return BT.FAILURE end

    -- если есть TP — используем
    local tp, _ = HasItem(bot, "item_tpscroll")
    if tp ~= nil and tp:GetCooldownTimeRemaining() <= 0 then
        bot:Action_UseAbilityOnLocation(tp, fountain)
        return BT.RUNNING
    end

    -- иначе бежим
    bot:Action_MoveToLocation(fountain)
    return BT.RUNNING
end

-- =========================================================================
-- ЛОГИКА: INITIATION (инициация боя)
-- =========================================================================
function Logic.Initiation(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    if hp < 0.6 then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local allies = bb:Get("TacticalState", "NearbyAllyHeroes") or {}
    if #enemies == 0 then return BT.FAILURE end
    if #allies < 2 then return BT.FAILURE end

    -- Sniper не инициирует, но может помочь с Shrapnel
    local shrapnel = FindAbility(bot, ABILITY_SHRAPNEL)
    if shrapnel ~= nil and shrapnel:GetLevel() > 0
       and shrapnel:GetCooldownTimeRemaining() <= 0
       and bot:GetMana() >= shrapnel:GetManaCost() then
        local target = bb:Get("TacticalState", "TargetEnemyHero")
        if target ~= nil and target:IsAlive() then
            local dist = Distance(bot:GetLocation(), target:GetLocation())
            if dist <= shrapnel:GetCastRange() then
                bot:Action_UseAbilityOnLocation(shrapnel, target:GetLocation())
                return BT.RUNNING
            end
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: PEELING (защита керри/саппортов)
-- =========================================================================
function Logic.Peeling(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local allies = bb:Get("TacticalState", "NearbyAllyHeroes") or {}
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies == 0 then return BT.FAILURE end

    -- ищем союзника с низким HP
    local lowAlly = nil
    for i = 1, #allies do
        local a = allies[i]
        if a ~= nil and a:IsAlive() then
            if a:GetHealth() / a:GetMaxHealth() < 0.3 then
                lowAlly = a
                break
            end
        end
    end
    if lowAlly == nil then return BT.FAILURE end

    -- атакуем врага, ближайшего к этому союзнику
    local nearestEnemy = nil
    local nearDist = 1e9
    for i = 1, #enemies do
        local e = enemies[i]
        if e ~= nil and e:IsAlive() then
            local d = Distance(e:GetLocation(), lowAlly:GetLocation())
            if d < nearDist then nearDist = d; nearestEnemy = e end
        end
    end
    if nearestEnemy ~= nil then
        local dist = Distance(bot:GetLocation(), nearestEnemy:GetLocation())
        local attackRange = bb:Get("SelfState", "AttackRange") or 550
        if dist <= attackRange then
            bot:Action_AttackUnit(nearestEnemy, true)
            return BT.RUNNING
        else
            bot:Action_MoveToLocation(nearestEnemy:GetLocation())
            return BT.RUNNING
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: VISION CONTROL
-- =========================================================================
function Logic.VisionControl(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    -- проверяем, есть ли варды
    local hasWard = false
    for i = 0, 15 do
        local it = bot:GetItemInSlot(i)
        if it ~= nil and it:GetName() == "item_ward_observer" then hasWard = true; break end
    end
    if not hasWard then return BT.FAILURE end
    -- ставим вард в ключевой точке если нет видимости
    local spots = {
        Vector(-3000, 0, 0), Vector(3000, 0, 0),
        Vector(0, 3000, 0), Vector(0, -3000, 0),
        Vector(-1500, 1500, 0), Vector(1500, -1500, 0),
    }
    local myPos = bot:GetLocation()
    local bestSpot, bestDist = nil, 1e9
    for i = 1, #spots do
        local sp = spots[i]
        local d = Distance(myPos, sp)
        if d < bestDist and d <= 2000 then
            local vis = true
            local ok, v = pcall(IsLocationVisible, sp)
            if ok then vis = v end
            if not vis then
                bestDist = d
                bestSpot = sp
            end
        end
    end
    if bestSpot == nil then return BT.FAILURE end
    local wardItem = nil
    for i = 0, 15 do
        local it = bot:GetItemInSlot(i)
        if it ~= nil and it:GetName() == "item_ward_observer" then wardItem = it; break end
    end
    if wardItem == nil then return BT.FAILURE end
    if Distance(myPos, bestSpot) <= 500 then
        bot:Action_UseAbilityOnLocation(wardItem, bestSpot)
        return BT.RUNNING
    else
        bot:Action_MoveToLocation(bestSpot)
        return BT.RUNNING
    end
end

-- =========================================================================
-- ЛОГИКА: ECONOMY OPTIMIZATION
-- =========================================================================
function Logic.EconomyOptimization(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return end
    local gold = bb:Get("SelfState", "Gold") or 0
    local time = bb:Get("MacroState", "CurrentGameTime") or 0
    -- если золота много и нет предметов для покупки — копим
    local needBuy = false
    for _, itemName in ipairs(ITEM_BUILD) do
        local it, _ = HasItem(bot, itemName)
        if it == nil then
            local cost = ItemCost(itemName)
            if gold >= cost then needBuy = true; break end
        end
    end
    if not needBuy then
        bb:Set("MacroState", "SavingGold", true)
    else
        bb:Set("MacroState", "SavingGold", false)
    end
end

-- =========================================================================
-- ЛОГИКА: ITEM EFFICIENCY
-- =========================================================================
function Logic.ItemEfficiency(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return 0 end
    local totalValue = 0
    for i = 0, 5 do
        local it = bot:GetItemInSlot(i)
        if it ~= nil then
            totalValue = totalValue + ItemCost(it:GetName())
        end
    end
    bb:Set("SelfState", "ItemValue", totalValue)
    return totalValue
end

-- =========================================================================
-- ЛОГИКА: HERO POWER SPIKE
-- =========================================================================
function Logic.HeroPowerSpike(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return false end
    local level = bb:Get("SelfState", "Level") or 1
    local time = bb:Get("MacroState", "CurrentGameTime") or 0
    -- Sniper power spike: level 6 (assassinate), level 11, level 16
    local isSpike = (level == 6 or level == 11 or level == 16)
    bb:Set("SelfState", "PowerSpike", isSpike)
    return isSpike
end

-- =========================================================================
-- ЛОГИКА: AGGRESSION LEVEL
-- =========================================================================
function Logic.AggressionLevel(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return 0 end
    local hp = bb:Get("SelfState", "HP") or 1.0
    local level = bb:Get("SelfState", "Level") or 1
    local gold = bb:Get("SelfState", "Gold") or 0
    local aggro = 0
    if hp > 0.7 then aggro = aggro + 3 end
    if level >= 6 then aggro = aggro + 2 end
    if gold > 1000 then aggro = aggro + 1 end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local allies = bb:Get("TacticalState", "NearbyAllyHeroes") or {}
    if #allies > #enemies then aggro = aggro + 2 end
    if #enemies > #allies then aggro = aggro - 2 end
    bb:Set("SelfState", "AggressionLevel", aggro)
    return aggro
end

-- =========================================================================
-- ЛОГИКА: DEFENSIVE LEVEL
-- =========================================================================
function Logic.DefensiveLevel(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return 0 end
    local hp = bb:Get("SelfState", "HP") or 1.0
    local threat = bb:Get("TacticalState", "ActiveThreatLevel") or 0
    local def = 0
    if hp < 0.4 then def = def + 3 end
    if threat >= 3 then def = def + 2 end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local allies = bb:Get("TacticalState", "NearbyAllyHeroes") or {}
    if #enemies > #allies then def = def + 2 end
    bb:Set("SelfState", "DefensiveLevel", def)
    return def
end

-- =========================================================================
-- ЛОГИКА: FARM PRIORITY SCORE
-- =========================================================================
function Logic.FarmPriorityScore(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return 0 end
    local enemyCreeps = bb:Get("TacticalState", "NearbyEnemyCreeps") or {}
    local neutrals = bb:Get("TacticalState", "NearbyNeutralCreeps") or {}
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local hp = bb:Get("SelfState", "HP") or 1.0
    if #enemies > 0 then return 0 end
    if hp < 0.4 then return 0 end
    local score = #enemyCreeps * 15 + #neutrals * 8
    bb:Set("SelfState", "FarmPriorityScore", score)
    return score
end

-- =========================================================================
-- ЛОГИКА: KILL PRIORITY SCORE
-- =========================================================================
function Logic.KillPriorityScore(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return 0 end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local killProb = bb:Get("TacticalState", "KillProbability") or 0
    local score = 0
    if #enemies > 0 then
        score = killProb * 100
        local allies = bb:Get("TacticalState", "NearbyAllyHeroes") or {}
        if #allies >= #enemies then score = score + 20 end
    end
    bb:Set("SelfState", "KillPriorityScore", score)
    return score
end

-- =========================================================================
-- ЛОГИКА: OBJECTIVE PRIORITY SCORE
-- =========================================================================
function Logic.ObjectivePriorityScore(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return 0 end
    local time = bb:Get("MacroState", "CurrentGameTime") or 0
    local score = 0
    -- ранняя игра: фарм
    if time < 900 then score = 10 end
    -- мидгейм: объективы
    if time >= 900 and time < 2100 then score = 50 end
    -- лейтгейм: трон
    if time >= 2100 then score = 80 end
    bb:Set("SelfState", "ObjectivePriorityScore", score)
    return score
end

-- =========================================================================
-- ЛОГИКА: DECISION MAKING ENGINE
-- =========================================================================
function Logic.DecisionEngine(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return "IDLE" end
    local farmScore = bb:Get("SelfState", "FarmPriorityScore") or 0
    local killScore = bb:Get("SelfState", "KillPriorityScore") or 0
    local objScore = bb:Get("SelfState", "ObjectivePriorityScore") or 0
    local aggro = bb:Get("SelfState", "AggressionLevel") or 0
    local def = bb:Get("SelfState", "DefensiveLevel") or 0

    if def >= 4 then return "RETREAT" end
    if killScore > 60 and aggro >= 3 then return "KILL" end
    if objScore > 60 then return "OBJECTIVE" end
    if farmScore > 30 then return "FARM" end
    return "LANE"
end

-- =========================================================================
-- ЛОГИКА: COUNTER-PICK AWARENESS
-- =========================================================================
function Logic.CounterPickAwareness(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return end
    local enemies = {}
    local ok, units = pcall(function() return GetUnitList(UNIT_LIST_ENEMY_HEROES) end)
    if ok and units ~= nil then
        for i = 1, #units do
            local u = units[i]
            if u ~= nil and u:IsAlive() then table.insert(enemies, u:GetName()) end
        end
    end
    -- если враги имеют BKB-piercing станы — приоритет BKB
    local needBKB = false
    for i = 1, #enemies do
        local n = enemies[i] or ""
        if string.find(n, "doom") or string.find(n, "beastmaster") or string.find(n, "batrider") then
            needBKB = true
        end
    end
    bb:Set("MacroState", "NeedBKB", needBKB)
end

-- =========================================================================
-- ЛОГИКА: DAMAGE MITIGATION
-- =========================================================================
function Logic.DamageMitigation(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies == 0 then return BT.FAILURE end
    -- если враг кастует способность — уклоняемся (move)
    for i = 1, #enemies do
        local e = enemies[i]
        if e ~= nil and e:IsAlive() and e:IsUsingAbility() then
            local away = bot:GetLocation() + (bot:GetLocation() - e:GetLocation()):Normalized() * 400
            bot:Action_MoveToLocation(away)
            return BT.RUNNING
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: SAVE ALLY (спасение союзника)
-- =========================================================================
function Logic.SaveAlly(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local allies = bb:Get("TacticalState", "NearbyAllyHeroes") or {}
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies == 0 then return BT.FAILURE end
    -- ищем союзника с критически низким HP
    local targetAlly = nil
    for i = 1, #allies do
        local a = allies[i]
        if a ~= nil and a:IsAlive() and a:GetHealth() / a:GetMaxHealth() < 0.2 then
            targetAlly = a
            break
        end
    end
    if targetAlly == nil then return BT.FAILURE end
    -- атакуем врага, бьющего союзника
    local nearestEnemy = nil
    local nearDist = 1e9
    for i = 1, #enemies do
        local e = enemies[i]
        if e ~= nil and e:IsAlive() then
            local d = Distance(e:GetLocation(), targetAlly:GetLocation())
            if d < nearDist then nearDist = d; nearestEnemy = e end
        end
    end
    if nearestEnemy ~= nil then
        local dist = Distance(bot:GetLocation(), nearestEnemy:GetLocation())
        local attackRange = bb:Get("SelfState", "AttackRange") or 550
        if dist <= attackRange then
            bot:Action_AttackUnit(nearestEnemy, true)
            return BT.RUNNING
        else
            bot:Action_MoveToLocation(nearestEnemy:GetLocation())
            return BT.RUNNING
        end
    end
    return BT.FAILURE
end

-- =========================================================================
-- ЛОГИКА: TOWER DIVE (дайв под башню)
-- =========================================================================
function Logic.TowerDive(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    if hp < 0.7 then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    local enemyTowers = bb:Get("TacticalState", "NearbyEnemyTowers") or {}
    if #enemies == 0 then return BT.FAILURE end
    if #enemyTowers == 0 then return BT.FAILURE end
    -- если цель убиваема и мы можем выжить под башней
    local target = bb:Get("TacticalState", "KillTarget")
    if target == nil then return BT.FAILURE end
    local targetHP = target:GetHealth() / target:GetMaxHealth()
    if targetHP > 0.3 then return BT.FAILURE end
    local burst = bb:Get("SelfState", "BurstDamage") or 0
    if burst < target:GetHealth() then return BT.FAILURE end
    -- дайвим
    local dist = Distance(bot:GetLocation(), target:GetLocation())
    local attackRange = bb:Get("SelfState", "AttackRange") or 550
    if dist <= attackRange then
        bot:Action_AttackUnit(target, true)
        return BT.RUNNING
    else
        bot:Action_MoveToLocation(target:GetLocation())
        return BT.RUNNING
    end
end

-- =========================================================================
-- ЛОГИКА: RETREAT PATH (безопасный путь отступления)
-- =========================================================================
function Logic.RetreatPath(bb)
    local bot = bb:GetBotRef()
    if bot == nil then return BT.FAILURE end
    local hp = bb:Get("SelfState", "HP") or 1.0
    if hp > 0.3 then return BT.FAILURE end
    local enemies = bb:Get("TacticalState", "NearbyEnemyHeroes") or {}
    if #enemies == 0 then return BT.FAILURE end
    local fountain = GetFountainLoc(bot)
    if fountain == nil then return BT.FAILURE end
    -- двигаемся к фонтану, избегая врагов
    local myPos = bot:GetLocation()
    local toFountain = (fountain - myPos):Normalized()
    local safePos = myPos + toFountain * 400
    -- проверяем, не ведёт ли путь через врагов
    local blocked = false
    for i = 1, #enemies do
        local e = enemies[i]
        if e ~= nil and e:IsAlive() then
            if Distance(e:GetLocation(), safePos) < 600 then
                blocked = true
                break
            end
        end
    end
    if blocked then
        -- обходим
        local perp = Vector(-toFountain.y, toFountain.x, 0)
        safePos = myPos + perp * 400
    end
    bot:Action_MoveToLocation(safePos)
    return BT.RUNNING
end

function Think()
    if not InitializeBot() then return end
    SyncBlackboard()
    Logic.SelectLane(Blackboard)
    Logic.LaneRotation(Blackboard)
    Logic.CalculateDamage(Blackboard)
    Logic.BurstDamage(Blackboard)
    Logic.SelectBestTarget(Blackboard)
    Logic.CooldownTracking(Blackboard)
    Logic.ThreatAssessment(Blackboard)
    Logic.DynamicRetreatThreshold(Blackboard)
    Logic.FarmEfficiencyScore(Blackboard)
    Logic.KillProbability(Blackboard)
    Logic.HeroPowerSpike(Blackboard)
    Logic.AggressionLevel(Blackboard)
    Logic.DefensiveLevel(Blackboard)
    Logic.FarmPriorityScore(Blackboard)
    Logic.KillPriorityScore(Blackboard)
    Logic.ObjectivePriorityScore(Blackboard)
    Logic.DecisionEngine(Blackboard)
    Logic.EconomyOptimization(Blackboard)
    Logic.ItemEfficiency(Blackboard)
    Logic.UpdateMacro(Blackboard)
    Logic.DynamicItemBuild(Blackboard)
    Logic.AdaptItemBuild(Blackboard)
    Logic.BuyItems(Blackboard)
    Logic.BuyConsumables(Blackboard)
    Logic.UpgradeItems(Blackboard)
    Logic.SellItems(Blackboard)
    Logic.LevelAbilities(Blackboard)
    Logic.FindKillTarget(Blackboard)
    Logic.BuybackDecision(Blackboard)
    Logic.ReactiveItems(Blackboard)
    Logic.MapAwareness(Blackboard)
    Logic.AntiGank(Blackboard)
    Logic.CourierManagement(Blackboard)
    Logic.RoshanTiming(Blackboard)
    Logic.BountyRune(Blackboard)
    Logic.PowerRune(Blackboard)
    Logic.WisdomRune(Blackboard)
    Logic.TPReaction(Blackboard)
    Logic.Escape(Blackboard)
    Logic.Reinforce(Blackboard)
    Logic.ManaManagement(Blackboard)
    Logic.ItemTiming(Blackboard)
    Logic.AdvancedPull(Blackboard)
    Logic.AntiPush(Blackboard)
    Logic.BaseRace(Blackboard)
    Logic.HighGroundDefense(Blackboard)
    Logic.TeamCoordination(Blackboard)
    Logic.ObjectivePriority(Blackboard)
    Logic.SplitPush(Blackboard)
    Logic.DefensiveTeleport(Blackboard)
    Logic.WardRefresh(Blackboard)
    Logic.StackTiming(Blackboard)
    Logic.LanePressure(Blackboard)
    Logic.TPToLane(Blackboard)
    Logic.JungleFarmEfficiency(Blackboard)
    Logic.KillSecure(Blackboard)
    Logic.EnemyAbilityAwareness(Blackboard)
    Logic.FightOrFlight(Blackboard)
    Logic.PositionInFight(Blackboard)
    Logic.AutoAttackControl(Blackboard)
    Logic.ShrapnelOnWave(Blackboard)
    Logic.AssassinateLowTarget(Blackboard)
    Logic.CombatItemUsage(Blackboard)
    Logic.FarmingEfficiency(Blackboard)
    Logic.LaneControl(Blackboard)
    Logic.DefensiveRetreat(Blackboard)
    Logic.AggressivePush(Blackboard)
    Logic.FarmAndFight(Blackboard)
    Logic.LaneSwap(Blackboard)
    Logic.TowerProtect(Blackboard)
    Logic.HighGroundSiege(Blackboard)
    Logic.FountainHealing(Blackboard)
    Logic.UseConsumables(Blackboard)
    Logic.UseSmoke(Blackboard)
    Logic.UseRefresher2(Blackboard)
    Logic.EnemyAbilityAwareness(Blackboard)
    Logic.VisionControl(Blackboard)
    Logic.Peeling(Blackboard)
    Logic.Initiation(Blackboard)
    Logic.SmartRetreat(Blackboard)
    Logic.CreepAggroControl(Blackboard)
    Logic.LaneEquilibriumAdvanced(Blackboard)
    if rootTree ~= nil then
        rootTree:Tick(thisBot, Blackboard)
    end
end

function MinionThink(hMinionUnit)
    -- Контроль иллюзий/крипов (заглушка расширяемая)
end

function CourierThink(hCourierUnit)
    -- Логика курьера (заглушка)
end

function GetDesire()
    return BOT_MODE_DESIRE_NONE
end

return {}
