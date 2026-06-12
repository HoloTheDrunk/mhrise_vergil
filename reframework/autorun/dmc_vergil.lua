---This mod code is entirely too complex and long for what it does, but I wanted
---to experiment in preparation for future, more complex mods.
---My condolences if you're here to learn how to mod.


local mdk = require("mdk.prelude")
local attach_hook = mdk.attach_hook
local hooks = mdk.hooks

local StateManager = require("mdk.utils.StateManager")

local config = {
  states = {
    charging = {
      charge_required = 500,
    },
    active = {
      duration = 20,
      timescale = 0.2,
      player_speedup = 1.5,
    },
    applying = {
      speedup = 1 / 0.2,
    },
    cooldown = {
      duration = 5,
    },
  },
  ui = {
    enable_debug = false,
    -- Based on what looked decent on my screen
    x = 427 / 2560,
    y = 230 / 1440,
    size = 20,
    segments = 4,
    colors = {
      primary = 0xffffffff,
      secondary = 0xffffff88,
      background = 0x77888888,
      applying = 0xff8888ff,
      cooldown = 0xff888888,
    },
    animations = {
      pulse = {
        frequency = 3,
      },
      maxed_charge = {
        duration = 2,
        size_ratio = 20,
      }
    }
  }
}

---Never tested in multiplayer
local is_online = false

---Technically insane but I need the linter to shut up
---@type Vector2f
local screen_size = nil
---@type Vector2f
local ui_position = Vector2f.new(config.ui.x, config.ui.y)

---@type QuestPlayer?
local player = nil

---@type BehaviorTree | nil
local player_bhvt = nil

---@type LongSword?
local long_sword = nil

---@class SavedHit
---@field timing number
---@field physical number
---@field elemental number
---@field pos { pos: Vector3f, joint: Joint|nil }

local function init_player_bhvt()
  if not player then return end
  player_bhvt = player:get_behavior_tree()
end

local function init_weapon()
  if not player then return end
  long_sword = player:get_long_sword()
  if not long_sword then return end
end

local function get_screen_size()
  local scene_manager = sdk.get_native_singleton("via.SceneManager")
  if not scene_manager then
    return
  end

  local scene_view = sdk.call_native_func(
    scene_manager,
    sdk.find_type_definition("via.SceneManager") --[[@as RETypeDefinition]],
    "get_MainView"
  )
  if not scene_view then
    return
  end

  local size = scene_view:call("get_Size")
  if not size then
    return
  end

  screen_size = Vector2f.new(size:get_field("w"), size:get_field("h"))
  ui_position = Vector2f.new(screen_size.x * config.ui.x, screen_size.y * config.ui.y)
end

---@type number|nil Time cache invalidated every update cycle
local _time_cache = nil
---@return number
local function time()
  if not _time_cache then
    _time_cache = mdk.game.time.get_uptime()
  end
  return _time_cache --[[@as number]]
end

---@type number
local last_motion_id = 1

---@type REManagedObject
local scene_manager = sdk.get_native_singleton("via.SceneManager") --[[@as REManagedObject]]
local scene_manager_type = sdk.find_type_definition("via.SceneManager") --[[@as RETypeDefinition]]
---@type REManagedObject
local scene = sdk.call_native_func(scene_manager, scene_manager_type, "get_CurrentScene")

---@type REManagedObject
local gui_manager = sdk.get_managed_singleton("snow.gui.GuiManager") --[[@as REManagedObject]]

---@type REManagedObject
local time_scale_manager = sdk.get_managed_singleton("snow.TimeScaleManager") --[[@as REManagedObject]]
---@type REManagedObject
local camera_manager = sdk.get_managed_singleton("snow.CameraManager") --[[@as REManagedObject]]
---@type REManagedObject
local system_manager = sdk.get_managed_singleton("snow.GameKeyboard") --[[@as REManagedObject]]

---@type Transition?
local time_scale_transition = nil
---@type Transition?
local player_speed_transition = nil

---@param speed number
---@return nil
local function set_time_scale(speed)
  scene:call("set_TimeScale", speed)
  time_scale_manager:call("set_TimeScale", speed)
  camera_manager:call("get_GameObject"):call("set_TimeScale", 1.0)
  system_manager:call("get_GameObject"):call("set_TimeScale", speed)
end

---@param speed number
---@param duration number
---@return nil
local function set_time_scale_target(speed, duration)
  time_scale_transition = mdk.Transition.Transition.new(scene:call("get_TimeScale"), speed, time(), duration)
end

---@param speed number
---@param duration number
---@return nil
local function set_player_speed_target(speed, duration)
  player_speed_transition = mdk.Transition.Transition.new(scene:call("get_TimeScale"), speed, time(), duration)
