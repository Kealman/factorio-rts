# Publishing checklist: Factorio RTS 0.1.0

The exact steps to publish the repository on GitHub and the mod on the Factorio Mod Portal. Run the commands from the repository root. The texts to paste are in [mod-portal.md](mod-portal.md), [announce.md](announce.md) and [github-release.md](github-release.md).

## 1. Decisions to confirm first

| Item | Prepared value | Where it is used |
|---|---|---|
| License | MIT, "Copyright (c) 2026 Kealman" | `LICENSE`, README, portal License field |
| Repository | `Kealman/factorio-rts` (the name is free as of 2026-10-24) | `info.json` homepage and contact, README links, portal texts, announcements |
| Contact | `https://github.com/Kealman/factorio-rts/issues` | `info.json` contact |
| Version | 0.1.0, unchanged | `info.json`, zip name, `changelog.txt`, tag `v0.1.0` |
| Mod changelog | `docs/release/changelog.txt` in the Factorio format; copy it to `mods/factorio-rts/changelog.txt` unless it is already there | in-game mod browser and the portal's Changelog tab |
| In-game description | the `[mod-description]` lines in `mods/factorio-rts/locale/en/factorio-rts.cfg` and `locale/ru/factorio-rts.cfg` still describe the Skirmish-only game, and they override `info.json` in the game's mod list | the in-game Mods screen |
| AI-development note | README, Development section: "Most of the code, tests and documents were written by AI coding agents (Claude Code) under the owner's direction" | README |
| Roadmap | six candidate directions in the README | README |
| Screenshot captions | written from the file names; check them against the final shots | README gallery, portal description |

If the repository name changes, replace `Kealman/factorio-rts` everywhere:

```sh
grep -rl 'Kealman/factorio-rts' README.md CONTRIBUTING.md CHANGELOG.md docs mods/factorio-rts/info.json
```

## 2. Privacy: decide before the first push

Once the repository is public, its history is public for good, even if it is deleted later.

1. **Commit identities.** The history has 52 commits by "Evgeniy Ivanov <kealman91@gmail.com>" and 120 by "Kealman <me@eivanov.net>". Pushing publishes both names and addresses. To keep them, do nothing. To replace them, rewrite the history before the first push (every commit hash and the milestone tags change):

   ```sh
   brew install git-filter-repo
   printf 'Kealman <ID+Kealman@users.noreply.github.com> Evgeniy Ivanov <kealman91@gmail.com>\nKealman <ID+Kealman@users.noreply.github.com> Kealman <me@eivanov.net>\n' > /tmp/mailmap
   git filter-repo --mailmap /tmp/mailmap --force   # ID: your numeric GitHub user id (Settings > Emails shows the noreply address)
   git config user.email 'ID+Kealman@users.noreply.github.com'   # future commits
   ```

2. **A log with a Steam ID.** `spikes/camera-input/codex-run.log` (a Phase 0 test log) contains a Steam ID (SteamID64), the macOS home path with the user name and the machine's hardware. Remove it from the tree, and from the history as well if the Steam ID must not be public:

   ```sh
   git rm spikes/camera-input/codex-run.log && git commit -m "Remove a local test log"
   git filter-repo --path spikes/camera-input/codex-run.log --invert-paths --force   # also purges the history
   ```

   `spikes/camera-input/TEST-PROTOCOL.md` mentions the home-relative project path (`~/Projects/home/games/factorio_rts`), which is harmless.

3. Nothing else was found: no tokens, passwords or keys in any tracked file or in the history (`tools/server-settings.json` has empty credential fields on purpose), and no file in the history is larger than 2 MB.

## 3. Pre-flight

1. The media files are committed: `docs/media/01-lobby.png` to `docs/media/15-city-panel.png` and `mods/factorio-rts/thumbnail.png` (144×144).
2. The working tree is clean, and you are on `main`:

   ```sh
   git status --short && git branch --show-current
   ```

3. The Skirmish smoke test passes (65/65, 0 errors):

   ```sh
   tools/autotest-run.sh smoke '{opponents = 1, difficulty = "normal", size = "small", enemy_brain = "waves"}' 240
   ```

4. Build the archive. It must print no warning:

   ```sh
   tools/package.sh
   # package: .../build/release/factorio-rts_0.1.0.zip
   # package: <n> files, <bytes> bytes (<size> MB), Factorio 2.1
   ```

