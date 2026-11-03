--[[
    blackboard.lua
    Централизованный Blackboard для автономного бота Dota 2 (Sniper).

    Единое "общее сознание" всех нод Behavior Tree.
    Потокобезопасен в рамках одного Lua-состояния.
]]

local Blackboard = {}

Blackboard._data = {}
Blackboard._botRef = nil

Blackboard._schema = {
    SelfState = {
        HP = 1.0,
        MP = 1.0,
        CurrentAction = "IDLE",
        IsStunned = false,
        IsHexed = false,
        IsSilenced = false,
        IsChanneling = false,
        IsUsingAbility = false,
        Gold = 0,
        Level = 1,
        Position = nil,
        AbilityCooldowns = {},
        AbilityReady = {},
        AbilityManaCost = {},
        AbilityRange = {},
        AbilityName = {},
        AbilityLevels = {},
        -- Sniper-specific / economy
        AttackDamage = 0,
        AttackRange = 0,
        SecondsPerAttack = 1.0,
        Inventory = {},        -- {slot= itemHandle}
        Stash = {},
        HasTP = false,
        BuybackAvailable = false,
    },
    TacticalState = {
        TargetEnemyHero = nil,
        KillTarget = nil,          -- герой, которого можно убить прямо сейчас
        TargetLowestHPEnemyCreep = nil,
        TargetLowestHPAllyCreep = nil,
        ActiveThreatLevel = 0,
        NearbyEnemyHeroes = {},
        NearbyEnemyCreeps = {},
        NearbyAllyCreeps = {},
        NearbyAllyHeroes = {},
        NearbyNeutralCreeps = {},
        NearbyEnemyTowers = {},
        NearbyAllyTowers = {},
        EnemyHeroCount = 0,
        EnemyCreepCount = 0,
        AllyHeroCount = 0,
        CanKillAnyHero = false,
        IsInTeamFight = false,
    },
    MacroState = {
        CurrentGameTime = 0.0,
        ActiveLane = nil,
        BuybackStatus = false,
        NextItemInQueue = nil,
        IsRetreating = false,
        IsPushing = false,
        LaneFront = nil,
        FarmLane = nil,            -- линия для фарма
        ShouldPush = false,
        ShouldDefend = false,
        ShouldRoam = false,
        RuneTargets = {},          -- список локаций рун
        GamePhase = "laning",      -- laning / midgame / lategame
    }
}

function Blackboard:Init()
    self._data = {}
    self._data.SelfState     = self:_DeepCopy(self._schema.SelfState)
    self._data.TacticalState = self:_DeepCopy(self._schema.TacticalState)
    self._data.MacroState    = self:_DeepCopy(self._schema.MacroState)
end

function Blackboard:_DeepCopy(orig)
    if type(orig) ~= "table" then return orig end
    local copy = {}
    for k, v in pairs(orig) do copy[k] = self:_DeepCopy(v) end
    return copy
end

function Blackboard:Get(key, subKey)
    if key == nil then return nil end
    if subKey == nil and type(key) == "string" then
        local dotPos = string.find(key, "%.")
        if dotPos ~= nil then
            local cat = string.sub(key, 1, dotPos - 1)
            local sk  = string.sub(key, dotPos + 1)
            local catTbl = self._data[cat]
            if catTbl == nil then return nil end
            return catTbl[sk]
        end
    end
    if subKey ~= nil then
        local catTbl = self._data[key]
        if catTbl == nil then return nil end
        return catTbl[subKey]
    end
    return self._data[key]
end

function Blackboard:Set(key, subKeyOrValue, valueIfThird)
    if key == nil then return false end
    if valueIfThird == nil and subKeyOrValue ~= nil and type(key) == "string" then
        local dotPos = string.find(key, "%.")
        if dotPos ~= nil then
            local cat = string.sub(key, 1, dotPos - 1)
            local sk  = string.sub(key, dotPos + 1)
            local val = subKeyOrValue
            if self._data[cat] == nil then self._data[cat] = {} end
            self._data[cat][sk] = val
            return true
        end
    end
    if valueIfThird ~= nil then
        if self._data[key] == nil then self._data[key] = {} end
        self._data[key][subKeyOrValue] = valueIfThird
        return true
    end
    if type(subKeyOrValue) == "table" and valueIfThird == nil then
        self._data[key] = subKeyOrValue
        return true
    end
    return false
end

function Blackboard:GetBotRef() return self._botRef end
function Blackboard:SetBotRef(bot) self._botRef = bot end

return Blackboard
