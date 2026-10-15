# Phase 2 polish: locale, readability, HUD fixes

Date: 2026-10-15. Factorio 2.0.77 (mac-arm64, Steam). Mod: `mods/factorio-rts/`.
Input: `docs/qa/phase2-qa-results.md` (summary lines 10 and 11, the "Anything odd" column of steps 3, 10, 19, 28,
30, 34 and 35). HUD background: `docs/qa/phase2-hud-notes.md`, `docs/qa/phase1-hud-notes.md`.

## Files

| File | Change |
|---|---|
| `locale/en/factorio-rts.cfg` | Reference strings: every rts entity, item, recipe, description, the item group, the shortcut, every custom input, and the `[rts]` section with every HUD string |
| `locale/ru/factorio-rts.cfg` | New. The same 184 keys in Russian, with the same parameters |
| `scripts/hud.lua` | Every caption and tooltip is a localised string. New panel layout: wide and low, recipe grid. Vanilla entity tooltip off. |
| `scripts/selection.lua` | Rally marker: 1.5-scale flag, filled ring, "Rally" label, thicker dashed line |
| `scripts/orders.lua` | Order marker: larger ring, centre dot, 20 ticks |
| `prototypes/styles.lua` | Narrower group buttons, thinner progress bar; widths now set from hud.lua |
| `prototypes/buildings.lua`, `items.lua` | English fallback names removed; names come from the locale |
| `prototypes/categories.lua`, `inputs.lua` | Same. The four Phase 2 inputs had plain English `localised_name` strings, which would have stayed English in Russian. |

No gameplay number changed. No file of the AI work (`match.lua`, `control.lua`, `debug.lua`, `scripts/ai/`) was
touched, and neither was `camera.lua`.

## What changed

### 1. Localization

- **Prototypes.** Entities, items, recipes and the item group use the default keys `entity-name.<name>`,
  `entity-description.<name>`, `item-name.<name>`, `recipe-name.<name>` and `item-group-name.rts`. Building items
  take their description from `entity-description.<name>`, so the long texts exist once. All 13 recipes have a
  `recipe-name`, which fixes "Unknown key: recipe-name.rts-pole" (QA step 35).
- **HUD.** No English text is built in Lua any more. Numbers, key names (F, Ctrl+A), positions and rich-text icons
  are the only literal parts. Item, recipe and entity names come from the prototypes' `localised_name`. Entity status
  uses the vanilla `entity-status.*` keys, with the raw status as a `?` fallback.
- **Language.** The game falls back to `en` per key, so a key missing from `ru` shows English, never "Unknown key".
  Both files have identical key sets and parameters; the check script is below.

### 2. Clipping and the overflowing Pause button

The selection panel is now 520 × 114 GUI units, from 420 × 140. At UI scale 0.75 it is 390 × 86 px at (6, 708).

| Page | Layout |
|---|---|
| Units | Row 1: count, HP, order. Row 2: kinds, then "Groups" and buttons 1–5 at the right. Row 3: the four command buttons. Row 4: the hint, or the selection hint when nothing is selected. |
| Barracks, factory | Header: name and HP. Left: the recipe grid, 6 columns × 34 px, **Pause first**, then the recipes by group, subgroup and recipe order. Right: status line, progress bar on its own line, counters, rally or hint. |
| Other buildings | No grid; the text column takes the whole width |

- The grid has a fixed width, so the text column starts at the same x for the barracks and the factory.
- Every label has a `maximal_width`. The longer explanations moved into tooltips: barracks totals, rally help.
- Factory order: row 1 Pause, Stockpile, Extractor, Smelter, Solar array, Factory. Row 2 Belt, Inserter, Pole,
  Barracks, Turret, Ammo. A new recipe takes its place within its subgroup. Pause never moves.

### 3. Readability

