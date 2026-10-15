-- Helpers shared by the unit prototype files.
local common = {}

common.TAG = "[rts-units] data: "

-- AI settings for player-like RTS units. The vanilla gleba settings enable
-- destroy_when_commands_fail and allow_try_return_to_spawner, both wrong for RTS units.
common.RTS_AI = {
  destroy_when_commands_fail = false,
  allow_try_return_to_spawner = false,
  do_separation = true,
  join_attacks = false, -- never get pulled into engine-made attack groups
  path_resolution_modifier = 0,
  size_in_group = 1,
}

function common.merge(a, b)
  local r = table.deepcopy(a)
  for k, v in pairs(b or {}) do r[k] = table.deepcopy(v) end
  return r
end

local function file_of(t)
  if type(t.filename) == "string" then return t.filename end
  if type(t.filenames) == "table" and type(t.filenames[1]) == "string" then return t.filenames[1] end
  return nil
end

-- Re-tint every sprite layer whose file name contains "mask".
-- color == nil: switch the layer to the runtime tint (apply_runtime_tint = true), which is
-- the force color for spider-units (changelog 2.0.63). color ~= nil: hard-code that tint.
-- Returns the number of layers changed.
function common.tint_masks(t, color)
  if type(t) ~= "table" then return 0 end
  local n = 0
  local file = file_of(t)
  if file and file:find("mask", 1, true) then
    if color then
      t.tint = color
      t.apply_runtime_tint = nil
    else
      t.apply_runtime_tint = true
      t.tint = nil
      t.tint_as_overlay = nil
    end
    n = n + 1
  end
  for _, v in pairs(t) do
    if type(v) == "table" then n = n + common.tint_masks(v, color) end
  end
  return n
end

-- Strip trigger effects that spawn wrigglers or apply stickers; optionally override damage amounts.
function common.clean_effects(t, damage)
  if type(t) ~= "table" then return end
  for _, key in pairs({"target_effects", "source_effects"}) do
    local eff = t[key]
    if type(eff) == "table" then
      if eff.type then eff = {eff}; t[key] = eff end
      for i = #eff, 1, -1 do
        local e = eff[i]
        if (e.type == "create-entity" and tostring(e.entity_name):find("wriggler", 1, true))
          or e.type == "create-sticker" then
          table.remove(eff, i)
        elseif e.type == "damage" and damage then
          e.damage.amount = damage
        end
      end
    end
  end
  for _, v in pairs(t) do
    if type(v) == "table" then common.clean_effects(v, damage) end
  end
end

-- Hitscan ranged attack built from base-game effects only (no Space Age assets).
function common.hitscan_attack(range, cooldown, damage, damage_type)
  return {
    type = "projectile",
    ammo_category = "bullet",
    cooldown = cooldown,
    range = range,
    ammo_type = {
      action = {
        type = "direct",
        action_delivery = {
          type = "instant",
          source_effects = {{type = "create-explosion", entity_name = "explosion-gunshot"}},
          target_effects = {
            {type = "create-entity", entity_name = "explosion-hit", offsets = {{0, 1}},
             offset_deviation = {{-0.5, -0.5}, {0.5, 0.5}}},
            {type = "damage", damage = {amount = damage, type = damage_type}},
          },
        },
      },
    },
  }
end

return common
