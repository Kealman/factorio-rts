# Factorio camera/input human test — 2026-10-15

Tested the already-running **Factorio: Space Age 2.0.77** on this Mac using Computer Use mouse/keyboard actions only. No game process was launched, restarted, quit, or killed, and no Factorio commands were run. The protocol was read in full; its Setup section was not executed. The display-name lookup failed, but bundle ID `com.factorio` worked immediately, without an approval denial. The existing window was raised.

The initial view was remote, zoom 0.133, centered at {45.04,18.81}, not over the units. Preparatory scrolling and WASD panning brought the units into view at zoom 1.000. Low-zoom panning initially overshot and was corrected. This run's first protocol input is **856.702 / tick 49549**; earlier entries in the appended log belong to setup, self-tests, and previous interactions. Steps 2–20 were visited in order, with limitations recorded rather than inferred passes. One supplemental Shift+left-click followed step 20 at 1351.753.

After every numbered step, the requested `grep ... | grep -v STATUS | grep -v HEARTBEAT | tail -8` command was run. Additional log reads disambiguated compound steps and zoom changes. Screenshots were captured and inspected after steps 2, 6, 11, and 14 in the Computer Use session; these are visual observations, not newly saved screenshot artifacts.

| Step | What I did | Expected log evidence present / absent | Result and observations |
| --- | --- | --- | --- |
| 1 | Already covered, as instructed; no new 60-second wait. | Existing SELFTEST done at 81.569 says controller=remote character=false; this run's initial STATUS also confirms remote/character=false. | Not rerun. Earlier self-test and manual controller changes remain in the full log. |
| 2 | Left-dragged (650,260) to (1060,670) around the visible biters and car. | 856.702 INPUT rts-lclick cursor_position={0.27, 8.18}; 856.705 SELECT on_player_selected_area entities=9, including small-biters and car, controller=remote. | PASS. Required screenshot inspected after release. Cursor remained available. |
| 3 | Left-dragged empty ground (510,520) to (640,640). | 869.369 INPUT rts-lclick; SELECT on_player_selected_area entities=0, area 4.06x3.75. | PASS: empty selections fire. |
| 4 | Attempted to hold Shift during a left-drag over biters. | No on_player_alt_selected_area from this attempt. 902.203 ordinary INPUT rts-lclick and on_player_selected_area entities=3 instead. | BLOCKED gesture: Computer Use rejected modifier-only Shift_L with keyPressIncludedNoNonModifierKeys; its drag API has no modifier parameter. After step 20, a separately labeled Shift+left-click check at 1351.753 DID fire on_player_alt_selected_area, entities=0, area 0.00x0.00. This does not validate Shift-drag over units. |
| 5 | Right-clicked empty ground at (550,550), without dragging. | 924.119 INPUT rts-rclick cursor_position={-2.86, 17.24}; 924.168 SELECT on_player_reverse_selected_area entities=0, area 0.00x0.00. | PASS: a plain right-click fires reverse selection. |
| 6 | Inspected biters and trees; could not perform right-drag. | No new selection line for this step. Tail still ended with step 5 reverse selection. | BLOCKED: documented Computer Use drag accepts only from/to, with no right-button option or separate button-down/move/up APIs. Required screenshot taken and inspected. Multi-entity/tree reverse selection remains untested. |
| 7 | Right-clicked a biter; first attempt missed a wandering unit, then retried beside the car at (699,380). | 950.752/950.802 first attempt: rts-rclick and reverse entities=0. Retry 970.302: INPUT rts-rclick selected_prototype=entity/unit/small-biter cursor_position={1.80, 11.93}; 970.352 reverse selection entities=1 [unit:small-biter@player]. | PASS on retry. HOVER also fired at 970.237 and 970.352. |
| 8 | Could not Shift+right-drag; used supported Shift+right-click on empty ground as a partial event check. | 991.668 SELECT on_player_alt_reverse_selected_area entities=0, area 0.00x0.00. | PARTIAL: alternate reverse event verified, drag rectangle and entity contents not verified. No plain rts-rclick input accompanied this shifted click. |
| 9 | Middle-clicked map ground at (600,550). | 1005.286 INPUT rts-rclick-consuming cursor_position={-1.29, 17.24}, in_gui=false, controller=remote. | PASS. No additional vanilla action visible in the subsequent screenshot; no selection event. |
| 10 | Pressed Ctrl+1, then Cmd+1, then bare 1, checking log between inputs. | 1017.461 and 1028.636 INPUT rts-cg-1 respectively; 1041.035 INPUT rts-recall-1. Bare 1 also caused cursor=empty, successful re-insert, then cursor=rts-cursor. | Both modifiers work. Empty quickbar showed no visible item change, but bare 1 demonstrably cleared the cursor as an additional effect; mod restored it immediately. |
| 11 | Pressed F2, waited at least 3 seconds, closed the opened inventory with Escape, held W for 180 ms, then pressed F2 again. | 1054.952 TOGGLE remote -> god; set_controller{god} ok=true; teleport god to camera position ok=true; give_cursor (after controller change) ok=true. 1084.652 TOGGLE god -> remote and set_controller{remote} ok=true. | PASS with interference: F2 opened inventory in god mode and a cursor-ghost picker on return to remote. W moved camera from {-0.04,13.43} to {-0.04,7.93}; other WASD directions not separately tested. Return to remote visibly zoomed out to 0.133 from 1.000. Required screenshot inspected. Closed picker before step 12. |
| 12 | Pressed M, then Escape. | 1097.619 INPUT rts-linked-toggle-map, old=remote new=god, CONTROLLER CHANGED; 1097.636 reapply/event ok=true. Escape repeated controller change at 1104.753 and reapply at 1104.770. | PASS: both returned to remote on the next tick. No persistent changed view or pause menu in screenshots; transient one-frame flicker cannot be assessed from these snapshots. |
| 13 | Scrolled out to the minimum (repeated input at the limit), then back in to maximum, reading STATUS separately. | Remote chart_zoomed_in at 0.133 before zoom-out; first chart sample 0.099. Minimum reported 0.004. On return, chart last sampled at 0.079, then chart_zoomed_in at 0.133; remained chart_zoomed_in through 3.000. No game sample during this sweep. | Protocol expectation of game mode at close remote zoom was not observed. Transition values are rounded 1 Hz samples, not exact engine thresholds. Pointer-centered scrolling shifted camera position. Full details below. |
| 14 | Left-clicked, then right-clicked custom minimap at (90,335). | 1233.371 GUI_HOVER minimap:rts_minimap; 1233.452 INPUT rts-lclick in_gui=true element=minimap:rts_minimap; 1233.453 GUI_CLICK button=left; 1234.052 rts-rclick in_gui=true and GUI_CLICK button=right. | PASS for both buttons. Required screenshot inspected; no map recentering observed. |
| 15 | Left-clicked and right-clicked custom camera element at (245,335). | 1247.802 GUI_HOVER camera:rts_camera; 1247.869 rts-lclick in_gui=true and GUI_CLICK button=left; 1248.468/1248.469 rts-rclick in_gui=true and GUI_CLICK button=right. | PASS for both buttons. No controller-change line or obvious camera jump. |
| 16 | Clicked Control button at (61,419). | 1264.335 GUI_HOVER button:rts_button; 1264.402 rts-lclick in_gui=true; 1264.452 GUI_CLICK element=button:rts_button button=left. | PASS control case. |
| 17 | Pressed Q while pointer remained over Control button. | 1275.686 INPUT rts-linked-clear-cursor; cursor=empty; give_cursor (re-insert after cursor emptied) set_stack ok=true cursor=rts-cursor; 1275.702 cursor-stack event restored. | PASS. Clearing the tool is immediately reversed by the mod. |
| 18 | Pressed F1. | 1286.219 INPUT rts-give-cursor; give_cursor (F1) clear_cursor ok=true and set_stack ok=true cursor=rts-cursor; 1286.220 cursor-stack event. | PASS. No fn modifier required; tool icon remained visible. |
| 19 | Clicked bottom-right RTS Cursor shortcut at (1027,798). | 1299.735 INPUT rts-lclick in_gui=true selected_prototype=shortcut/shortcut/rts-give-cursor-shortcut; 1299.786 cursor=rts-cursor. No on_lua_shortcut event. | PASS. Screenshot tooltip identifies RTS Cursor (F1), and tool icon is visible. |
| 20 | Zoomed back to a usable 0.630 and inspected the map to locate biters for hover. | No new HOVER at this step. Earlier current-run 970.237 HOVER selected=unit:small-biter at {1.78,12.41} controller=remote and 970.352 at {1.78,12.38} provide positive incidental evidence. | PARTIAL / isolated action not performed: API exposes no move-only/hover operation; biters had wandered out of the inspected map area. Do not count the earlier right-click hover as a separately executed step-20 pass. |