5. Test the archive as a player gets it: remove the development copy, install the zip and start a game.

   ```sh
   tools/uninstall.sh
   cp build/release/factorio-rts_0.1.0.zip ~/Library/Application\ Support/factorio/mods/
   ```

   Start Factorio, check that **Mods** lists Factorio RTS 0.1.0 with its thumbnail, description and changelog, start a new Freeplay game and see the lobby. Afterwards, delete the zip from the mods folder and run `tools/install.sh` to go back to the development copy.

## 4. GitHub

1. Make sure the GitHub CLI acts as Kealman (this machine is logged in to two accounts):

   ```sh
   gh auth switch --user Kealman && gh auth status
   ```

2. Create the public repository and push `main`:

   ```sh
   gh repo create Kealman/factorio-rts --public --source=. --remote=origin --push \
     --description "Factorio 2.1 mod: a StarCraft-style RTS with a real Factorio production economy, grown into a Rise of Nations-style mini-state with cities, rails, trade, diplomacy and war on worlds up to 4096 tiles." \
     --homepage "https://mods.factorio.com/mod/factorio-rts"
   ```

3. Push the milestone tags (`m1-ready`, `m2-wave-a`, `m2-ready`, `m3-wave-a`, `m3-ready`):

   ```sh
   git push origin --tags
   ```

4. Add the topics:

   ```sh
   gh repo edit Kealman/factorio-rts --add-topic factorio,factorio-mod,factorio-mods,lua,rts,real-time-strategy,strategy-game,grand-strategy,game-ai,procedural-generation,logistics,trains
   ```

5. Tag the release and publish it with the zip:

   ```sh
   git tag -a v0.1.0 -m "Factorio RTS 0.1.0"
   git push origin v0.1.0
   gh release create v0.1.0 build/release/factorio-rts_0.1.0.zip --repo Kealman/factorio-rts \
     --title "Factorio RTS 0.1.0" --notes-file docs/release/github-release.md
   ```

6. Open https://github.com/Kealman/factorio-rts and check that the README renders with its gallery, that Issues are enabled (Settings > General > Features), and that the release lists `factorio-rts_0.1.0.zip`.

## 5. Factorio Mod Portal

1. Sign in at https://mods.factorio.com with your Factorio account. The portal shows the uploader's account name as the author, whatever `info.json` says.
2. Open the upload page (top menu, *Upload mod*; https://mods.factorio.com/create at the time of writing) and upload `build/release/factorio-rts_0.1.0.zip`. The portal reads the name, version, title, dependencies, thumbnail and changelog from the zip, so the file name must stay `factorio-rts_0.1.0.zip`.
3. On the mod's edit page (https://mods.factorio.com/mod/factorio-rts/edit), fill in from [mod-portal.md](mod-portal.md):
   - **Summary:** the Summary block.
   - **Description:** the Long description block.
   - **Category:** Overhaul. **Tags:** Combat, Enemies, Logistics, Logistic network, Trains, Manufacturing, Environment.
   - **License:** MIT. **Source URL:** https://github.com/Kealman/factorio-rts.
   - **FAQ:** the FAQ block.
4. **Gallery:** upload the 15 screenshots from `docs/media/` in file-name order (`01-lobby.png` first). The description's "Screenshots (gallery order)" list matches that order.
5. **Thumbnail:** check that the portal shows `thumbnail.png`; if it does not, upload `mods/factorio-rts/thumbnail.png` on the edit page.
6. Open https://mods.factorio.com/mod/factorio-rts and check the Information, Changelog and FAQ tabs.

## 6. Announce

1. Post on r/factorio: the title and body from [announce.md](announce.md), with 3 or 4 screenshots.
2. Post in the Mods subforum of https://forums.factorio.com: the BBCode title and body from [announce.md](announce.md).
3. Add the forum thread's link to the portal's description or README if you want a discussion page besides GitHub Issues.

## 7. Later releases

1. Raise `version` in `mods/factorio-rts/info.json`, add a section on top of `mods/factorio-rts/changelog.txt` (99 dashes, then `Version: x.y.z`) and of `CHANGELOG.md`.
2. Commit, then `tools/package.sh`.
3. Tag `vX.Y.Z`, push it, and `gh release create vX.Y.Z build/release/factorio-rts_X.Y.Z.zip --title "Factorio RTS X.Y.Z" --notes "..."`.
4. Upload the new zip on the portal: the mod's page, *Downloads* tab, upload a new version (or the edit page's upload field).
