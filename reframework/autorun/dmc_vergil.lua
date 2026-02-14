local mdk = require("mdk.prelude")
local attach_hook = mdk.attach_hook
local hooks = mdk.hooks

---@class SavedHit
---@field physical number
---@field elemental number
---@field pos { pos: Vector3f, joint: unknown|nil }

---@type SavedHit[]
local hits = {}

---@enum states
local states = { charging = 1, active = 2, applying = 3, cooldown = 4 }

---@type states
local state = states.charging

---@type integer Current charge
local charge = 0
---@type integer Charge needed for activation
local required_charge = 1000

---@type integer Cooldown time in seconds
local cooldown_time = 5
---@type integer Skill active time in seconds
local active_time = 10

---@type integer Starting timestamp of the current state
local state_start = 0
---@type integer The duration of the current state
local state_duration = 0

---@type boolean Disable the mod in multiplayer, I'm not dealing with that
local is_online = false

---@type integer|nil Time cache invalidated every update cycle
local _time_cache = nil
---@return integer
local function time()
  return _time_cache or os.time()
end

---@return boolean
local function is_active()
  return active_start < time() and time() < active_start + active_time
end

---@return boolean
local function is_on_cooldown()
  return cooldown_start < time() and time() < cooldown_start + cooldown_time
end

local function init()
  state = states.charging
  hits = {}
  charge = 0
  cooldown_start = 0
  active_start = 0

  local lobby_manager = mdk.LobbyManager.new()
  is_online = lobby_manager:is_quest_online()
end

---@param hitInfo HitInfo
local function onStockDamage(hitInfo)
  local physical_damage = hitInfo:get_physical_damage()
  local elemental_damage = hitInfo:get_elemental_damage()

  if state == states.active then
    hits[#hits + 1] = {
      physical = physical_damage,
      elemental = elemental_damage,
      pos = hitInfo:get_detailed_position()
    }
  else
    charge = math.min(required_charge, charge + physical_damage + elemental_damage)
  end
end

local function main()
  attach_hook(hooks.player.start, init)

  attach_hook(hooks.enemy.stockDamage, function(args)
    if is_online then return end

    if is_on_cooldown() then
      return
    else
      state = states.charging
    end

    onStockDamage(mdk.HitInfo.new(args[3]))
  end)

  attach_hook(hooks.player.update, function(args)
    if is_online then return end

    local player = mdk.QuestPlayer.new(args[2])
    if not mdk.utils.is_own_player(player) then
      return
    end

    if is_active() then
      -- Purely for visual reasons
      charge = math.max(0, charge - required_charge / active_time)
    else
      if state == states.active then
        state = states.applying
        charge = 0
      end
    end
  end)
end

re.on_draw_ui(function()
  if imgui.tree_node("DMC Vergil") then
    imgui.text(string.format("Hit count: %d", #hits))
    imgui.progress_bar(charge / required_charge, Vector2f.new(500, 50),
      string.format("Charge: %d / %d", charge, required_charge))
    imgui.tree_pop()
  end
end)

main()
