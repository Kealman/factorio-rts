# Announcement texts

Short posts for launch day, plus the GitHub repository's description and topics. Replace nothing unless the repository or portal URL changed (see [checklist.md](checklist.md)). Text between the `=====` markers is meant to be copied as it is.

## GitHub repository

**Description** (the "About" box, under 350 characters):

=====
Factorio 2.1 mod: a StarCraft-style RTS with a real Factorio production economy, grown into a Rise of Nations-style mini-state with cities, rails, trade, diplomacy and war on worlds up to 4096 tiles.
=====

**Website:** https://mods.factorio.com/mod/factorio-rts

**Topics:**

=====
factorio, factorio-mod, factorio-mods, lua, rts, real-time-strategy, strategy-game, grand-strategy, game-ai, procedural-generation, logistics, trains
=====

## Reddit: r/factorio

Use the subreddit's "Modded" flair if it is offered, and attach 3 or 4 screenshots as a gallery (suggested: `docs/media/04-division-battle.png`, `02-capital.png`, `09-strategic-map.png`, `07-artillery-train.png`).

**Title:**

=====
I turned Factorio into an RTS: StarCraft-style control, a Factorio economy, and a Nation mode with cities, rails, trade and war on 4096-tile worlds
=====

**Body:**

=====
**Factorio RTS** is a mod for Factorio 2.1 (Space Age optional) that replaces the engineer with an RTS camera. You box-select armies, right-click to attack, set control groups and fire abilities, and everything you field comes out of a factory you build: ore patches that run dry, smelting lines, forward hubs with their own logistic networks, and haulers that the enemy raids.

There are two modes:

* **Skirmish**: 15 to 30 minute matches against 1 to 3 AI commanders, each with its own doctrine (economic, aggressive or turtle), on generated arenas with moats and contested patches.
* **Nation**: a mini-state on a world of up to 4096×4096 tiles with up to 6 nations. You found cities, feed and house their people (who staff your buildings and become your soldiers), link them by rail (click depot to depot and a construction train lays the line), run a treasury and trade on a shared world market, declare wars with goals, capture cities and race through three ages to a Space Program launch. The AI nations play by the same rules, without resource cheats.

It is a first release, so expect rough edges: the AI is slow to the last age, it under-uses air units and artillery trains, and I have only tested it on macOS. Multiplayer is co-op against the AI.

* Mod Portal: https://mods.factorio.com/mod/factorio-rts
* Source, full guide and known issues: https://github.com/Kealman/factorio-rts

Start a new Freeplay game and the lobby opens. I'd love feedback, especially balance reports and tests on Windows and Linux.
=====

## Factorio forums: Mods subforum (BBCode)

The forums use BBCode, not Markdown. Post in the Mods subforum; the post title is the first line.

**Title:**

=====
[MOD 2.1] Factorio RTS - StarCraft-style control, a Factorio economy and a Nation mode
=====

**Body:**

=====
[b]Factorio RTS[/b] turns Factorio into a real-time strategy game. You command from a free camera instead of walking an engineer: box-select units, right-click to move and attack, set control groups and fire abilities. Your army comes out of a real Factorio production economy that you build and defend.

[b]Requirements:[/b] Factorio 2.1. Space Age is optional. Start a new Freeplay game; the RTS lobby opens when you join.

[b]Skirmish[/b]
[list]
[*]15 to 30 minute matches against 1 to 3 AI commanders with economic, aggressive or turtle doctrines.
[*]Finite ore patches, smelting lines, factories and labs, forward hubs with their own logistic networks and haulers that can be raided.
[*]Walkers, drones, heavy walkers, raiders and artillery in a counter wheel, 19 technologies, five abilities and a Commander hero.
[/list]

[b]Nation[/b]
[list]
[*]Worlds of 2048 to 4096 tiles with 2 to 6 nations, named regions, mountains, rivers, city-states, trade ports and rare resources.
[*]Up to 4 cities per nation with territory, people, housing, food and labor.
[*]Rail lines laid by construction trains; freight, troop, artillery and armoured trains.
[*]A treasury, taxes, a shared world market, contracts, diplomacy, war goals and treaties.
[*]Three ages, from the Railway Charter to the Space Program and a Space victory.
[*]Divisions with supply, city capture, garrisons, fronts, fort belts and air units.
[*]A layered nation AI whose difficulty changes skill, never resources.
[/list]

[b]Multiplayer:[/b] cooperative, every human on the player's side against the AI.

[b]Known issues:[/b] the Nation AI is slow to Age III and rarely uses air units or artillery trains; only macOS has been tested so far. The full list is in the README.

[b]Download:[/b] [url=https://mods.factorio.com/mod/factorio-rts]Mod Portal[/url]
[b]Source, guide and bug reports:[/b] [url=https://github.com/Kealman/factorio-rts]GitHub[/url]

[img]https://raw.githubusercontent.com/Kealman/factorio-rts/main/docs/media/02-capital.png[/img]
[img]https://raw.githubusercontent.com/Kealman/factorio-rts/main/docs/media/04-division-battle.png[/img]
[img]https://raw.githubusercontent.com/Kealman/factorio-rts/main/docs/media/09-strategic-map.png[/img]

Feedback and bug reports are very welcome. Please include the map seed ([i]/seed[/i] in the console), the mode and the [i][rts][/i] lines of factorio-current.log.
=====

## 0.1.2 update (reply in the forum thread and on the Reddit post)

Paste it as a comment; replace the 0.1.1 paragraph if one is pinned.

=====
**Factorio RTS 0.1.2 is out.** It comes from the first long game on 0.1.1, where building and logistics got in the way. You can now order crafts in the factory like handcrafting (click 1, Shift 5, Ctrl all), select and demolish belts, inserters and poles, cancel ghosts, clear trees and rocks with a right click, and use underground belts and splitters. Hold Shift over anything (or press Shift+F11) for a help card. Oil panels say there are no pipes, and a new city brings starter stock from its mother city. Railways are yours now: trains run stop lists with orders per stop, a train builder composes mixed trains carriage by carriage, and the Rail tool lays your own track with signals and rail stations. 0.1.1 saves load. Known limits: two trains on single track can block each other at a platform (add a passing loop), junctions turn one way, and the AI is unchanged from 0.1.1.

Mod Portal: https://mods.factorio.com/mod/factorio-rts · Release notes: https://github.com/Kealman/factorio-rts/releases
=====
