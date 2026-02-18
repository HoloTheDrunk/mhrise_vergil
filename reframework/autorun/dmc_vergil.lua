---This mod code is entirely too complex and long for what it does, but I wanted to experiment setting
---up a simple state machine in preparation for future, more complex move addition mods.
---My apologies if you're reading this to learn how to mod.

local show_debug = true
local debug = ""

local mdk = require("mdk.prelude")
local attach_hook = mdk.attach_hook
local hooks = mdk.hooks

local config = {
  charge_required = 1000,
  active_duration = 10,
  active_timescale = 0.2,
  applying_speedup = 2,
  cooldown_duration = 15,
}

---@type mdk.QuestPlayer?
local player = nil

---@class SavedHit
---@field timing number
---@field physical number
---@field elemental number
---@field pos { pos: Vector3f, joint: unknown|nil }

---@type number|nil Time cache invalidated every update cycle
local _time_cache = nil
---@return number
local function time()
  return _time_cache or mdk.utils.get_uptime()
end

---@type number
local last_motion_id = 1

--Timescale management (start)
local scene_manager = sdk.get_native_singleton("via.SceneManager")
local scene_manager_type = sdk.find_type_definition("via.SceneManager") --[[@as RETypeDefinition]]
---@type REManagedObject
local scene = sdk.call_native_func(scene_manager, scene_manager_type, "get_CurrentScene")

---@type REManagedObject
local time_scale_manager = sdk.get_managed_singleton("snow.TimeScaleManager") --[[@as REManagedObject]]
---@type REManagedObject
local camera_manager = sdk.get_managed_singleton("snow.CameraManager") --[[@as REManagedObject]]
---@type REManagedObject
local system_manager = sdk.get_managed_singleton("snow.GameKeyboard") --[[@as REManagedObject]]

---@param speed number
---@return nil
local function set_time_scale(speed)
  scene:call("set_TimeScale", speed)
  time_scale_manager:call("set_TimeScale", speed)
  camera_manager:call("get_GameObject"):call("set_TimeScale", 1.0)
  system_manager:call("get_GameObject"):call("set_TimeScale", 1.0)
end
--Timescale management (end)

--Start of the madness

---@class State
---@field inner unknown
---@field init fun(): self
---@field is_over fun(self: self): boolean
---@field get_next fun(self: self): State | nil
---@field get_name fun(self: self): string
---@field draw_ui fun(self: self): nil

---@class ChargingState : State
---@field inner {current: number, required: number, iai: boolean}
local ChargingState = {}
ChargingState.__index = ChargingState

---@class ActiveState : State
---@field inner {start: number, duration: number, hits: SavedHit[]}
local ActiveState = {}
ActiveState.__index = ActiveState

---Applies all the hits again in the same order and at the same positions but <speed> times as fast
---@class ApplyingState : State
---@field inner {start: number, hits: SavedHit[], done: integer, speed: number}
local ApplyingState = {}
ApplyingState.__index = ApplyingState

---@class CooldownState : State
---@field inner {start: number, duration: number}
local CooldownState = {}
CooldownState.__index = CooldownState

---@return self
function ChargingState.init()
  return setmetatable({
    inner = { current = 0, required = config.charge_required, iai = false },
    get_next = function() return ActiveState.init() end,
    get_name = function() return "Charging" end
  }, ChargingState)
end

function ChargingState:is_over()
  if self.inner.iai and self.inner.current >= self.inner.required then
    return true
  end
  self.inner.iai = false
  return false
end

function ChargingState:draw_ui()
  local charge = self.inner.current / self.inner.required
  imgui.progress_bar(charge, Vector2f.new(400, 40), string.format("Charge: %d%%", math.floor(100 * charge)))
end

