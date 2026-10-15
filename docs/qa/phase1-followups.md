# Phase 1 QA follow-ups (from `phase1-qa-results.md`, 2026-10-15)

Confirmed by the first interactive run: remote-view camera with WASD pan and wheel zoom, Space = home, minimap click jumps the camera accurately, HUD renders without vanilla chrome, Q/F1 cursor restore, M/Escape are undone by the controller guard, attack-move arm/disarm, HUD buttons dispatch.

Not verified (armies were dead before the selection steps because the console was blocked and the first enemy wave hit at 45 s): box select, click select, Shift add, control groups with units, move spread, attack on an enemy, stop/hold with units, fights.

Fixes to apply before the next QA run:

1. **Pan speed.** ~170 tiles per second of key hold at zoom 0.5 overshoots. Set `data.raw["remote-controller"]["default"].movement_speed` (data stage, see `research/api-capabilities-2.0.77.md` surprising findings: controller prototypes are moddable) to roughly a quarter of vanilla; verify in a GUI run by logging the camera pan distance per second (the `[rts] camera pan` line already exists).
2. **First enemy wave.** 45 s is too early for a human; make the first wave 3 minutes and later waves every 2 minutes, configurable in `storage.match.config`. The headless autotest can shorten it via a debug setting.
3. **Console-free QA controls.** Add custom inputs `rts-qa-reset` (CONTROL + SHIFT + R) and `rts-qa-end` (CONTROL + SHIFT + E) that call the same functions as the console commands, so a tester never needs the console. The per-run config now also binds F9 as the console alternative (`tools/factorio-env.sh`).
4. **Victory banner.** It stayed "Victory" while the strip showed 0 vs 0 after the last units died; derive the banner from `storage.match.phase` and only declare a winner when the other side is out and ours is not.
5. **Attack-move prompt.** The small armed-state prompt overlaps the HUD and tooltips; move it to the top strip message line and show the pressed state of the button more clearly.
6. **Spawn formation.** Initial silhouettes overlap densely; spawn in a looser grid (3.5 tiles for walkers, 5 for heavies).
7. **QA protocol.** Reorder so the reset hotkey is step 1 and the wave is disabled (`nowaves`) until the fight step; prefer short drags; the tester runs with the ABC input source if possible.
