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

    -- Sequences
    local seqRetreat = BT.BuildSequence("EmergencyRetreat", { condLowHP, actRetreat })
    local seqKill    = BT.BuildSequence("KillHero", { condKillTarget, actCombat })
    local seqTeamFight = BT.BuildSequence("TeamFight", { condTeamFight, actTeamFight })
    local seqRoshan  = BT.BuildSequence("Roshan", { actRoshan })
    local seqPush    = BT.BuildSequence("PushObjective", { condShouldPush, actPush })
    local seqDefend  = BT.BuildSequence("DefendBase", { actDefend })
    local seqCombat  = BT.BuildSequence("MicroCombat", { condEnemyHero, actCombat })
    local seqWard    = BT.BuildSequence("PlaceWard", { condHasWard, actWard })
    local seqRune    = BT.BuildSequence("CollectRune", { actRune })
    local seqCreep   = BT.BuildSequence("CreepMicro", { condCreeps, actFarm })
    local seqLane    = BT.BuildSequence("IdleLaningMacro", { actLane })

    -- Root Selector: приоритет retreat > kill > teamfight > defend > push > combat > ward > rune > farm > lane
    local root = BT.BuildSelector("RootSelector", {
        seqRetreat, seqKill, seqTeamFight, seqDefend, seqPush, seqCombat,
        seqWard, seqRune, seqCreep, seqLane, seqRoshan
    })
    return root
end

-- =========================================================================
-- ENGINE HOOKS
-- =========================================================================
function Think()
    if not InitializeBot() then return end
    SyncBlackboard()
    Logic.UpdateMacro(Blackboard)
    Logic.BuyItems(Blackboard)
    Logic.FindKillTarget(Blackboard)
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