Default zoom limits, verbatim:

```text
  22.904 Script @__rts-spike-camera__/control.lua:31: [rts-camera] default zoom_limits (controller=remote): {closest = {zoom = 3}, furthest = {zoom = 0.00390625}, furthest_game_view = {distance = 200, max_distance = 500}} ; zoom=0.3
```

The existing setup log also says it successfully changed `furthest_game_view` to `{distance = 300, max_distance = 600}`. Thus the observed sweep is not a measurement of the untouched default `{distance = 200, max_distance = 500}`.

Step 13 switched **chart_zoomed_in → chart at first sampled zoom 0.099** (1127.135), after chart_zoomed_in at 0.133. It switched **chart → chart_zoomed_in at first sampled zoom 0.133** (1190.202), after the last chart sample at 0.079. The one-second STATUS sampling skipped some intermediate scroll states, so these values bracket observed changes and are not exact transition thresholds. At 1280 horizontal pixels and 32 pixels/tile at zoom 1, 0.133 corresponds to approximately 301 tiles across, and 0.099 to approximately 404; this is broadly consistent with the configured 300-tile detail boundary, rather than proving the default 200-tile limit. The full range sampled was 0.004 (rounded; configured minimum 0.00390625) through 3.000. No `render_mode=game` appeared in remote view during step 13.

Selected STATUS evidence (excluded from the requested full filtered output below):

```text
1117.136 Script @__rts-spike-camera__/control.lua:31: [rts-camera] STATUS tick=65160 rel=65160 player=1 controller=remote physical=god desired=remote position={-0.04, 7.93} physical_position={-0.04, 7.93} character=false render_mode=chart_zoomed_in zoom=0.133 surface=nauvis cursor=rts-cursor selected=nil
1127.135 Script @__rts-spike-camera__/control.lua:31: [rts-camera] STATUS tick=65760 rel=65760 player=1 controller=remote physical=god desired=remote position={-0.04, 6.16} physical_position={-0.04, 7.93} character=false render_mode=chart zoom=0.099 surface=nauvis cursor=rts-cursor selected=nil
1144.135 Script @__rts-spike-camera__/control.lua:31: [rts-camera] STATUS tick=66780 rel=66780 player=1 controller=remote physical=god desired=remote position={-0.04, -162.87} physical_position={-0.04, 7.93} character=false render_mode=chart zoom=0.004 surface=nauvis cursor=rts-cursor selected=nil
1189.136 Script @__rts-spike-camera__/control.lua:31: [rts-camera] STATUS tick=69480 rel=69480 player=1 controller=remote physical=god desired=remote position={-0.04, 4.37} physical_position={-0.04, 7.93} character=false render_mode=chart zoom=0.079 surface=nauvis cursor=rts-cursor selected=nil
1190.202 Script @__rts-spike-camera__/control.lua:31: [rts-camera] STATUS tick=69540 rel=69540 player=1 controller=remote physical=god desired=remote position={-0.04, 7.94} physical_position={-0.04, 7.93} character=false render_mode=chart_zoomed_in zoom=0.133 surface=nauvis cursor=rts-cursor selected=nil
1210.202 Script @__rts-spike-camera__/control.lua:31: [rts-camera] STATUS tick=70740 rel=70740 player=1 controller=remote physical=god desired=remote position={-0.04, 10.34} physical_position={-0.04, 7.93} character=false render_mode=chart_zoomed_in zoom=3.000 surface=nauvis cursor=rts-cursor selected=nil
```

