---This mod code is entirely too complex and long for what it does, but I wanted to experiment setting
---up a simple state machine in preparation for future, more complex move addition mods.
---My apologies if you're reading this to learn how to mod.

local mdk = require("mdk.prelude")
local attach_hook = mdk.attach_hook
local hooks = mdk.hooks

local config = {
  charge_required = 10000,
  active_duration = 10,
  applying_speedup = 2,
  cooldown_duration = 15,
}

---@class SavedHit
---@field timing number
---@field physical number
---@field elemental number
---@field pos { pos: Vector3f, joint: unknown|nil }

---@type integer|nil Time cache invalidated every update cycle
local _time_cache = nil
---@return integer
local function time()
  return _time_cache or os.time()
end

--Start of the madness

---@class State
---@field inner unknown
---@field init fun(): self
---@field is_over fun(self: self): boolean
---@field get_next fun(): State | nil

---@class ChargingState : State
---@field inner {current: integer, required: integer}
local ChargingState = {}
ChargingState.__index = ChargingState

---@class ActiveState : State
---@field inner {start: number, duration: number, hits: SavedHit[]}
local ActiveState = {}
ActiveState.__index = ActiveState

---Applies all the hits again in the same order and at the same positions but <speed> times as fast
---@class ApplyingState : State
---@field inner {start: number, hits: SavedHit[], done: number, speed: number}
local ApplyingState = {}
ApplyingState.__index = ApplyingState

---@class CooldownState : State
---@field inner {start: number, duration: number}
local CooldownState = {}
CooldownState.__index = CooldownState

---@return self
function ChargingState.init()
  return setmetatable({
    inner = { current = 0, required = config.charge_required },
    get_next = function() return ActiveState.init() end
  }, ChargingState)
end

function ChargingState:is_over()
  return self.inner.current >= self.inner.required
end

---@return self
function ActiveState.init()
  return setmetatable({
    inner = { start = time(), duration = config.active_duration, hits = {} },
  }, ActiveState)
end

function ActiveState:is_over()
  return time() > self.inner.start + self.inner.duration
end

function ActiveState:get_next()
  local res = ApplyingState.init()
  res.inner.hits = self.inner.hits
  return res
end

---@return self
function ApplyingState.init()
  return setmetatable({
    inner = { start = time(), hits = {}, done = 0, speed = config.applying_speedup },
    get_next = function() return CooldownState.init() end
  }, ApplyingState)
end

function ApplyingState:is_over()
  return self.inner.done > #self.inner.hits
end

---@return self
function CooldownState.init()
  return setmetatable({
    inner = { start = time(), duration = config.cooldown_duration },
    get_next = function() return ChargingState.init() end
  }, CooldownState)
end

function CooldownState:is_over()
  return time() > self.inner.start + self.inner.duration
end

---@class StateManager
---@field public state State
local StateManager = {}
StateManager.__index = StateManager

---@return self
function StateManager.new()
  return setmetatable({
    state = ChargingState.init()
  }, StateManager)
end

function StateManager:update()
  if self.state:is_over() then
    local next = self.state:get_next()
    if not next then
      log.error("[dmc_vergil] Invalid state")
      self.state = ChargingState.init()
    else
      self.state = next
    end
  end
end

---@generic T : State
---@param state T The state class you want to check against
---@return boolean
function StateManager:is(state)
  return getmetatable(self.state) == state
end

---@generic T : State
---@param state T The state class you want to check against
---@return T | nil state The inner state
function StateManager:as(state)
  if getmetatable(self.state) == state then
    return self.state
  end
  return nil
end

-- End of the madness

local state_manager = StateManager.new()

---Disable the mod in multiplayer, I'm not dealing with that
local is_online = false

local function init()
  state_manager = StateManager.new()

  local lobby_manager = mdk.LobbyManager.new()
  is_online = lobby_manager:is_quest_online()
end

---@param hitInfo HitInfo
local function onStockDamage(hitInfo)
  local physical_damage = hitInfo:get_physical_damage()
  local elemental_damage = hitInfo:get_elemental_damage()

  if state_manager:is(ActiveState) then
    local state = state_manager.state --[[@as ActiveState]]
    local hits = state.inner.hits
    hits[#hits + 1] = {
      timing = time() - state.inner.start,
      physical = physical_damage,
      elemental = elemental_damage,
      pos = hitInfo:get_detailed_position()
    }
  elseif state_manager:is(ChargingState) then
    local state = state_manager.state --[[@as ChargingState]]
    state.inner.current = math.min(state.inner.required, state.inner.current + physical_damage + elemental_damage)
  end
end

local function main()
  attach_hook(hooks.player.start, init)

  attach_hook(hooks.enemy.stockDamage, function(args)
    if is_online or state_manager:is(CooldownState) then return end
    onStockDamage(mdk.HitInfo.new(args[3]))
  end)

  attach_hook(hooks.player.update, function(args)
    if is_online then return end

    local player = mdk.QuestPlayer.new(args[2])
    if not mdk.utils.is_own_player(player) then
      return
    end

    state_manager:update()
  end)
end

re.on_draw_ui(function()
  if imgui.tree_node("DMC Vergil") then
    if state_manager:is(ActiveState) or state_manager:is(ApplyingState) then
      local state = state_manager.state --[[@as ActiveState|ApplyingState]]
      imgui.text(string.format("Hit count: %d", #state.inner.hits))
    end
    local charge = 0
    if state_manager:is(ChargingState) then
      local state = state_manager.state --[[@as ChargingState]]
      charge = state.inner.current / state.inner.required
    elseif state_manager:is(ActiveState) then
      local state = state_manager.state --[[@as ActiveState]]
      charge = 1 - (time() - state.inner.start) / state.inner.duration
    end
    imgui.progress_bar(charge, Vector2f.new(500, 50), string.format("Charge: %d%%", charge))
    imgui.tree_pop()
  end
end)

main()
