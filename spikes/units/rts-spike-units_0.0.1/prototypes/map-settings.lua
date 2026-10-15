-- Default map settings for NEW maps. Existing saves keep their own copy (use game.map_settings at runtime).
local TAG = "[rts-units] data: "
local ms = data.raw["map-settings"]["map-settings"]

local function set(path, value)
  local t = ms
  for i = 1, #path - 1 do t = t[path[i]] end
  local key = path[#path]
  local old = t[key]
  t[key] = value
  log(TAG .. "map-settings." .. table.concat(path, ".") .. ": " .. tostring(old) .. " -> " .. tostring(value))
end

-- Units whose behavior keeps failing are destroyed after this many failures. Default 3.
set({"max_failed_behavior_count"}, 1000000)
-- Keep the vanilla enemy force from expanding / evolving during tests (the RTS has its own AI).
set({"enemy_expansion", "enabled"}, false)
set({"enemy_evolution", "enabled"}, false)