Full output of `grep '\[rts-camera\]' build/camera-human.log | grep -v STATUS | grep -v HEARTBEAT` at report capture time, including all pre-existing entries:

```text
  22.895 Script @__rts-spike-camera__/control.lua:31: [rts-camera] control.lua loaded
  22.903 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_created player=1 tick=0
  22.903 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SETUP (created) player=1 tick=0 controller=character physical=character character=true position={0.00, 0.00} multiplayer=false
  22.904 Script @__rts-spike-camera__/control.lua:31: [rts-camera] freeplay state at created: init_ran=true disable_crashsite=true skip_intro=true
  22.904 Script @__rts-spike-camera__/control.lua:31: [rts-camera] player.character = nil -> ok=true err=nil controller_now=god
  22.904 Script @__rts-spike-camera__/control.lua:31: [rts-camera] character.destroy() -> ok=true result=true
  22.904 Script @__rts-spike-camera__/control.lua:31: [rts-camera] set_controller{remote} (setup/created) ok=true err=nil target={6.00, 6.00} -> controller=remote physical=god position={6.00, 6.00} physical_position={0.00, 0.00}
  22.904 Script @__rts-spike-camera__/control.lua:31: [rts-camera] default zoom_limits (controller=remote): {closest = {zoom = 3}, furthest = {zoom = 0.00390625}, furthest_game_view = {distance = 200, max_distance = 500}} ; zoom=0.3
  22.904 Script @__rts-spike-camera__/control.lua:31: [rts-camera] set_zoom_limits(remote, {furthest_game_view = {distance = 300, max_distance = 600}}) ok=true err=nil
  22.904 Script @__rts-spike-camera__/control.lua:31: [rts-camera] zoom_limits now (controller=remote): {closest = {zoom = 3}, furthest = {zoom = 0.00390625}, furthest_game_view = {distance = 300, max_distance = 600}} ; zoom=0.3 render_mode=game
  22.905 Script @__rts-spike-camera__/control.lua:31: [rts-camera] give_cursor (setup/created): set_stack ok=true result=true cursor=rts-cursor temporary=false controller=remote
  22.905 Script @__rts-spike-camera__/control.lua:31: [rts-camera] GUI built for player 1: frame=true minimap=true camera=true button=true
  22.905 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_joined_game player=1 tick=0 setup_done=true controller=remote
  22.905 Script @__rts-spike-camera__/control.lua:31: [rts-camera] GUI built for player 1: frame=true minimap=true camera=true button=true
  22.906 Script @__rts-spike-camera__/control.lua:31: [rts-camera] spawned 10 small-biters (force=player) near {10.00, 10.00} and car=true on nauvis at tick 0
  22.906 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_controller_changed old=character new=remote physical=god desired=remote in_setup=false position={6.00, 6.00}
  22.906 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=remote
  24.904 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SCREENSHOT rts-camera-120.png ok=true err=nil controller=remote position={6.00, 6.00}
  25.903 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SCREENSHOT rts-camera-180-playerzoom.png ok=true err=nil controller=remote position={6.00, 6.00}
  72.902 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SCREENSHOT rts-camera-3000.png ok=true err=nil controller=remote position={6.00, 6.00}
  73.905 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SELFTEST exit_remote_view() ok=true result=nil -> controller=god
  73.905 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_controller_changed old=remote new=god physical=god desired=remote in_setup=false position={0.00, 0.00}
  73.905 Script @__rts-spike-camera__/control.lua:31: [rts-camera] CONTROLLER CHANGED (event): remote -> god while desired=remote; re-applying next tick
  73.905 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=god
  73.919 Script @__rts-spike-camera__/control.lua:31: [rts-camera] set_controller{remote} (reapply/event) ok=true err=nil target={6.00, 6.00} -> controller=remote physical=god position={6.00, 6.00} physical_position={0.00, 0.00}
  73.919 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_controller_changed old=god new=remote physical=god desired=remote in_setup=false position={6.00, 6.00}
  73.919 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=remote
  75.902 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SELFTEST zoom := 0.2 -> zoom=0.2 render_mode=chart_zoomed_in
  76.236 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SELFTEST zoom check -> zoom=0.2 render_mode=chart_zoomed_in
  76.902 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SELFTEST zoom := 0.08 -> zoom=0.08 render_mode=chart_zoomed_in
  77.235 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SELFTEST zoom check -> zoom=0.08 render_mode=chart
  77.902 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SELFTEST zoom reset -> zoom=0.3 render_mode=chart
  78.902 Script @__rts-spike-camera__/control.lua:31: [rts-camera] TOGGLE (selftest): remote -> god
  78.903 Script @__rts-spike-camera__/control.lua:31: [rts-camera] set_controller{god} (toggle/selftest) ok=true err=nil -> controller=god position={6.00, 6.00} (camera was at {6.00, 6.00})
  78.904 Script @__rts-spike-camera__/control.lua:31: [rts-camera] teleport god to camera position ok=true result=true -> position={6.00, 6.00}
  78.905 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_controller_changed old=remote new=god physical=god desired=god in_setup=false position={6.00, 6.00}
  78.905 Script @__rts-spike-camera__/control.lua:31: [rts-camera] give_cursor (after controller change): set_stack ok=true result=true cursor=rts-cursor temporary=false controller=god
  78.905 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=god
  79.569 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SCREENSHOT rts-camera-3400-god.png ok=true err=nil controller=god position={6.00, 6.00}
  80.569 Script @__rts-spike-camera__/control.lua:31: [rts-camera] TOGGLE (selftest): god -> remote
  80.570 Script @__rts-spike-camera__/control.lua:31: [rts-camera] set_controller{remote} (toggle/selftest) ok=true err=nil target={6.00, 6.00} -> controller=remote physical=god position={6.00, 6.00} physical_position={6.00, 6.00}
  80.570 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_controller_changed old=god new=remote physical=god desired=remote in_setup=false position={6.00, 6.00}
  80.570 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=remote
  81.569 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SELFTEST done: controller=remote character=false
 387.255 Script @__rts-spike-camera__/control.lua:31: [rts-camera] HOVER selected=unit:small-biter at {18.32, 4.02} controller=remote
 388.552 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-lclick tick=21931 cursor_position={11.25, 10.40} cursor_display_location={590, 438} in_gui=false element=nil selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 388.671 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SELECT on_player_selected_area item=rts-cursor area={10.22, 10.34}..{11.25, 10.40} (1.03x0.06) center={10.73, 10.37} entities=1 [unit:small-biter@player] tiles=0 surface=nauvis controller=remote quality=normal
 388.671 Script @__rts-spike-camera__/control.lua:31: [rts-camera] HOVER selected=unit:small-biter at {10.45, 10.86} controller=remote
 398.369 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-lclick tick=22520 cursor_position={14.25, 13.65} cursor_display_location={686, 542} in_gui=false element=nil selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 398.735 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SELECT on_player_selected_area item=rts-cursor area={4.97, 13.65}..{14.25, 18.40} (9.28x4.75) center={9.61, 16.03} entities=2 [unit:small-biter@player, unit:small-biter@player] tiles=0 surface=nauvis controller=remote quality=normal
 399.069 Script @__rts-spike-camera__/control.lua:31: [rts-camera] HOVER selected=unit:small-biter at {7.82, 17.11} controller=remote
 399.919 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-lclick tick=22613 cursor_position={9.81, 9.90} cursor_display_location={544, 422} in_gui=false element=nil selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 400.002 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SELECT on_player_selected_area item=rts-cursor area={9.81, 9.90}..{9.81, 9.90} (0.00x0.00) center={9.81, 9.90} entities=0 [] tiles=0 surface=nauvis controller=remote quality=normal
 400.069 Script @__rts-spike-camera__/control.lua:31: [rts-camera] HOVER selected=unit:small-biter at {9.10, 10.11} controller=remote
 402.535 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-lclick tick=22770 cursor_position={13.31, 8.28} cursor_display_location={656, 370} in_gui=false element=nil selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 402.819 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SELECT on_player_selected_area item=rts-cursor area={4.88, 8.28}..{13.31, 11.59} (8.44x3.31) center={9.09, 9.93} entities=1 [unit:small-biter@player] tiles=0 surface=nauvis controller=remote quality=normal
 404.169 Script @__rts-spike-camera__/control.lua:31: [rts-camera] HOVER selected=unit:small-biter at {9.10, 10.11} controller=remote
 541.505 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-lclick tick=31099 cursor_position={13.44, 2.68} cursor_display_location={660, 191} in_gui=false element=nil selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 541.508 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SELECT on_player_selected_area item=rts-cursor area={13.44, 2.68}..{21.34, 7.62} (7.91x4.94) center={17.39, 5.15} entities=4 [unit:small-biter@player, unit:small-biter@player, unit:small-biter@player, unit:small-biter@player] tiles=0 surface=nauvis controller=remote quality=normal
 542.402 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-lclick tick=31153 cursor_position={-5.25, 13.65} cursor_display_location={62, 542} in_gui=false element=nil selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 542.402 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SELECT on_player_selected_area item=rts-cursor area={-5.25, 13.65}..{0.56, 18.09} (5.81x4.44) center={-2.34, 15.87} entities=0 [] tiles=0 surface=nauvis controller=remote quality=normal
 551.585 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-rclick tick=31704 cursor_position={-1.91, 14.12} cursor_display_location={169, 557} in_gui=false element=nil selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 551.635 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SELECT on_player_reverse_selected_area item=rts-cursor area={-1.91, 14.12}..{-1.91, 14.12} (0.00x0.00) center={-1.91, 14.12} entities=0 [] tiles=0 surface=nauvis controller=remote quality=normal
 552.369 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-rclick tick=31751 cursor_position={18.88, 4.75} cursor_display_location={834, 257} in_gui=false element=nil selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 552.419 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SELECT on_player_reverse_selected_area item=rts-cursor area={18.88, 4.75}..{18.88, 4.75} (0.00x0.00) center={18.88, 4.75} entities=0 [] tiles=0 surface=nauvis controller=remote quality=normal
 552.952 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-rclick-consuming tick=31786 cursor_position={10.97, 10.34} cursor_display_location={581, 436} in_gui=false element=nil selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 553.556 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-cg-1 tick=31808 cursor_position={10.97, 10.34} cursor_display_location={581, 436} in_gui=false element=nil selected_prototype=nil controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 553.569 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-cg-1 tick=31810 cursor_position={10.97, 10.34} cursor_display_location={581, 436} in_gui=false element=nil selected_prototype=nil controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 553.586 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-recall-1 tick=31811 cursor_position={10.97, 10.34} cursor_display_location={581, 436} in_gui=false element=nil selected_prototype=nil controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 553.586 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=empty controller=remote
 553.588 Script @__rts-spike-camera__/control.lua:31: [rts-camera] give_cursor (re-insert after cursor emptied): set_stack ok=true result=true cursor=rts-cursor temporary=false controller=remote
 553.602 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=remote
 565.252 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-toggle-controller tick=32511 cursor_position={10.97, 10.34} cursor_display_location={581, 436} in_gui=false element=nil selected_prototype=nil controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 565.253 Script @__rts-spike-camera__/control.lua:31: [rts-camera] TOGGLE (F2): remote -> god
 565.269 Script @__rts-spike-camera__/control.lua:31: [rts-camera] set_controller{god} (toggle/F2) ok=true err=nil -> controller=god position={12.81, 9.21} (camera was at {12.81, 9.21})
 565.269 Script @__rts-spike-camera__/control.lua:31: [rts-camera] teleport god to camera position ok=true result=true -> position={12.81, 9.21}
 565.270 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_controller_changed old=remote new=god physical=god desired=god in_setup=false position={12.81, 9.21}
 565.270 Script @__rts-spike-camera__/control.lua:31: [rts-camera] give_cursor (after controller change): set_stack ok=true result=true cursor=rts-cursor temporary=false controller=god
 565.271 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=god
 582.035 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-toggle-controller tick=33517 cursor_position={10.97, 10.34} cursor_display_location={581, 436} in_gui=true element=nil selected_prototype=nil controller=god render_mode=game cursor=rts-cursor
 582.035 Script @__rts-spike-camera__/control.lua:31: [rts-camera] TOGGLE (F2): god -> remote
 582.040 Script @__rts-spike-camera__/control.lua:31: [rts-camera] set_controller{remote} (toggle/F2) ok=true err=nil target={12.81, 9.21} -> controller=remote physical=god position={12.81, 9.21} physical_position={12.81, 9.21}
 582.041 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_controller_changed old=god new=remote physical=god desired=remote in_setup=false position={12.81, 9.21}
 582.041 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=remote
 589.369 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-linked-toggle-map tick=33957 cursor_position={-1.02, 17.65} cursor_display_location={581, 436} in_gui=false element=nil selected_prototype=nil controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 589.370 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_controller_changed old=remote new=god physical=god desired=remote in_setup=false position={12.81, 9.21}
 589.370 Script @__rts-spike-camera__/control.lua:31: [rts-camera] CONTROLLER CHANGED (event): remote -> god while desired=remote; re-applying next tick
 589.370 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=god
 596.723 Script @__rts-spike-camera__/control.lua:31: [rts-camera] set_controller{remote} (reapply/event) ok=true err=nil target={12.81, 9.21} -> controller=remote physical=god position={12.81, 9.21} physical_position={12.81, 9.21}
 596.724 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_controller_changed old=god new=remote physical=god desired=remote in_setup=false position={12.81, 9.21}
 596.724 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=remote
 638.303 Script @__rts-spike-camera__/control.lua:31: [rts-camera] GUI_HOVER element=minimap:rts_minimap
 638.369 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-lclick tick=36450 cursor_position={39.44, 17.82} cursor_display_location={103, 305} in_gui=true element=minimap:rts_minimap selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 638.370 Script @__rts-spike-camera__/control.lua:31: [rts-camera] GUI_CLICK element=minimap:rts_minimap button=left alt=false control=false shift=false cursor_display_location={103, 305} controller=remote
 638.536 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-rclick tick=36460 cursor_position={39.44, 17.82} cursor_display_location={103, 305} in_gui=true element=minimap:rts_minimap selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 638.536 Script @__rts-spike-camera__/control.lua:31: [rts-camera] GUI_CLICK element=minimap:rts_minimap button=right alt=false control=false shift=false cursor_display_location={103, 305} controller=remote
 638.819 Script @__rts-spike-camera__/control.lua:31: [rts-camera] GUI_LEAVE element=minimap:rts_minimap
 638.819 Script @__rts-spike-camera__/control.lua:31: [rts-camera] GUI_HOVER element=camera:rts_camera
 638.885 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-lclick tick=36481 cursor_position={40.94, 17.82} cursor_display_location={247, 305} in_gui=true element=camera:rts_camera selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 638.886 Script @__rts-spike-camera__/control.lua:31: [rts-camera] GUI_CLICK element=camera:rts_camera button=left alt=false control=false shift=false cursor_display_location={247, 305} controller=remote
 639.368 Script @__rts-spike-camera__/control.lua:31: [rts-camera] GUI_LEAVE element=camera:rts_camera
 639.368 Script @__rts-spike-camera__/control.lua:31: [rts-camera] GUI_HOVER element=button:rts_button
 639.435 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-lclick tick=36514 cursor_position={39.02, 18.72} cursor_display_location={62, 391} in_gui=true element=button:rts_button selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 639.486 Script @__rts-spike-camera__/control.lua:31: [rts-camera] GUI_CLICK element=button:rts_button button=left alt=false control=false shift=false cursor_display_location={62, 391} controller=remote
 649.238 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-linked-clear-cursor tick=37102 cursor_position={39.02, 18.72} cursor_display_location={62, 391} in_gui=true element=button:rts_button selected_prototype=nil controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 649.239 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=empty controller=remote
 649.239 Script @__rts-spike-camera__/control.lua:31: [rts-camera] give_cursor (re-insert after cursor emptied): set_stack ok=true result=true cursor=rts-cursor temporary=false controller=remote
 649.252 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=remote
 649.269 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-give-cursor tick=37104 cursor_position={39.02, 18.72} cursor_display_location={62, 391} in_gui=true element=button:rts_button selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 649.269 Script @__rts-spike-camera__/control.lua:31: [rts-camera] give_cursor (F1): clear_cursor ok=true result=true
 649.269 Script @__rts-spike-camera__/control.lua:31: [rts-camera] give_cursor (F1): set_stack ok=true result=true cursor=rts-cursor temporary=false controller=remote
 649.270 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=remote
 654.719 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-linked-toggle-map tick=37431 cursor_position={39.02, 18.72} cursor_display_location={62, 391} in_gui=true element=button:rts_button selected_prototype=nil controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 654.721 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_controller_changed old=remote new=god physical=god desired=remote in_setup=false position={12.81, 9.21}
 654.721 Script @__rts-spike-camera__/control.lua:31: [rts-camera] CONTROLLER CHANGED (event): remote -> god while desired=remote; re-applying next tick
 654.722 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=god
 654.736 Script @__rts-spike-camera__/control.lua:31: [rts-camera] set_controller{remote} (reapply/event) ok=true err=nil target={45.04, 18.81} -> controller=remote physical=god position={45.04, 18.81} physical_position={12.81, 9.21}
 654.737 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_controller_changed old=god new=remote physical=god desired=remote in_setup=false position={45.04, 18.81}
 654.737 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=remote
 661.569 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-linked-toggle-map tick=37842 cursor_position={-90.43, 16.70} cursor_display_location={62, 391} in_gui=true element=button:rts_button selected_prototype=nil controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 661.570 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_controller_changed old=remote new=god physical=god desired=remote in_setup=false position={12.81, 9.21}
 661.570 Script @__rts-spike-camera__/control.lua:31: [rts-camera] CONTROLLER CHANGED (event): remote -> god while desired=remote; re-applying next tick
 661.570 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=god
 661.586 Script @__rts-spike-camera__/control.lua:31: [rts-camera] set_controller{remote} (reapply/event) ok=true err=nil target={45.04, 18.81} -> controller=remote physical=god position={45.04, 18.81} physical_position={12.81, 9.21}
 661.586 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_controller_changed old=god new=remote physical=god desired=remote in_setup=false position={45.04, 18.81}
 661.586 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=remote
 668.202 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-toggle-controller tick=38240 cursor_position={-90.43, 16.70} cursor_display_location={62, 391} in_gui=true element=button:rts_button selected_prototype=nil controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 668.202 Script @__rts-spike-camera__/control.lua:31: [rts-camera] TOGGLE (F2): remote -> god
 668.203 Script @__rts-spike-camera__/control.lua:31: [rts-camera] set_controller{god} (toggle/F2) ok=true err=nil -> controller=god position={45.04, 18.81} (camera was at {45.04, 18.81})
 668.204 Script @__rts-spike-camera__/control.lua:31: [rts-camera] teleport god to camera position ok=true result=true -> position={45.04, 18.81}
 668.204 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_controller_changed old=remote new=god physical=god desired=god in_setup=false position={45.04, 18.81}
 668.204 Script @__rts-spike-camera__/control.lua:31: [rts-camera] give_cursor (after controller change): set_stack ok=true result=true cursor=rts-cursor temporary=false controller=god
 668.204 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=god
 674.870 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-toggle-controller tick=38640 cursor_position={26.97, 18.53} cursor_display_location={62, 391} in_gui=true element=button:rts_button selected_prototype=nil controller=god render_mode=game cursor=rts-cursor
 674.870 Script @__rts-spike-camera__/control.lua:31: [rts-camera] TOGGLE (F2): god -> remote
 674.872 Script @__rts-spike-camera__/control.lua:31: [rts-camera] set_controller{remote} (toggle/F2) ok=true err=nil target={45.04, 18.81} -> controller=remote physical=god position={45.04, 18.81} physical_position={45.04, 18.81}
 674.873 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_controller_changed old=god new=remote physical=god desired=remote in_setup=false position={45.04, 18.81}
 674.873 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=remote
 684.604 Script @__rts-spike-camera__/control.lua:31: [rts-camera] GUI_LEAVE element=button:rts_button
 856.702 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-lclick tick=49549 cursor_position={0.27, 8.18} cursor_display_location={650, 232} in_gui=false element=nil selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 856.705 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SELECT on_player_selected_area item=rts-cursor area={0.27, 8.18}..{13.08, 20.99} (12.81x12.81) center={6.68, 14.58} entities=9 [unit:small-biter@player, car:car@player, unit:small-biter@player, unit:small-biter@player, unit:small-biter@player, unit:small-biter@player, unit:small-biter@player, unit:small-biter@player] tiles=0 surface=nauvis controller=remote quality=normal
 869.369 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-lclick tick=50309 cursor_position={-4.11, 16.30} cursor_display_location={510, 492} in_gui=false element=nil selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 869.369 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SELECT on_player_selected_area item=rts-cursor area={-4.11, 16.30}..{-0.04, 20.05} (4.06x3.75) center={-2.07, 18.18} entities=0 [] tiles=0 surface=nauvis controller=remote quality=normal
 902.203 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-lclick tick=52279 cursor_position={4.96, 12.55} cursor_display_location={800, 372} in_gui=false element=nil selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 902.203 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SELECT on_player_selected_area item=rts-cursor area={4.96, 12.55}..{18.71, 21.30} (13.75x8.75) center={11.83, 16.93} entities=3 [unit:small-biter@player, unit:small-biter@player, unit:small-biter@player] tiles=0 surface=nauvis controller=remote quality=normal
 924.119 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-rclick tick=53594 cursor_position={-2.86, 17.24} cursor_display_location={550, 522} in_gui=false element=nil selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 924.168 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SELECT on_player_reverse_selected_area item=rts-cursor area={-2.86, 17.24}..{-2.86, 17.24} (0.00x0.00) center={-2.86, 17.24} entities=0 [] tiles=0 surface=nauvis controller=remote quality=normal
 950.752 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-rclick tick=55180 cursor_position={7.39, 15.05} cursor_display_location={878, 452} in_gui=false element=nil selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 950.802 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SELECT on_player_reverse_selected_area item=rts-cursor area={7.39, 15.05}..{7.39, 15.05} (0.00x0.00) center={7.39, 15.05} entities=0 [] tiles=0 surface=nauvis controller=remote quality=normal
 970.237 Script @__rts-spike-camera__/control.lua:31: [rts-camera] HOVER selected=unit:small-biter at {1.78, 12.41} controller=remote
 970.302 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-rclick tick=56353 cursor_position={1.80, 11.93} cursor_display_location={699, 352} in_gui=false element=nil selected_prototype=entity/unit/small-biter controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
 970.352 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SELECT on_player_reverse_selected_area item=rts-cursor area={1.80, 11.93}..{1.80, 11.93} (0.00x0.00) center={1.80, 11.93} entities=1 [unit:small-biter@player] tiles=0 surface=nauvis controller=remote quality=normal
 970.352 Script @__rts-spike-camera__/control.lua:31: [rts-camera] HOVER selected=unit:small-biter at {1.78, 12.38} controller=remote
 991.668 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SELECT on_player_alt_reverse_selected_area item=rts-cursor area={-2.86, 17.24}..{-2.86, 17.24} (0.00x0.00) center={-2.86, 17.24} entities=0 [] tiles=0 surface=nauvis controller=remote quality=normal
1005.286 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-rclick-consuming tick=58452 cursor_position={-1.29, 17.24} cursor_display_location={600, 522} in_gui=false element=nil selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
1017.461 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-cg-1 tick=59181 cursor_position={-1.29, 17.24} cursor_display_location={600, 522} in_gui=false element=nil selected_prototype=nil controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
1028.636 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-cg-1 tick=59853 cursor_position={-1.29, 17.24} cursor_display_location={600, 522} in_gui=false element=nil selected_prototype=nil controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
1041.035 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-recall-1 tick=60597 cursor_position={-1.29, 17.24} cursor_display_location={600, 522} in_gui=false element=nil selected_prototype=nil controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
1041.036 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=empty controller=remote
1041.038 Script @__rts-spike-camera__/control.lua:31: [rts-camera] give_cursor (re-insert after cursor emptied): set_stack ok=true result=true cursor=rts-cursor temporary=false controller=remote
1041.052 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=remote
1054.952 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-toggle-controller tick=61429 cursor_position={-1.29, 17.24} cursor_display_location={600, 522} in_gui=false element=nil selected_prototype=nil controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
1054.952 Script @__rts-spike-camera__/control.lua:31: [rts-camera] TOGGLE (F2): remote -> god
1054.961 Script @__rts-spike-camera__/control.lua:31: [rts-camera] set_controller{god} (toggle/F2) ok=true err=nil -> controller=god position={-0.04, 13.43} (camera was at {-0.04, 13.43})
1054.961 Script @__rts-spike-camera__/control.lua:31: [rts-camera] teleport god to camera position ok=true result=true -> position={-0.04, 13.43}
1054.962 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_controller_changed old=remote new=god physical=god desired=god in_setup=false position={-0.04, 13.43}
1054.962 Script @__rts-spike-camera__/control.lua:31: [rts-camera] give_cursor (after controller change): set_stack ok=true result=true cursor=rts-cursor temporary=false controller=god
1054.963 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=god
1084.652 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-toggle-controller tick=63211 cursor_position={-1.29, 11.74} cursor_display_location={600, 522} in_gui=false element=nil selected_prototype=nil controller=god render_mode=game cursor=rts-cursor
1084.652 Script @__rts-spike-camera__/control.lua:31: [rts-camera] TOGGLE (F2): god -> remote
1084.653 Script @__rts-spike-camera__/control.lua:31: [rts-camera] set_controller{remote} (toggle/F2) ok=true err=nil target={-0.04, 7.93} -> controller=remote physical=god position={-0.04, 7.93} physical_position={-0.04, 7.93}
1084.654 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_controller_changed old=god new=remote physical=god desired=remote in_setup=false position={-0.04, 7.93}
1084.654 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=remote
1097.619 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-linked-toggle-map tick=63989 cursor_position={-9.42, 36.52} cursor_display_location={600, 522} in_gui=false element=nil selected_prototype=nil controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
1097.619 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_controller_changed old=remote new=god physical=god desired=remote in_setup=false position={-0.04, 7.93}
1097.619 Script @__rts-spike-camera__/control.lua:31: [rts-camera] CONTROLLER CHANGED (event): remote -> god while desired=remote; re-applying next tick
1097.619 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=god
1097.636 Script @__rts-spike-camera__/control.lua:31: [rts-camera] set_controller{remote} (reapply/event) ok=true err=nil target={-0.04, 7.93} -> controller=remote physical=god position={-0.04, 7.93} physical_position={-0.04, 7.93}
1097.636 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_controller_changed old=god new=remote physical=god desired=remote in_setup=false position={-0.04, 7.93}
1097.636 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=remote
1104.753 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_controller_changed old=remote new=god physical=god desired=remote in_setup=false position={-0.04, 7.93}
1104.753 Script @__rts-spike-camera__/control.lua:31: [rts-camera] CONTROLLER CHANGED (event): remote -> god while desired=remote; re-applying next tick
1104.753 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=god
1104.770 Script @__rts-spike-camera__/control.lua:31: [rts-camera] set_controller{remote} (reapply/event) ok=true err=nil target={-0.04, 7.93} -> controller=remote physical=god position={-0.04, 7.93} physical_position={-0.04, 7.93}
1104.770 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_controller_changed old=god new=remote physical=god desired=remote in_setup=false position={-0.04, 7.93}
1104.770 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=remote
1233.371 Script @__rts-spike-camera__/control.lua:31: [rts-camera] GUI_HOVER element=minimap:rts_minimap
1233.452 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-lclick tick=72127 cursor_position={-5.77, 9.37} cursor_display_location={90, 307} in_gui=true element=minimap:rts_minimap selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
1233.453 Script @__rts-spike-camera__/control.lua:31: [rts-camera] GUI_CLICK element=minimap:rts_minimap button=left alt=false control=false shift=false cursor_display_location={90, 307} controller=remote
1234.052 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-rclick tick=72163 cursor_position={-5.77, 9.37} cursor_display_location={90, 307} in_gui=true element=minimap:rts_minimap selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
1234.052 Script @__rts-spike-camera__/control.lua:31: [rts-camera] GUI_CLICK element=minimap:rts_minimap button=right alt=false control=false shift=false cursor_display_location={90, 307} controller=remote
1247.802 Script @__rts-spike-camera__/control.lua:31: [rts-camera] GUI_LEAVE element=minimap:rts_minimap
1247.802 Script @__rts-spike-camera__/control.lua:31: [rts-camera] GUI_HOVER element=camera:rts_camera
1247.869 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-lclick tick=72992 cursor_position={-4.16, 9.37} cursor_display_location={245, 307} in_gui=true element=camera:rts_camera selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
1247.869 Script @__rts-spike-camera__/control.lua:31: [rts-camera] GUI_CLICK element=camera:rts_camera button=left alt=false control=false shift=false cursor_display_location={245, 307} controller=remote
1248.468 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-rclick tick=73028 cursor_position={-4.16, 9.37} cursor_display_location={245, 307} in_gui=true element=camera:rts_camera selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
1248.469 Script @__rts-spike-camera__/control.lua:31: [rts-camera] GUI_CLICK element=camera:rts_camera button=right alt=false control=false shift=false cursor_display_location={245, 307} controller=remote
1264.335 Script @__rts-spike-camera__/control.lua:31: [rts-camera] GUI_LEAVE element=camera:rts_camera
1264.335 Script @__rts-spike-camera__/control.lua:31: [rts-camera] GUI_HOVER element=button:rts_button
1264.402 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-lclick tick=73984 cursor_position={-6.07, 10.24} cursor_display_location={61, 391} in_gui=true element=button:rts_button selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
1264.452 Script @__rts-spike-camera__/control.lua:31: [rts-camera] GUI_CLICK element=button:rts_button button=left alt=false control=false shift=false cursor_display_location={61, 391} controller=remote
1275.686 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-linked-clear-cursor tick=74661 cursor_position={-6.07, 10.24} cursor_display_location={61, 391} in_gui=true element=button:rts_button selected_prototype=nil controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
1275.686 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=empty controller=remote
1275.686 Script @__rts-spike-camera__/control.lua:31: [rts-camera] give_cursor (re-insert after cursor emptied): set_stack ok=true result=true cursor=rts-cursor temporary=false controller=remote
1275.702 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=remote
1286.219 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-give-cursor tick=75293 cursor_position={-6.07, 10.24} cursor_display_location={61, 391} in_gui=true element=button:rts_button selected_prototype=item/selection-tool/rts-cursor controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
1286.219 Script @__rts-spike-camera__/control.lua:31: [rts-camera] give_cursor (F1): clear_cursor ok=true result=true
1286.219 Script @__rts-spike-camera__/control.lua:31: [rts-camera] give_cursor (F1): set_stack ok=true result=true cursor=rts-cursor temporary=false controller=remote
1286.220 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=remote
1299.668 Script @__rts-spike-camera__/control.lua:31: [rts-camera] GUI_LEAVE element=button:rts_button
1299.735 Script @__rts-spike-camera__/control.lua:31: [rts-camera] INPUT rts-lclick tick=76104 cursor_position={3.99, 14.19} cursor_display_location={1027, 770} in_gui=true element=nil selected_prototype=shortcut/shortcut/rts-give-cursor-shortcut controller=remote render_mode=chart_zoomed_in cursor=rts-cursor
1299.786 Script @__rts-spike-camera__/control.lua:31: [rts-camera] EVENT on_player_cursor_stack_changed cursor=rts-cursor controller=remote
1351.753 Script @__rts-spike-camera__/control.lua:31: [rts-camera] SELECT on_player_alt_selected_area item=rts-cursor area={-2.02, 16.39}..{-2.02, 16.39} (0.00x0.00) center={-2.02, 16.39} entities=0 [] tiles=0 surface=nauvis controller=remote quality=normal
```