---@return self
function ActiveState.init()
  player._remo:call("get_MotLayer0Speed"):call("setSpeed", 0, 2.0 / config.active_timescale)
  set_time_scale(config.active_timescale)
  return setmetatable({
    inner = { start = time(), duration = config.active_duration, hits = {} },
    get_name = function() return "Active" end
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

function ActiveState:draw_ui()
  imgui.text("Hits:")
  imgui.same_line()
  imgui.text_colored(tostring(#self.inner.hits), 0xff9999ff)
  local charge = 1 - (time() - self.inner.start) / self.inner.duration
  imgui.progress_bar(charge, Vector2f.new(400, 40), string.format("Charge: %d%% ⬇", math.floor(100 * charge)))
  for i, hit in pairs(self.inner.hits) do
    imgui.text(string.format("%.1f | %.0f phys %.0f elem", hit.timing, hit.physical, hit.elemental))
  end
end

---@return self
function ApplyingState.init()
  player._remo:call("get_MotLayer0Speed"):call("setSpeed", 0, 1.0)
  set_time_scale(1.)
  return setmetatable({
    inner = { start = time(), hits = {}, done = 0, speed = config.applying_speedup },
    get_next = function() return CooldownState.init() end,
    get_name = function() return "Applying" end
  }, ApplyingState)
end

function ApplyingState:is_over()
  return self.inner.done >= #self.inner.hits
end

function ApplyingState:draw_ui()
  imgui.text("Hits:")
  imgui.same_line()
  imgui.text_colored(string.format("%d / %d", self.inner.done, #self.inner.hits), 0xff9999ff)
end

---@return self
function CooldownState.init()
  return setmetatable({
    inner = { start = time(), duration = config.cooldown_duration },
    get_next = function() return ChargingState.init() end,
    get_name = function() return "Cooldown" end
  }, CooldownState)
end

function CooldownState:is_over()
  return time() > self.inner.start + self.inner.duration
end

function CooldownState:draw_ui()
  imgui.text_colored(
    string.format("Cooldown: %ds", math.ceil(self.inner.start + self.inner.duration - time())),
    0xffff9999
  )
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

function StateManager:to_next()
  local next = self.state:get_next()
  if not next then
    log.error("[dmc_vergil] Invalid state")
    self.state = ChargingState.init()
  else
    self.state = next
  end
end

function StateManager:update()
  if self.state:is_over() then
    self:to_next()
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

---Disable the mod in multiplayer
local is_online = false

local function init(args)
  if args[2] then
    player = mdk.QuestPlayer.new(args[2])
  end
  state_manager = StateManager.new()

  local lobby_manager = mdk.LobbyManager.new()
  is_online = lobby_manager:is_quest_online()
end

---@param hitInfo HitInfo
local function on_stock_damage(hitInfo)
  local physical_damage = hitInfo:get_physical_damage()
  local elemental_damage = hitInfo:get_elemental_damage()

  if state_manager:is(ChargingState) then
    local state = state_manager.state --[[@as ChargingState]]
    state.inner.current = math.min(state.inner.required, state.inner.current + physical_damage + elemental_damage)
  elseif state_manager:is(ActiveState) then
    local state = state_manager.state --[[@as ActiveState]]
    local hits = state.inner.hits
    hits[#hits + 1] = {
      timing = time() - state.inner.start,
      physical = physical_damage,
      elemental = elemental_damage,
      pos = hitInfo:get_detailed_position()
    }
  end
end

local function main()
  attach_hook(hooks.player.start, init)

  attach_hook(hooks.enemy.stockDamage, function(args)
    if is_online or state_manager:is(CooldownState) then return end
    on_stock_damage(mdk.HitInfo.new(args[3]))
  end)

  attach_hook(hooks.player.update, function(args)
    if is_online then return end

    local player = mdk.QuestPlayer.new(args[2])
    if not mdk.utils.is_own_player(player) then
      return
    end

    state_manager:update()

    if state_manager:is(ApplyingState) then
      local state = state_manager.state --[[@as ApplyingState]]
      if #state.inner.hits == 0 then return end

      local now = time()
      --Go through every recorded hit with the speed multiplier and create a damaging shell in the same spot
      while state.inner.done < #state.inner.hits
        and now > state.inner.start + state.inner.hits[state.inner.done + 1].timing / state.inner.speed
      do
        state.inner.done = state.inner.done + 1
        local hit = state.inner.hits[state.inner.done]
        -- TODO: Create a damaging shell at the desired position
      end
    end
  end)

  sdk.hook(
    sdk.find_type_definition("snow.player.PlayerMotionControl"):get_method("lateUpdate") --[[@as REMethodDefinition]],
    function(args)
      local motion_control = sdk.to_managed_object(args[2])
      if not motion_control then return end

      local bid = motion_control:get_field("_OldBankID")
      local mid = motion_control:get_field("_OldMotionID")

      if state_manager:is(ChargingState)
          and bid == mdk.motions.motion_bank_ids.drawn
          and mid == mdk.motions.motions_ids.ls.special_sheathe_iai_spirit_slash
      then
        local state = state_manager.state --[[@as ChargingState]]
        state.inner.iai = true
      elseif state_manager:is(ActiveState)
          and bid ~= mdk.motions.motion_bank_ids.drawn
      then
        set_time_scale(1.0)
        state_manager:to_next()
      end

      if bid == mdk.motions.motion_bank_ids.drawn then
        last_motion_id = mid
      end
    end
  )

  sdk.hook(sdk.find_type_definition("snow.player.PlayerQuestBase"):get_method("updateHitStop"),
    function(args)
	    if state_manager:is(ActiveState) then
		    sdk.to_managed_object(args[2]):call("resetHitStop")
	    end
    end
  )

  re.on_draw_ui(function()
    if imgui.tree_node("DMC Vergil") then
      imgui.text(string.format("State: %s", state_manager.state:get_name()))

      local success, data = pcall(state_manager.state.draw_ui, state_manager.state)
      if not success then
        local error_message = string.format("Failed to render menu: %s", tostring(data))
        imgui.text(error_message)
        log.error(error_message)
      end

      imgui.separator()

      if #debug > 0 then
        imgui.text(string.format("debug: %s", debug))
        -- debug = ""
      end

      imgui.tree_pop()
    end
  end)
end

main()