| Item | Result |
|---|---|
| (a) Unit size | **Not changed.** `SpiderUnitPrototype` has no scale field (checked in `prototype-api.json`: torso graphics set, spider engine and leg specs only). Space Age's `make_stomper` and `make_strafer` take a scale, but it also scales the leg geometry, for example the stomper's ground position of `-7 * scale`. That changes stride and therefore walking speed, which is a gameplay number. Formation spacing is in `orders.formation`, which is gameplay code, so it was left alone too. |
| (b) Rally marker | Vanilla `utility/spawn_flag` (the red flag) at scale 1.5 with its pole foot on the point. A filled green disc on the ground with a 3 px ring, radius 1. The label `rts.rally-label` ("Rally" / "Сбор") above it, `scale_with_zoom`. A 3 px dashed line from the barracks. Every object goes to the selecting player only. Without a rally point the same marker is greyed at the default exit, without the label. |
| (c) Order marker | Ring radius 1.75 (an entity target: half its selection-box diagonal + 0.5), 4 px. A filled centre dot on ground targets. 20 ticks (was radius 1, 3 px, 30 ticks). |
| (d) Minimap hover | The overlap was the **vanilla entity tooltip**, drawn in the top-right corner under the HUD minimap. An opaque panel under the minimap would not help, because the minimap is drawn over the tooltip. `hud.lua` sets `game_view_settings.show_entity_tooltip = false` (`HIDE_ENTITY_TOOLTIP`, checked every refresh, logged once). Hovering still works (`update_entity_selection` stays on), so building clicks are unaffected. |
| (e) Chat | `GameViewSettings` has no console or chat field (2.0.77). The console's last line ends about 135 GUI units above the bottom of the window. The lower panel top, 122 units, now sits below it. Measured in a window capture at 0.75: chat ends at y ≈ 697, the panel starts at 708. |

### 4. Mixed languages in tooltips

Build-menu, recipe, resource, power, bots and command tooltips are all localised.

- The stock count is `{"rts.in-stock", n}`.
- Recipe times are `{"rts.seconds", n}` ("5 s" / "5 с").
- Costs are icon + number rich text, which needs no translation.

## Locale key conventions

- **Sections.** Prototype names live in the standard sections. HUD and map-marker text lives in `[rts]`, and the code
  refers to it as `{"rts.<key>", ...}`.
- **Key names.** Kebab case, area first:

  | Prefix | Area |
  |---|---|
  | `sel-`, `kind-`, `order-`, `group-`, `cmd-` | Units page |
  | `bld-`, `state-`, `recipe-`, `barracks-`, `rally-`, `factory-`, `cc-`, `turret-`, `extractor-`, `smelter-`, `stockpile-`, `solar-` | Building page |
  | `army`, `enemy-count`, `res-`, `power-`, `bots-` | Strip |
  | `match-`, `wave-`, `waves-off`, `attack-move-armed`, `placing` | Message line |
  | `build-`, `in-stock` | Build menu |

  Tooltips end in `-tooltip`.
- **Parameters.** `__1__`, `__2__`, … in the order the code passes them; each file's comment above a group says
  what they are. Numbers are passed as numbers, or as preformatted strings when the decimals matter (`"%.2f"`).
- **Plurals.** English uses `__plural_for_parameter__N__{1=unit|rest=units}__`. Russian avoids plural forms with
  a "noun: N" order ("Выбрано юнитов: 6"). If a plural is needed, use the vanilla Russian pattern
  `{ends in 11,ends in 12,ends in 13,ends in 14=…|ends in 1=…|ends in 2,ends in 3,ends in 4=…|rest=…}`.
- **Rich text.** `[font=default-bold]…[/font]` and `[item=…]` work in locale values. A line break is `\n`.
- **Comments.** Lines starting with `#` are comments. Comment lines contain no `=`.

## How to add a string

1. Add `key=English text` to the right group of `[rts]` in `locale/en/factorio-rts.cfg`.
2. Add the same key with the Russian text to `locale/ru/factorio-rts.cfg`, with the same `__N__` parameters.
3. In Lua, use `{"rts.key", p1, p2}` as a caption, tooltip, `player.print` argument or `draw_text` text. Never
   `string.format` user-visible text. Nest a localised string as a parameter (`{"rts.order", {"rts.order-move"}}`).
4. Keep it short. The panel's text column is 282 GUI units next to the recipe grid and 504 without it. At default
   fonts that is about 40 and 70 Cyrillic characters. Labels clip with "…"; put the long version in a tooltip.
5. Check parity and usage:

   ```sh
   python3 - mods/factorio-rts <<'EOF'
   import re,sys,glob
   root=sys.argv[1]
   def parse(p):
       d={};sec=None
       for l in open(p,encoding='utf-8'):
           l=l.rstrip('\n')
           if not l.strip() or l.lstrip().startswith(('#',';')): continue
           m=re.match(r'^\[(.+)\]$',l)
           if m: sec=m.group(1); continue
           if '=' in l: k,v=l.split('=',1); d[sec+'.'+k]=v
       return d
   en,ru=parse(root+'/locale/en/factorio-rts.cfg'),parse(root+'/locale/ru/factorio-rts.cfg')
   print('missing in ru',sorted(set(en)-set(ru)),'extra in ru',sorted(set(ru)-set(en)))
   print('param mismatch',[k for k in en if k in ru and set(re.findall(r'__(\d+)__',en[k]))!=set(re.findall(r'__(\d+)__',ru[k]))])
   used={m for f in glob.glob(root+'/scripts/*.lua') for m in re.findall(r'"(rts\.[a-z0-9-]+)"',open(f,encoding='utf-8').read())}
   print('undefined',sorted(u for u in used if u not in en and u!='rts.key'))
   EOF
   ```

