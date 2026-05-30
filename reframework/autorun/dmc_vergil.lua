---This mod code is entirely too complex and long for what it does, but I wanted to experiment setting
---up a simple state machine in preparation for future, more complex move addition mods.
---My apologies if you're reading this to learn how to mod.

local function dump(o)
  if type(o) == 'table' then
    local s = '{ '
    for k, v in pairs(o) do
      if type(k) ~= 'number' then k = '"' .. k .. '"' end
      s = s .. '[' .. k .. '] = ' .. dump(v) .. ',\n'
    end
    return s .. '}\n'
  else
    return tostring(o)
  end
end

---@param play_object PlayObjectRemo
---@diagnostic disable-next-line: unused-function
local function dump_ui(play_object, seen)
  seen = seen or {}
  seen[play_object:get_address()] = true
  local current = play_object
  while current do
    current = current:call("get_Next")
  end
end

local ui = {
  enable_debug = true,
  x = 0,
  y = 0,
  width = nil,
  height = nil,
  size = 20,
  segments = 6,
  primary_color = 0xffffffff,
  secondary_color = 0xffffff88,
  background_color = 0x77888888,
  applying_color = 0xff8888ff,
  cooldown_color = 0xff888888,
}

local show_debug = true
local debug = ""

local mdk = require("mdk.prelude")
local attach_hook = mdk.attach_hook
local hooks = mdk.hooks

local StateManager = require("mdk.utils.StateManager")

local config = {
  charge_required = 500,
  active_duration = 20,
  active_timescale = 0.2,
  active_player_speedup = 1.5,
  applying_speedup = 1 / 0.2,
  cooldown_duration = 5,
}

---@type QuestPlayer?
local player = nil

---@type BehaviorTree | nil
local player_bhvt = nil

---@type REManagedObject?
local long_sword = nil

---@class SavedHit
---@field timing number
---@field physical number
---@field elemental number
---@field pos { pos: Vector3f, joint: Joint|nil }

---@param hit SavedHit
---@return string
local function saved_hit_to_string(hit)
  return string.format(
    "%.0fms | %.0fp %.0fe | { pos: %s, joint: %s }",
    hit.timing * 1000, hit.physical, hit.elemental,
    tostring(hit.pos.pos), hit.pos.joint
  )
end

local function init_player_bhvt()
  if not player then return end
  local mp_obj = player._remo:call("get_GameObject")
  player_bhvt = mp_obj:call("getComponent(System.Type)", sdk.typeof("via.behaviortree.BehaviorTree"))
end

local function init_weapon()
  if not player then return end
  long_sword = player._remo
      :call("get_GameObject")
      :call("getComponent(System.Type)", sdk.typeof("snow.player.LongSword")) --[[@as REManagedObject?]]
  if not long_sword then return end

  if long_sword:get_field("_LongSwordGaugeLv") == 3 then

  end
end

local function get_screen_size()
  local sceneman = sdk.get_native_singleton("via.SceneManager")
  if not sceneman then
    return
  end

  local sceneview = sdk.call_native_func(sceneman, sdk.find_type_definition("via.SceneManager"), "get_MainView")
  if not sceneview then
    return
  end

  local size = sceneview:call("get_Size")
  if not size then
    return
  end

  ui.width = size:get_field("w")
  ui.height = size:get_field("h")

  ui.x = ui.width * (427 / 2560)
  ui.y = ui.height * (230 / 1440)
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
      required = config.charge_required,
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
  if ui.enable_debug then
    local charge = self.inner.current / self.inner.required
    imgui.progress_bar(charge, Vector2f.new(400, 40), string.format("Charge: %d%%", math.floor(100 * charge)))
    _, ui.segments = imgui.drag_int("ui.segments", ui.segments, 0.1, 3, 12)
  end
end

function ChargingState:draw_hud()
  local charge = self.inner.current / self.inner.required

  local primary_color = ui.primary_color
  local secondary_color = ui.secondary_color
  if charge >= 1 then
    primary_color = secondary_color
    secondary_color = secondary_color + 0x33 * math.abs(math.sin(3 * time()))
  end

  -- Background
  draw.filled_circle(ui.x, ui.y, ui.size, 0x77888888, ui.segments)

  -- Border
  draw.outline_circle(ui.x, ui.y, ui.size, primary_color, ui.segments)
  draw.outline_circle(ui.x, ui.y, ui.size * 1.1, primary_color, ui.segments)

  -- Progress indicator
  draw.outline_circle(ui.x, ui.y, ui.size * (1 + .5 * charge), primary_color, ui.segments)
  draw.outline_circle(ui.x, ui.y, ui.size * (1 + .6 * charge), primary_color, ui.segments)
  draw.filled_circle(ui.x, ui.y, charge * ui.size, secondary_color, ui.segments)

  if self.inner.maxed_at and time() < self.inner.maxed_at + 1 then
    local t = (time() - self.inner.maxed_at) / 2;
    local alpha = math.floor((1 - t) * 0xff) << 24
    draw.outline_circle(ui.x, ui.y, ui.size + ui.height * t, alpha + (ui.secondary_color & 0x00ffffff), ui.segments)
  end
