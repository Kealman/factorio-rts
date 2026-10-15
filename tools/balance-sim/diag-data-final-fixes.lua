-- Diagnostic only: count shots (source effect) and impacts (projectile / instant target effect) of rts units.
local function add(list_owner, key, eff)
  local l = list_owner[key]
  if l == nil then list_owner[key] = {eff} return end
  if l.type then list_owner[key] = {l, eff} return end
  l[#l + 1] = eff
end
for _, t in pairs({"spider-unit", "unit"}) do
  for name, u in pairs(data.raw[t]) do
    if name:find("^rts%-") then
      local ap = u.attack_parameters
      local action = ap.ammo_type and ap.ammo_type.action
      local first = action and (action.type and action or action[1])
      local d = first and first.action_delivery
      if d then
        if d.type == "stream" or d.type == "projectile" or d.type == "instant" then
          add(d, "source_effects", {type = "script", effect_id = "shot:" .. name})
        end
        if d.type == "instant" then add(d, "target_effects", {type = "script", effect_id = "impact:" .. name}) end
        if d.type == "projectile" and data.raw.projectile[d.projectile] then
          local p = data.raw.projectile[d.projectile]
          local pa = p.action.type and p.action or p.action[1]
          add(pa.action_delivery, "target_effects", {type = "script", effect_id = "impact:" .. name})
        end
      end
    end
  end
end