end
--Timescale management (end)

--Start of the madness

---Builds up charge based on damage done by the player
---@class ChargingState : State
---@field inner {current: number, required: number, iai: boolean, maxed_at: integer?}
local ChargingState = {}
ChargingState.__index = ChargingState

---Records hits' position and damage
---@class ActiveState : State
---@field inner {start: number, duration: number, hits: SavedHit[]}
local ActiveState = {}
ActiveState.__index = ActiveState

---Applies all the hits again in the same order and at the same positions but <speed> times as fast
---@class ApplyingState : State
---@field inner {start: number, hits: SavedHit[], done: integer, speed: number}
local ApplyingState = {}
ApplyingState.__index = ApplyingState

---Cooldown before the player can start accumulating charge again
---@class CooldownState : State
---@field inner {start: number, duration: number}
local CooldownState = {}
CooldownState.__index = CooldownState

---@return self
function ChargingState.init()
  return setmetatable({
    inner = {
      current = 0,
      required = config.states.charging.charge_required,
      iai = false,
      maxed_at = nil,
    },
    get_next = function() return ActiveState.init() end,
    get_name = function() return "Charging" end
  }, ChargingState)
end

function ChargingState:is_over()
  if self.inner.current >= self.inner.required then
    if not self.inner.maxed_at then
      self.inner.maxed_at = time()
    end
    if self.inner.iai then
      return true
    end
  end
  self.inner.iai = false
  return false
end

function ChargingState:draw_ui()
  if config.ui.enable_debug then
    local charge = self.inner.current / self.inner.required
    imgui.progress_bar(charge, Vector2f.new(400, 40), string.format("Charge: %d%%", math.floor(100 * charge)))
    _, config.ui.segments = imgui.drag_int("ui.segments", config.ui.segments, 0.1, 3, 12)
  end
end

function ChargingState:draw_hud()
  local charge = self.inner.current / self.inner.required

  -- short-hands
  local ui = config.ui
  local pos = ui_position

  local primary_color = ui.colors.primary
  local secondary_color = ui.colors.secondary
  if charge >= 1 then
    primary_color = secondary_color
    -- Pulse to and from a lighter color
    secondary_color = secondary_color + 0x33 * math.abs(math.sin(ui.animations.pulse.frequency * time() * math.pi))
  end

  -- Background
  draw.filled_circle(pos.x, pos.y, ui.size, 0x77888888, ui.segments)

  -- Border
  draw.outline_circle(pos.x, pos.y, ui.size, primary_color, ui.segments)
  draw.outline_circle(pos.x, pos.y, ui.size * 1.1, primary_color, ui.segments)

  -- Progress indicator
  draw.outline_circle(pos.x, pos.y, ui.size * (1 + .5 * charge), primary_color, ui
    .segments)
  draw.outline_circle(pos.x, pos.y, ui.size * (1 + .6 * charge), primary_color, ui
    .segments)
  draw.filled_circle(pos.x, pos.y, charge * ui.size, secondary_color, ui.segments)

  if self.inner.maxed_at and time() < self.inner.maxed_at + 1 then
    local t = (time() - self.inner.maxed_at) / 2;
    local alpha = math.floor((1 - t) * 0xff) << 24
    draw.outline_circle(pos.x, pos.y, ui.size + screen_size.y * t,
      alpha + (ui.colors.secondary & 0x00ffffff), ui.segments)
  end
end

