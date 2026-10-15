-- RTS-paced camera panning (docs/qa/phase1-followups.md item 1). The first interactive QA measured about
-- 170 tiles per second of WASD hold at zoom 0.5 with the vanilla remote controller (movement_speed = 1,
-- data/core/prototypes/remote-controller.lua). RemoteControllerPrototype.movement_speed "Must be >= 0.34375"
-- (prototype docs 2.0.77), so a quarter of vanilla (0.25) is not allowed: the minimum is used, about a third.
local controller = data.raw["remote-controller"] and data.raw["remote-controller"]["default"]
if controller then
  local before = controller.movement_speed
  controller.movement_speed = 0.34375
  log(string.format("[rts] controller: remote-controller movement_speed %s -> %s", tostring(before),
    tostring(controller.movement_speed)))
end