## QA protocol impact

The Phase 2 protocol's panel coordinates are stale. These are the new centres at UI scale 0.75 in a 1280×800 game
area; add 28 px to y for the macOS title bar.

| Element | Centre |
|---|---|
| Units page | Group buttons y 742, x 231 / 266 / 301 / 336 / 371. Command row y 763: English Attack-move 56, Stop 124, Hold 176, Select all 249; Russian 56, 117, 183, 270. |
| Recipe grid | Row 1 y 745, row 2 y 771. Columns x 27, 53, 79, 105, 131, 157. |
| Barracks | Pause (27, 745), walker kit (53, 745), heavy kit (79, 745) |
| Factory | Pause (27, 745). Extractor is (79, 745), Stockpile (53, 745), Pole (79, 771). |

The log line now lists Pause first and the row length:

```
hud: recipe buttons factory#N player=1: pause rts-stockpile rts-extractor rts-smelter rts-solar-array rts-factory rts-belt rts-inserter rts-pole rts-barracks rts-turret rts-ammo (6 per row)
```

## Validation

| Run | Result |
|---|---|
| `tools/headless-run.sh 200 … build/p2-polish` (Space Age, clean copy of `mods/` at the end) | `autotest summary 65/65 (all passed)` at 152.6 s. 0 errors in the create and server logs. At 120 s the summary is not written yet: 64 checks passed and 0 failed by then. |
| Same, base only (`build/p2-polish-nosa`, 40 s) | 0 errors, 58 checks passed, 0 failed |
| GUI run, Russian (`[general] locale=ru` in the run's config; self-test and a 5-line chat probe switched on in the copy only) | 0 script errors, no "Unknown key". Screenshots in `build/shots-p2-polish-ru/`. Window capture with the console: `build/window-p2-polish-ru.png`. |
| GUI run, English (`locale=en`, same copy) | 0 script errors. Screenshots in `build/shots-p2-polish-en/`. Window capture: `build/window-p2-polish-en.png`. |

What the screenshots show, in Russian:

| Screenshot | Shows |
|---|---|
| `rts-hud-600.png` | Units page: "Выбрано юнитов: 6", "Шагоход ×6", group 1 toggled, all four command buttons inside the panel |
| `rts-hud-420.png` | Build prompt "Казармы: ЛКМ по карте — поставить, …" and "Приказ: ожидание 3, движение 3" |
| `rts-p1-270.png` | Order marker: 1.75-tile ring with the centre dot |
| `rts-hud-840.png` | CC page, three lines inside the panel |
| `rts-p1-900.png` | Barracks page and the rally marker: red flag, green disc, "Сбор" over copper ore |
| `rts-hud-960.png` | Factory grid 2 × 6 with Pause at the top left, Extractor active |

The window capture shows the console's last line above the panel, with no overlap. No text is clipped in either
language, and the Pause button is inside the panel. Script screenshots do not render the console, so the chat
check needs a real window capture. The scratch runner did this with `screencapture -l <window id>` at the stop
marker.

## For the lead

- **`match.lua` prints the result in English.** It uses `game.print("[RTS] Victory! …")`. The keys `rts.match-victory`,
  `rts.match-defeat` and `rts.match-draw` exist, so `game.print({"", "[RTS] ", {"rts.match-victory"}})` would
  localise it. `match.lua` belongs to the AI work, so it was not edited.
- **Developer and QA prints stay English.** These are the `debug.lua` and `camera.lua` prints (`qa-reset by …`,
  `/rts-eco`, admin-only). They are console output for testers, not HUD.
- **A comment in `camera.lua` is now stale.** It says `show_entity_tooltip` is kept on. The HUD now switches it off;
  set `HIDE_ENTITY_TOOLTIP = false` in `hud.lua` to get it back.
- **The QA protocol needs the new coordinates above.** The factory recipe order changed, Pause is first, and the
  units-page buttons moved.
- **Units still overlap when bunched.** Real relief needs either smaller pentapod variants, with walking speed
  re-tuned, or a wider formation spacing in `orders.lua`. Both are gameplay decisions.
- **`tools/gui-run.sh` has no locale switch.** The isolated config uses the system language. The Russian run used a
  scratch copy of the script that appends `[general] locale=ru` to the run's `config.ini`. A `LOCALE` variable in
  the shared script would make this repeatable.
