-- 0.1.2 (issue #26): reads the result of scripts/netwait.lua (storage.netwait) for the panels. No dependencies, so the
-- hub panel (loaded before the cities) can require it. See scripts/netwait.lua for the contract.
local netwaitline = {}

--- The waiting record of a hub / City Center ({n, items}), or nil when nothing waits.
function netwaitline.get(unit_number)
  local r = storage.netwait and storage.netwait[unit_number]
  if r and r.n > 0 then return r end
  return nil
end

--- A localised "N ghosts waiting: ... missing in this network" line for the record, or nil.
function netwaitline.line(unit_number)
  local r = netwaitline.get(unit_number)
  if not r then return nil end
  local names = {}
  for item in pairs(r.items) do names[#names + 1] = item end
  table.sort(names)
  local icons = {}
  for i = 1, math.min(#names, 4) do icons[#icons + 1] = "[item=" .. names[i] .. "]" end
  return {"rts-ux.waiting-line", r.n, table.concat(icons, " ")}
end

return netwaitline