end

---@return self
function ActiveState.init()
  if player ~= nil then
    set_player_speed_target(config.active_player_speedup / config.active_timescale, 1.)
    set_time_scale_target(config.active_timescale, 1.)
  end
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
  if ui.enable_debug then
    imgui.text("Hits:")
    imgui.same_line()
    imgui.text_colored(tostring(#self.inner.hits), 0xff9999ff)
    local charge = 1 - (time() - self.inner.start) / self.inner.duration
    imgui.progress_bar(charge, Vector2f.new(400, 40), string.format("Charge: %d%% ⬇", math.floor(100 * charge)))
  end
end

function ActiveState:draw_hud()
  local charge = 1 - (time() - self.inner.start) / self.inner.duration

  -- Background
  draw.filled_circle(ui.x, ui.y, ui.size, 0x77888888, ui.segments)

  -- Border
  draw.outline_circle(ui.x, ui.y, ui.size, ui.secondary_color, ui.segments)
  draw.outline_circle(ui.x, ui.y, ui.size * 1.1, ui.secondary_color, ui.segments)

  -- Progress indicator
  draw.outline_circle(ui.x, ui.y, ui.size * (1 + .5 * charge), ui.secondary_color, ui.segments)
  draw.outline_circle(ui.x, ui.y, ui.size * (1 + .6 * charge), ui.secondary_color, ui.segments)
  draw.filled_circle(ui.x, ui.y, charge * ui.size, ui.secondary_color, ui.segments)
end

---@return self
function ApplyingState.init()
  if player ~= nil then
    set_player_speed_target(1., 1.)
    set_time_scale_target(1., 1.)
  end
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
  if ui.enable_debug then
    imgui.text("Hits:")
    imgui.same_line()
    imgui.text_colored(string.format("%d / %d", self.inner.done, #self.inner.hits), 0xff9999ff)
  end
end

function ApplyingState:draw_hud()
  -- Background
  draw.filled_circle(ui.x, ui.y, ui.size, ui.background_color, ui.segments)

  -- Border
  draw.outline_circle(ui.x, ui.y, ui.size, ui.applying_color, ui.segments)
  draw.outline_circle(ui.x, ui.y, ui.size * 1.1, ui.applying_color, ui.segments)

  -- Progress indicator
  draw.outline_circle(ui.x, ui.y, ui.size * 1.5, ui.applying_color, ui.segments)
  draw.outline_circle(ui.x, ui.y, ui.size * 1.6, ui.applying_color, ui.segments)
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
  if ui.enable_debug then
    imgui.text_colored(
      string.format("Cooldown: %ds", math.ceil(self.inner.start + self.inner.duration - time())),
      0xffff9999
    )
  end
end

function CooldownState:draw_hud()
  -- Background
  draw.filled_circle(ui.x, ui.y, ui.size, ui.background_color, ui.segments)

  -- Border
  draw.outline_circle(ui.x, ui.y, ui.size, ui.cooldown_color, ui.segments)
  draw.outline_circle(ui.x, ui.y, ui.size * 1.1, ui.cooldown_color, ui.segments)

  -- Progress indicator
  draw.outline_circle(ui.x, ui.y, ui.size * 1.5, ui.cooldown_color, ui.segments)
  draw.outline_circle(ui.x, ui.y, ui.size * 1.6, ui.cooldown_color, ui.segments)
end

-- End of the madness

local state_manager = StateManager.new(ChargingState)

---Debug info storing latest player BHVT nodes
local node_stack = {}

---Disable the mod in multiplayer
local is_online = false


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

local latest_attack = { id = 0, type = "unknown" }

---@param dmg_info DamageInfo
---@param hit_info HitInfo
local function on_after_calc_damage_side(dmg_info, hit_info)
  local attacker_id = dmg_info:get_attacker_id()
  if not player or player:get_index() ~= attacker_id then return end

  local attacker_type = dmg_info:get_attacker_type();
  if attacker_type ~= mdk.DamageAttackerType.types.player_weapon then return end

  latest_attack = {
    id = attacker_id,
    type = tostring(mdk.DamageAttackerType.name_from_id(attacker_type) or tostring(attacker_type))
  }

  local physical_damage = dmg_info:get_physical_damage()
  local elemental_damage = dmg_info:get_elemental_damage()

  if state_manager:is(ChargingState) then
    local state = state_manager.state --[[@as ChargingState]]
    if not long_sword or long_sword:get_field("_LongSwordGaugeLv") < 3 then
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

local tbl = nil
local tbl_time = 0
local _cache = nil

local function main()
  attach_hook(hooks.player.start, init)

  attach_hook(hooks.enemy.stock_damage, function(args)
    if is_online or state_manager:is(CooldownState) then return end
    on_stock_damage(mdk.DamageInfo.new(args[3]))
  end)

  attach_hook(hooks.enemy.after_damage_calc, function(args)
    if is_online or state_manager:is(CooldownState) then return end
    -- if (not tbl or time() > tbl_time + 1) and args then
    --   _cache = nil
    --   tbl = args
    --   tbl_time = time()
    -- end
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
    elseif player == nil then
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
      player._remo
          :call("get_MotLayer0Speed")
          :call("setSpeed", 0, player_speed_transition:get(time()))
      if player_speed_transition:is_done(time()) then
        player_speed_transition = nil
      end
    end

    if state_manager:is(ChargingState) then
      local state = state_manager.state --[[@as ChargingState]]
      if not long_sword or long_sword:get_field("_LongSwordGaugeLv") < 3 then
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

    if bid == mdk.motions.motion_bank_ids.drawn then
      last_motion_id = mid
    end
  end)

  attach_hook(hooks.player.update_hit_stop, function(args)
    if state_manager:is(ActiveState) then
      sdk.to_managed_object(args[2]):call("resetHitStop")
    end
  end)

  local colors = { o = {}, i = {} }

  local function draw_hud()
    if not long_sword then return end
    -- local level = long_sword:get_field("_LongSwordGaugeLv")
    -- if level < 3 then
    --   long_sword:set_field("_LongSwordGaugeLv", 3)
    -- end

    if not ui.width or not ui.height then
      get_screen_size()
    end

    state_manager.state:draw_hud()

    local state = state_manager:as(ChargingState) --[[@as ChargingState | nil]]
    if not state then return end

    local gui_manager = mdk.game.gui.GuiManager.new()
    local weapon_hud_object = mdk.game.GameObject.new(gui_manager:get_weapon_hud()) --[[@as GameObject]]
    local weapon_hud_type = mdk.game.gui.WeaponHud[1].long_sword;
    local weapon_hud = mdk.game.gui.weapon_huds.LongSwordHud.new(weapon_hud_object:get_component(weapon_hud_type)._remo)

    --[[
    via.gui.Rect
    via.Color
    via.gui.ColorType
    via.gui.ColorPreset
    --]]
    colors.debug = "Failed"
    local panel = weapon_hud:get_main_panel()._remo
    colors.ty = panel:get_type_definition()
    local inner = panel:get_field("pnl_OutsideGauge")
    if inner then
      colors.debug = "Inner found"
      local rect = inner:get_field("rect_OutsideGaugeMask")
      if rect then
        colors.debug = "Rect found"
        colors.debug = rect:call("get_Color"):call("ToString")
      end
    end
    -- colors.debug = weapon_hud._remo:get_type_definition():get_full_name()
    -- colors.tbl = mdk.game.gui.weapon_huds.LongSwordHud.new(weapon_hud._remo)
    local out_panel = weapon_hud._remo:get_field("_Ls_OutGaugePanel")
    colors.panel = out_panel --[[@as REManagedObject]]
    -- local out_rect = weapon_hud._remo:get_field("_Ls_OutGaugeRect")
    -- local out_color = out_rect:call("get_Color")
    -- local mix = math.max(1., mdk.utils.Transition.curves.smoothstep(state.inner.current / state.inner.required))
    -- colors.o.main = out_color:call("ToString")
    -- colors.o.left = out_rect:call("get_ColorLeft"):call("ToString")
    -- colors.o.right = out_rect:call("get_ColorRight"):call("ToString")
    -- colors.o.top = out_rect:call("get_ColorTop"):call("ToString")
    -- colors.o.bottom = out_rect:call("get_ColorBottom"):call("ToString")
    -- out_color:call("set_b", mix)
    --
    -- if state.inner.current == state.inner.required then
    --   local in_rect = weapon_hud._remo:get_field("_Ls_IngaugeRect")
    --   local in_color = in_rect:call("get_Color")
    --   colors.i.main = in_color:call("ToString")
    --   colors.i.left = out_rect:call("get_ColorLeft"):call("ToString")
    --   colors.i.right = out_rect:call("get_ColorRight"):call("ToString")
    --   colors.i.top = out_rect:call("get_ColorTop"):call("ToString")
    --   colors.i.bottom = out_rect:call("get_ColorBottom"):call("ToString")
    --   in_color:call("set_b", 0xff)
    -- end
  end

  re.on_frame(function()
    draw_hud()
  end)

  re.on_draw_ui(function()
    if imgui.tree_node("DMC Vergil") then
      if imgui.button("Reset timescale") then
        set_time_scale(1.0)
      end
      imgui.text(string.format("State: %s", state_manager.state:get_name()))

      local success, data = pcall(state_manager.state.draw_ui, state_manager.state)
      if not success then
        local error_message = string.format("Failed to render menu: %s", tostring(data))
        imgui.text(error_message)
        log.error(error_message)
      end

      imgui.separator()

      imgui.text(string.format("latest_attack: { id = %d, type = %s }", latest_attack.id, latest_attack.type))
      imgui.text(string.format("time_scale: %s", tostring(scene:call("get_TimeScale"))))
      if player then
        local mot_layer = player._remo:call("get_MotLayer0Speed")
        if mot_layer then
          imgui.text(string.format("player_speed: %s", tostring(mot_layer:call("getSpeed", 0))))
        end
      end

      imgui.separator()

      imgui.text(string.format("LongSword : %s", tostring(long_sword)))
      if long_sword then
        imgui.text(string.format("LongSword GameObject Type : %s",
          long_sword:get_type_definition():get_full_name()))

        local gauge_level = long_sword:get_field("_LongSwordGaugeLv")
        imgui.text(string.format("Gauge level : %s", tostring(gauge_level)))

        imgui.separator()

        imgui.text("PANEL")
        --[[
        via.gui.Panel
        via.gui.TransformObject
        via.gui.PlayObject
        --]]
        local rect = mdk.game.gui.Rect.new(colors.panel:get_Child())
        imgui.text(string.format("main : %s", rect._remo:call("get_Color"):call("ToString")))

        imgui.text(string.format("typeof weapon_hud : %s", colors.debug))
        imgui.text(string.format("ty : %s (%s)", colors.ty, colors.ty:get_full_name()))
        imgui.text(tostring(#colors.ty:get_fields()))
        for i, v in ipairs(colors.ty:get_fields()) do
          imgui.text(string.format("\t%s : %s", tostring(i), v:get_name()))
        end
        -- imgui.text(string.format("fn : %s", colors.tbl.get_main_panel))
        -- imgui.text(string.format("tbl : %s", colors.tbl))
        -- imgui.text(dump(getmetatable(colors.tbl)))

        imgui.text(string.format("name : %s", rect._remo:get_type_definition():get_full_name()))
        imgui.text("OUTSIDE")
        for name, str in pairs(colors.o) do
          imgui.text(string.format("%s : %s", name, str))
        end
        imgui.text("INSIDE")
        for name, str in pairs(colors.i) do
          imgui.text(string.format("%s : %s", name, str))
        end
      end

      imgui.separator()

      if imgui.tree_node("BHVT") then
        if not player_bhvt then
          imgui.text("player_bhvt not initialized")
        else
          local id = player_bhvt:call("getCurrentNodeID(System.UInt32)", nil)
          local name = player_bhvt:call("getCurrentNodeName(System.UInt32)", nil)

          if #node_stack == 0 or id ~= node_stack[#node_stack][1] then
            node_stack[#node_stack + 1] = { id, name }
          end

          for i = #node_stack, (math.max(1, #node_stack - 10)), -1 do
            local entry = node_stack[i]
            imgui.text(string.format("%s : %s", tostring(entry[1]), entry[2]))
          end
        end
        imgui.tree_pop()
      end

      imgui.separator()

      if tbl and imgui.tree_node("TBL") then
        local name = 2
        local value = tbl[name]
        if value or _cache then
          local ty = type(value)
          if not _cache and ty == "userdata" and sdk.is_managed_object(value) then
            _cache = string.format("%s : %s -> %s", tostring(name), ty,
              sdk.to_managed_object(value):get_type_definition():get_full_name())
          elseif not _cache then
            _cache = string.format("%s : %s", tostring(name), ty)
          end
          imgui.text(_cache)
        else
          imgui.text("wait")
        end
        -- for name, value in pairs(tbl) do
        --   local ty = type(value)
        --   if ty == "userdata" and sdk.is_managed_object(value) then
        --     imgui.text(string.format("%s : %s -> %s", tostring(name), ty,
        --       sdk.to_managed_object(value):get_type_definition():get_full_name()))
        --   else
        --     imgui.text(string.format("%s : %s", tostring(name), ty))
        --   end
        -- end
        imgui.tree_pop()
      end

      if show_debug and #debug > 0 then
        imgui.text(string.format("debug: %s", debug))
        -- debug = ""
      end

      imgui.tree_pop()
    end
  end)
end

main()
