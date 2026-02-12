local mdk = require("mdk.prelude")
local attach_hook = mdk.attach_hook
local hooks = mdk.hooks

---@class SavedHit
---@field physical number
---@field elemental number
---@field pos { pos: Vector3f, joint: unknown|nil }

---@type SavedHit[]
local hits = {}

local charge = 0
local required_charge = 1000
local is_active = false

local is_online = false

local function main()
  attach_hook(hooks.player.init, function()
    hits = {}
    charge = 0
    is_active = false
    -- local lobby_manager = mdk.LobbyManager.new()
    -- is_online = mdk.LobbyManager:is_quest_online()
    is_online = false
  end)

  attach_hook(hooks.enemy.stockDamage, function(args)
    if is_online then return end

    local monster = mdk.Monster.new(args[2])
    local hitInfo = mdk.HitInfo.new(args[3])
    local physicalDamage = hitInfo:get_physical_damage()
    local elementalDamage = hitInfo:get_elemental_damage()

    if is_active then
      hits[#hits + 1] = {
        physical = physicalDamage,
        elemental = elementalDamage,
        pos = hitInfo:get_detailed_position()
      }
    else
      charge = math.min(required_charge, charge + physicalDamage + elementalDamage)
    end
  end)

  attach_hook(hooks.player.update, function(args)
    if is_online then return end

    local player = mdk.QuestPlayer.new(args[2])
    if not mdk.utils.is_own_player(player) then
      return
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
