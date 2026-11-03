--[[
    blackboard.lua
    Централизованный Blackboard для автономного бота Dota 2

    Назначение:
    - Единое "общее сознание" всех нод Behavior Tree
    - Потокобезопасен в рамках одного Lua-состояния (как и весь бот-скриптинг)
    - Предзаполненный шаблон схемы под Self/Tactical/Macro состояние
]]

local Blackboard = {}

-- Внутреннее хранилище
Blackboard._data = {}
Blackboard._botRef = nil

-- Схема по умолчанию (заполняется Data Provider'ом из bot_generic.lua)
Blackboard._schema = {
    -- Состояние самого бота
    SelfState = {
        HP                = 1.0,      -- Отношение текущего HP к максимуму (0.0 - 1.0)
        MP                = 1.0,      -- Отношение текущего MP к максимуму (0.0 - 1.0)
        CurrentAction     = "IDLE",   -- Текущее действие (информационный флаг)
        IsStunned         = false,
        IsHexed           = false,
        IsSilenced        = false,
        IsChanneling      = false,
        IsUsingAbility    = false,
        Gold              = 0,
        Level             = 1,
        Position          = nil,      -- Vector3/Location от GetLocation()
        AbilityCooldowns  = {},       -- {[abilityIndex] = secondsLeft}
        AbilityReady      = {},       -- {[abilityIndex] = bool}
        AbilityManaCost   = {},       -- {[abilityIndex] = manaCost}
        AbilityRange      = {},       -- {[abilityIndex] = castRange}
        AbilityName       = {},       -- {[abilityIndex] = name}
        AbilityLevels     = {},       -- {[abilityIndex] = level}
    },

    -- Тактическое состояние
    TacticalState = {
        TargetEnemyHero        = nil,  -- Handle вражеского героя
        TargetLowestHPEnemyCreep = nil,-- Handle самого слабого вражеского крипa
        TargetLowestHPAllyCreep  = nil,-- Handle самого слабого союзного крипa
        ActiveThreatLevel      = 0,   -- 0 = чисто, 1 = умеренно, 2 = опасно
        NearbyEnemyHeroes      = {},
        NearbyEnemyCreeps      = {},
        NearbyAllyCreeps       = {},
        NearbyAllyHeroes       = {},
        EnemyHeroCount         = 0,
        EnemyCreepCount        = 0,
    },

    -- Макро-состояние
    MacroState = {
        CurrentGameTime = 0.0,        -- GameTime()
        ActiveLane      = nil,        -- "TOP"/"MID"/"BOT"/nil
        BuybackStatus   = false,
        NextItemInQueue = nil,
        IsRetreating    = false,
        IsPushing       = false,
        LaneFront        = nil,        -- точка линии (vector)
    }
}

-- Инициализация Blackboard
function Blackboard:Init()
    self._data = {}
    self._data.SelfState     = self:_DeepCopy(self._schema.SelfState)
    self._data.TacticalState = self:_DeepCopy(self._schema.TacticalState)
    self._data.MacroState    = self:_DeepCopy(self._schema.MacroState)
end

function Blackboard:_DeepCopy(orig)
    if type(orig) ~= "table" then
        return orig
    end
    local copy = {}
    for k, v in pairs(orig) do
        copy[k] = self:_DeepCopy(v)
    end
    return copy
end

-- Геттер: Blackboard:Get("SelfState.HP") либо Blackboard:Get("SelfState", "HP")
function Blackboard:Get(key, subKey)
    if key == nil then
        return nil
    end

    if subKey == nil and type(key) == "string" then
        local dotPos = string.find(key, "%.")
        if dotPos ~= nil then
            local cat = string.sub(key, 1, dotPos - 1)
            local sk  = string.sub(key, dotPos + 1)
            local catTbl = self._data[cat]
            if catTbl == nil then
                return nil
            end
            return catTbl[sk]
        end
    end

    if subKey ~= nil then
        local catTbl = self._data[key]
        if catTbl == nil then
            return nil
        end
        return catTbl[subKey]
    end

    return self._data[key]
end

-- Сеттер: Blackboard:Set("SelfState.HP", 0.24) либо Blackboard:Set("SelfState", "HP", 0.24)
function Blackboard:Set(key, subKeyOrValue, valueIfThird)
    if key == nil then
        return false
    end

    if valueIfThird == nil and subKeyOrValue ~= nil and type(key) == "string" then
        local dotPos = string.find(key, "%.")
        if dotPos ~= nil then
            local cat = string.sub(key, 1, dotPos - 1)
            local sk  = string.sub(key, dotPos + 1)
            local val = subKeyOrValue
            if self._data[cat] == nil then
                self._data[cat] = {}
            end
            self._data[cat][sk] = val
            return true
        end
    end

    if valueIfThird ~= nil then
        if self._data[key] == nil then
            self._data[key] = {}
        end
        self._data[key][subKeyOrValue] = valueIfThird
        return true
    end

    if type(subKeyOrValue) == "table" and valueIfThird == nil then
        self._data[key] = subKeyOrValue
        return true
    end

    return false
end

function Blackboard:GetBotRef()
    return self._botRef
end

function Blackboard:SetBotRef(bot)
    self._botRef = bot
end

return Blackboard
