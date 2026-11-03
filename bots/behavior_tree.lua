--[[
    behavior_tree.lua
    Behavior Tree фреймворк под Dota 2 Bot API

    Поддерживаемые узлы:
    - BT.Node        : Базовый абстрактный узел
    - BT.Selector    : Fallback. Успех/Running при первом непровалившемся ребёнке
    - BT.Sequence    : Конъюнкция. Провал при первом провалившемся ребёнке
    - BT.Condition   : Чтение из Blackboard -> SUCCESS/FAILURE
    - BT.Action      : Точка исполнения с обязательным safety-gate
]]

local BT = {}

-- Статусы узлов
BT.SUCCESS = "SUCCESS"
BT.FAILURE = "FAILURE"
BT.RUNNING = "RUNNING"

-- Базовый узел
BT.Node = {}
BT.Node.__index = BT.Node

function BT.Node:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.name = o.name or "Node"
    o.children = o.children or {}
    return o
end

function BT.Node:AddChild(child)
    if child == nil then
        return
    end
    table.insert(self.children, child)
end

function BT.Node:Tick(npcBot, blackboard)
    return BT.FAILURE
end

-- SELECTOR (Fallback)
BT.Selector = setmetatable({}, { __index = BT.Node })
BT.Selector.__index = BT.Selector

function BT.Selector:new(o)
    o = BT.Node.new(self, o)
    o.name = o.name or "Selector"
    setmetatable(o, BT.Selector)
    return o
end

function BT.Selector:Tick(npcBot, blackboard)
    if self.children == nil then
        return BT.FAILURE
    end

    for i=1, #self.children do
        local child = self.children[i]
        if child ~= nil and child.Tick ~= nil then
            local status = child:Tick(npcBot, blackboard)
            if status == BT.SUCCESS or status == BT.RUNNING then
                return status
            end
        end
    end

    return BT.FAILURE
end

-- SEQUENCE
BT.Sequence = setmetatable({}, { __index = BT.Node })
BT.Sequence.__index = BT.Sequence

function BT.Sequence:new(o)
    o = BT.Node.new(self, o)
    o.name = o.name or "Sequence"
    setmetatable(o, BT.Sequence)
    return o
end

function BT.Sequence:Tick(npcBot, blackboard)
    if self.children == nil then
        return BT.FAILURE
    end

    for i=1, #self.children do
        local child = self.children[i]
        if child ~= nil and child.Tick ~= nil then
            local status = child:Tick(npcBot, blackboard)
            if status == BT.FAILURE then
                return BT.FAILURE
            end
            if status == BT.RUNNING then
                return BT.RUNNING
            end
        else
            return BT.FAILURE
        end
    end

    return BT.SUCCESS
end

-- CONDITION (только чтение из Blackboard)
BT.Condition = setmetatable({}, { __index = BT.Node })
BT.Condition.__index = BT.Condition

function BT.Condition:new(o)
    o = BT.Node.new(self, o)
    o.name = o.name or "Condition"
    setmetatable(o, BT.Condition)
    o.eval = o.eval or function(npcBot, blackboard) return false end
    return o
end

function BT.Condition:Tick(npcBot, blackboard)
    if self.eval == nil then
        return BT.FAILURE
    end

    local ok, res = pcall(self.eval, npcBot, blackboard)
    if ok and res == true then
        return BT.SUCCESS
    end

    return BT.FAILURE
end

-- ACTION (исполнение с обязательным safety-gate)
BT.Action = setmetatable({}, { __index = BT.Node })
BT.Action.__index = BT.Action

function BT.Action:new(o)
    o = BT.Node.new(self, o)
    o.name = o.name or "Action"
    setmetatable(o, BT.Action)
    o.execute = o.execute or function(npcBot, blackboard) return BT.FAILURE end
    return o
end

function BT.Action:Tick(npcBot, blackboard)
    if npcBot == nil then
        return BT.FAILURE
    end

    -- SAFETY-GATE: не прерывать активные действия бота
    if npcBot:IsUsingAbility() or npcBot:IsChanneling() or npcBot:IsStunned() or npcBot:IsHexed() then
        return BT.RUNNING
    end

    if self.execute == nil then
        return BT.FAILURE
    end

    local ok, res = pcall(self.execute, npcBot, blackboard)
    if not ok then
        return BT.FAILURE
    end

    if res == BT.SUCCESS or res == BT.RUNNING or res == BT.FAILURE then
        return res
    end

    return BT.FAILURE
end

function BT.BuildSelector(name, children)
    local s = BT.Selector:new({ name = name })
    if children ~= nil then
        for i=1, #children do
            s:AddChild(children[i])
        end
    end
    return s
end

function BT.BuildSequence(name, children)
    local seq = BT.Sequence:new({ name = name })
    if children ~= nil then
        for i=1, #children do
            seq:AddChild(children[i])
        end
    end
    return seq
end

return BT