---@return self
function ActiveState.init()
  if player ~= nil then
    set_player_speed_target(config.states.active.player_speedup / config.states.active.timescale, 1.)
    set_time_scale_target(config.states.active.timescale, 1.)
  end
  return setmetatable({
    inner = { start = time(), duration = config.states.active.duration, hits = {} },
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
  if config.ui.enable_debug then
    imgui.text("Hits:")
    imgui.same_line()
    imgui.text_colored(tostring(#self.inner.hits), 0xff9999ff)
    local charge = 1 - (time() - self.inner.start) / self.inner.duration
    imgui.progress_bar(charge, Vector2f.new(400, 40), string.format("Charge: %d%% ⬇", math.floor(100 * charge)))
  end
end

function ActiveState:draw_hud()
  local charge = 1 - (time() - self.inner.start) / self.inner.duration

  -- short-hands
  local ui = config.ui
  local pos = ui_position

  -- Background
  draw.filled_circle(pos.x, pos.y, ui.size, ui.colors.background, ui.segments)

  -- Border
  draw.outline_circle(pos.x, pos.y, ui.size, ui.colors.secondary, ui.segments)
  draw.outline_circle(pos.x, pos.y, ui.size * 1.1, ui.colors.secondary, ui.segments)

  -- Progress indicator
  draw.outline_circle(pos.x, pos.y, ui.size * (1 + .5 * charge), ui.colors.secondary, ui.segments)
  draw.outline_circle(pos.x, pos.y, ui.size * (1 + .6 * charge), ui.colors.secondary, ui.segments)
  draw.filled_circle(pos.x, pos.y, charge * ui.size, ui.colors.secondary, ui.segments)
end

---@return self
function ApplyingState.init()
  if player ~= nil then
    set_player_speed_target(1., 1.)
    set_time_scale_target(1., 1.)
  end
  return setmetatable({
    inner = { start = time(), hits = {}, done = 0, speed = config.states.applying.speedup },
    get_next = function() return CooldownState.init() end,
    get_name = function() return "Applying" end
  }, ApplyingState)
end

function ApplyingState:is_over()
  return self.inner.done >= #self.inner.hits
end

function ApplyingState:draw_ui()
  if config.ui.enable_debug then
    imgui.text("Hits:")
    imgui.same_line()
    imgui.text_colored(string.format("%d / %d", self.inner.done, #self.inner.hits), 0xff9999ff)
  end
end

function ApplyingState:draw_hud()
  -- short-hands
  local ui = config.ui
  local pos = ui_position

  -- Background
  draw.filled_circle(pos.x, pos.y, ui.size, ui.colors.background, ui.segments)

  -- Border
  draw.outline_circle(pos.x, pos.y, ui.size, ui.colors.applying, ui.segments)
  draw.outline_circle(pos.x, pos.y, ui.size * 1.1, ui.colors.applying, ui.segments)

  -- Progress indicator
  draw.outline_circle(pos.x, pos.y, ui.size * 1.5, ui.colors.applying, ui.segments)
  draw.outline_circle(pos.x, pos.y, ui.size * 1.6, ui.colors.applying, ui.segments)
end

---@return self
function CooldownState.init()
  return setmetatable({
    inner = { start = time(), duration = config.states.cooldown.duration },
    get_next = function() return ChargingState.init() end,
    get_name = function() return "Cooldown" end
  }, CooldownState)
end

function CooldownState:is_over()
  return time() > self.inner.start + self.inner.duration
end

function CooldownState:draw_ui()
  if config.ui.enable_debug then
    imgui.text_colored(
      string.format("Cooldown: %ds", math.ceil(self.inner.start + self.inner.duration - time())),
      0xffff9999
    )
  end
end

function CooldownState:draw_hud()
  -- short-hands
  local ui = config.ui
  local pos = ui_position

  -- Background
  draw.filled_circle(pos.x, pos.y, ui.size, ui.colors.background, ui.segments)

  -- Border
  draw.outline_circle(pos.x, pos.y, ui.size, ui.colors.cooldown, ui.segments)
  draw.outline_circle(pos.x, pos.y, ui.size * 1.1, ui.colors.cooldown, ui.segments)

  -- Progress indicator
  draw.outline_circle(pos.x, pos.y, ui.size * 1.5, ui.colors.cooldown, ui.segments)
  draw.outline_circle(pos.x, pos.y, ui.size * 1.6, ui.colors.cooldown, ui.segments)
end

-- End of the madness

local state_manager = StateManager.new(ChargingState)

local function init(args)
  if args[2] then
    player = mdk.QuestPlayer.new(args[2])
  end

  state_manager = StateManager.new(ChargingState)

  local lobby_manager = mdk.LobbyManager.new()
  is_online = lobby_manager:is_quest_online()

  init_weapon()
  init_player_bhvt()
end

---@param dmg_info DamageInfo
local function on_stock_damage(dmg_info)
  --Filter so we only handle shells...
  local attacker_type = dmg_info:get_attacker_type();
  if attacker_type ~= mdk.DamageAttackerType.types.invalid then return end
  --...exclusively during the applying state when there are hits to apply
  local state = state_manager:as(ApplyingState)
  if not state or #state.inner.hits == 0 then return end

  dmg_info:set_physical_damage(state.inner.hits[state.inner.done].physical)
  dmg_info:set_elemental_damage(state.inner.hits[state.inner.done].elemental)
end

---@param dmg_info DamageInfo
---@param hit_info HitInfo
local function on_after_calc_damage_side(dmg_info, hit_info)
  local attacker_id = dmg_info:get_attacker_id()
  if not player or player:get_index() ~= attacker_id then return end

  local attacker_type = dmg_info:get_attacker_type();
  if attacker_type ~= mdk.DamageAttackerType.types.player_weapon then return end

  local physical_damage = dmg_info:get_physical_damage()
  local elemental_damage = dmg_info:get_elemental_damage()

  if state_manager:is(ChargingState) then
    local state = state_manager.state --[[@as ChargingState]]
    if not long_sword or long_sword:get_gauge_level() < 3 then
      state.inner.current = 0
    else
      state.inner.current = math.min(state.inner.required, state.inner.current + physical_damage + elemental_damage)
    end
  elseif state_manager:is(ActiveState) then
    local state = state_manager.state --[[@as ActiveState]]
    local hits = state.inner.hits
    hits[#hits + 1] = {
      timing = time() - state.inner.start,
      physical = physical_damage,
      elemental = elemental_damage,
      pos = hit_info:get_detailed_position()
    }
  end
end

local function main()
  attach_hook(hooks.player.start, init)

  attach_hook(hooks.enemy.stock_damage, function(args)
    if is_online or state_manager:is(CooldownState) then return end
    on_stock_damage(mdk.DamageInfo.new(args[3]))
  end)

  attach_hook(hooks.enemy.after_damage_calc, function(args)
    if is_online or state_manager:is(CooldownState) then return end
    on_after_calc_damage_side(mdk.DamageInfo.new(args[3]), mdk.HitInfo.new(args[4]))
  end)

  attach_hook(hooks.player.update, function(args)
    _time_cache = nil
    if is_online then return end

    if not player_bhvt then
      init_player_bhvt()
    end

    if not long_sword then
      init_weapon()
    end

    local cur_player = mdk.QuestPlayer.new(args[2])
    if not mdk.LobbyManager.is_own_player(cur_player) then
      return
    end
    if player == nil then
      player = cur_player
    end

    state_manager:update()
    if time_scale_transition then
      set_time_scale(time_scale_transition:get(time()))
      if time_scale_transition:is_done(time()) then
        time_scale_transition = nil
      end
    end
    if player_speed_transition then
      player:set_animation_speed(player_speed_transition:get(time()))
      if player_speed_transition:is_done(time()) then
        player_speed_transition = nil
      end
    end

    if state_manager:is(ChargingState) then
      local state = state_manager.state --[[@as ChargingState]]
      if not long_sword or long_sword:get_gauge_level() < 3 then
        state.inner.current = 0
        state.inner.maxed_at = nil
      end
    end

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
        local pos = hit.pos.pos
        if hit.pos.joint ~= nil then
          pos = hit.pos.joint:local_to_world(pos)
        end
        player:create_damaging_shell(pos)
      end
    end
  end)

  attach_hook(hooks.player.motion_control.late_update, function(args)
    local motion_control = mdk.game.MotionControl.new(args[2])
    if not motion_control then return end

    local bid = motion_control:get_old_bank_id()
    local mid = motion_control:get_old_motion_id()

    if state_manager:is(ChargingState)
        and bid == mdk.motions.motion_bank_ids.drawn
        and mid == mdk.motions.motions_ids.ls.special_sheathe_iai_spirit_slash
        and player_bhvt and player_bhvt:call("getCurrentNodeID(System.UInt32)", nil) == 2004603551 -- Iai success
    then
      local state = state_manager.state --[[@as ChargingState]]
      state.inner.iai = true
    elseif state_manager:is(ActiveState)
        and bid ~= mdk.motions.motion_bank_ids.drawn
    then
      set_time_scale(1.0)
      state_manager:to_next()
    end
  end)

  attach_hook(hooks.player.update_hit_stop, function(args)
    if state_manager:is(ActiveState) then
      sdk.to_managed_object(args[2]):call("resetHitStop")
    end
  end)

  local function draw_hud()
    if not long_sword
        or time_scale_manager:call("get_Pausing")
        or gui_manager:call("IsStartMenuAndSubmenuOpen")
        or gui_manager:get_field("InvisibleAllGUI")
        or not gui_manager:call("isOpenHudSharpness")
    then
      return
    end

    if not screen_size then
      get_screen_size()
    end

    state_manager.state:draw_hud()
  end

  re.on_frame(function()
    draw_hud()
  end)

  re.on_draw_ui(function()
    if imgui.tree_node("DMC Vergil") then
      _, config.ui.enable_debug = imgui.checkbox("Enable debug", config.ui.enable_debug)
      if imgui.button("Reset timescale") then
        set_time_scale(1.0)
      end

      local success, data = pcall(state_manager.state.draw_ui, state_manager.state)
      if not success then
        local error_message = string.format("Failed to render menu: %s", tostring(data))
        imgui.text(error_message)
        log.error(error_message)
      end

      imgui.tree_pop()
    end
  end)
end

main()