Ten-line summary:

1. YES: custom left, right, and middle mouse inputs fire in remote view with cursor_position (856.702, 924.119/970.302, 1005.286).
2. on_player_selected_area fires for both populated drag boxes (9 entities) and empty drag boxes (0 entities).
3. on_player_alt_selected_area fires for supplemental Shift+left-click (1351.753); Shift-drag over units remains unverified because of the input API limitation.
4. on_player_reverse_selected_area fires for plain right-clicks, both empty and one-biter selections; right-drag over biters and trees remains untested.
5. on_player_alt_reverse_selected_area fires for Shift+right-click (991.668); Shift+right-drag remains untested.
6. YES: minimap and camera GUI clicks fire for both buttons, with GUI_HOVER and custom inputs carrying in_gui=true and the correct element.
7. Ctrl+1 and Cmd+1 both work; bare 1 also clears the cursor, and F2 also opens inventory/picker UI, creating RTS-control interference.
8. F2 preserves the world position on entry to god mode and W moves the camera, but returning to remote jumps the zoom out; M/Escape briefly exit remote before next-tick restoration.
9. Remote zoom uses chart_zoomed_in/chart, with observed switch samples 0.099 outward and 0.133 inward; pointer-centered zoom and rapid low-zoom panning complicate camera control.
10. Q/F1/shortcut restoration works; biter hover was observed incidentally in step 7, standalone step 20 was limited by the API, and Factorio was left running unpaused in remote view with rts-cursor.
