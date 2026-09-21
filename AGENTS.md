# AGENTS.md — setting up Armada (instructions for coding agents)

You are setting up **Armada**, a macOS menu-bar app: a Spotlight-style ⌘ Space panel that finds files, apps and
settings from natural-language descriptions. Ranking is done by
**Codiv's OpenJev** model through the Jev-compatible `POST https://api.codiv.ai/v1/systemone` API. There is no
server to run; the app talks to Codiv directly with the user's own free key.

Follow the steps in order. Every step has a verification command. Do not skip the human-only steps at the end —
they are macOS permission dialogs that no CLI can grant.

## TL;DR (agent runbook)

```bash
# 1. Human: get a free key at https://codiv.ai/signup → Dashboard → Create key (starts with sk-codiv-, shown once).
# 2. From the unzipped release folder:
CODIV_API_KEY=sk-codiv-... ./install.sh        # prebuilt app: ~15 s, no Xcode. Falls back to a source build if Xcode exists.
"/Applications/Armada.app/Contents/MacOS/Armada" --doctor   # every line must read OK; FAIL lines print the fix
# 3. Human: in the "Set up Armada" window that opened, click "Open Full Disk Access…" and turn Armada on
#    The row turns green live; the agent can re-run --doctor.
# 4. Press ⌘ Space and type. Done.
```

Nothing in the install can break the Mac: no sudo, no system files, only `/Applications/Armada.app`, a 600-mode key
file under `~/Library/Application Support/Armada/`, a login item, and Spotlight's ⌘ Space shortcut preference (turned
off while Jev runs, restored when it quits). Declining a permission only reduces what Jev can see; it never blocks the app.

## 0. Requirements (check first)

```bash
sw_vers -productVersion          # needs 15.0 or newer (built and tested on macOS 26), Apple silicon or Intel
```

Only if you build from source (the prebuilt `Armada.app` in the release folder needs none of this):

```bash
xcode-select -p                  # must point into a full Xcode.app, not just CommandLineTools
xcodebuild -version              # Xcode 16 or newer (Swift 5.10+/6)
command -v xcodegen              # optional: Armada.xcodeproj is checked in
```

If `xcode-select -p` prints `/Library/Developer/CommandLineTools`, the human must install Xcode from the App Store,
then run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` and `sudo xcodebuild -license accept`.
Tell them; you cannot do this for them.

## 1. Get a free Codiv API key (human step, ~2 minutes)

Codiv is a free public experiment: **100M input tokens per account, no credit card**. One Armada search costs
roughly 15–30k tokens, so that is several thousand searches.

Ask the human to:

1. Open <https://codiv.ai/signup> and sign up with Google, GitHub or email (verify the email if asked —
   unverified accounts get `403 permission_error`).
2. Open <https://codiv.ai/dashboard> → **Create key**. The key looks like `sk-codiv-…` and is **shown only once**.
3. Paste it to you, or export it in the shell you'll run the setup from: `export CODIV_API_KEY=sk-codiv-...`

Never commit the key. The app stores it in `~/Library/Application Support/Armada/api-key` (mode 600), not in the
repo and not in the Keychain (ad-hoc-signed rebuilds would trigger Keychain prompts).

Sanity-check a key without the app:

```bash
curl -s https://api.codiv.ai/v1/systemone -H "Authorization: Bearer $CODIV_API_KEY" -H "Content-Type: application/json" \
  -H "User-Agent: setup-check" \
  -d '{"model":"openjev-latest","state":"hello there","questions":{"q":{"type":"noul","instructions":"Is this a greeting?"}}}'
# expect: {"model":"openjev-0.1","answers":{"q":{"type":"noul","noul":0.9...}},"usage":{...}}
```

(Send *some* User-Agent header — Codiv returns 403 to Python's default `Python-urllib` UA.)

## 2. Install — one command

```bash
CODIV_API_KEY=sk-codiv-... ./install.sh          # release folder: prebuilt app (fast) or source build (if Xcode)
# or, inside the source tree:
CODIV_API_KEY=sk-codiv-... ./scripts/setup.sh    # always builds from source
```

`install.sh` copies the app to `/Applications`, strips the download quarantine flag (the app is signed with a developer
certificate but not notarized, so Gatekeeper would otherwise refuse it), stores the key, launches the app and prints
`--doctor`. If no key is given and a terminal is attached it asks for one; otherwise the app's checklist asks.

What it does: regenerates the Xcode project if `xcodegen` is present, builds Release signed with the first
"Apple Development"/"Developer ID" identity in the login keychain (falls back to ad-hoc `-`; no developer account needed,
but a real identity keeps the code identity stable across rebuilds so macOS remembers the permission grants), copies the
app to `/Applications/Armada.app`, stores the key, launches the app, registers it as a login item, and prints the
remaining human steps.

Manual equivalent if you prefer explicit steps:

```bash
xcodegen generate            # optional
xcodebuild -project Armada.xcodeproj -scheme Armada -configuration Release -derivedDataPath build \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build | grep -E "error:|BUILD"
rm -rf "/Applications/Armada.app" && cp -R "build/Build/Products/Release/Armada.app" /Applications/
BIN="/Applications/Armada.app/Contents/MacOS/Armada"
"$BIN" --set-key "$CODIV_API_KEY"
"$BIN" --ping                # → "Codiv reachable"
open "/Applications/Armada.app"
```

## 3. Verify (headless, no UI needed)

```bash
BIN="/Applications/Armada.app/Contents/MacOS/Armada"
"$BIN" --search "the most recent pdf in my downloads" --verbose     # prints each Jev routing step and the ranked list
"$BIN" --search "resume" --json | head -40
"$BIN" --login-status        # "launch at login: enabled"
pgrep -x "Armada"        # the agent process is running
```

`"$BIN" --doctor` prints one OK/FAIL line per setup item with the fix. `"$BIN" --apps claud` lists app-launcher
matches (Claude first), `"$BIN" --calc "15% of 80"` prints 12, `"$BIN" --sites youtube` lists website rows read
from the browsers' history/bookmarks (youtube.com first; Safari's store only appears once Full Disk Access is on).
A healthy search prints something like `done: 30 results, 7 requests, 18000 tokens, 1900 ms`. If the first search
takes very long or hangs, macOS is showing a folder-access dialog (Desktop/Documents/Downloads) — the human must
click Allow.

`"$BIN" --finder-results "syllabus for the lab course" --root ~/Downloads` does what ⏎ in a Finder search field
does (ranked links folder, shown in the front Finder window); `"$BIN" --ax-probe` prints what the Finder bridge sees
(front app, focused field, folder) — both need Accessibility, which a terminal-launched CLI inherits from the terminal.

To open the real UI from a script: `open "armada://search?q=old%20resume"` (URL scheme; `armada://show`,
`armada://hide`, `armada://settings`, `armada://setup` / `armada://setup?close`, and the debug hook
`armada://finder-search?q=pdf&root=~/Downloads` also exist).

## 4. Human-only steps (system permission dialogs)

The app opens a **"Set up Armada" checklist window** on first launch (menu bar › Setup checklist… later) with one
row per step and a live green check. `--doctor` reports the same rows from the CLI. Tell the human exactly this:

1. **Full Disk Access** — on first launch the app shows one dialog: "Open Full Disk Access Settings" → toggle
   **Armada** on (if it isn't listed, click "+" and pick /Applications/Armada.app — a Finder window with the app
   selected opens so it can be dragged in). This single switch replaces the separate Desktop/Documents/Downloads/iCloud/
   external-disk prompts. Without it, those per-folder prompts appear together right after launch; allow them all.
   The app reminds via the menu-bar icon and Settings › Files until FDA is granted.
2. **Accessibility** (for the Finder / Open-panel search only) — the app asks once on first launch; the human turns
   **Armada** on under System Settings › Privacy & Security › Accessibility (the checklist has an "Open Settings"
   button). Without it everything else works and Finder simply searches the standard way. The app also sets Finder's
   "When performing a search" preference to *Search the Current Folder* so the standard results are scoped like Armada's.
3. **⌘ Space** — nothing to do: while Jev owns ⌘ Space it turns Spotlight's own ⌘ Space shortcut off (symbolic hotkey 64)
   and turns it back on when Jev quits or the user picks another key in Settings. Spotlight itself keeps working from
   the menu bar. Settings › ⌘ Space has explicit "turn off / give back" buttons. ⌥ Space opens Jev too.
4. Gatekeeper: the app is built locally, so no "unidentified developer" dialog. If you instead copied a prebuilt
   `Armada.app` from a zip, run `xattr -dr com.apple.quarantine "/Applications/Armada.app"` first.

## 5. Run the grounded evaluation (optional but recommended)

The author's grounded sets (70 file, 22 date, 50 launcher cases) name private files and are **not shipped**;
`Tests/eval_example.json` shows the format. To evaluate on a new machine, write 20–70 cases the same way: pick a real
file first, then describe it by content / purpose / date / partial name **without** using its exact name, and run:

```bash
python3 Tests/run_eval.py --set Tests/eval_example.json        # prints PASS/ok/weak/MISS per case + summary
python3 Tests/run_eval.py --set my_cases.json --repeat 2
```

Case format: `{"style":"date","query":"the earliest walkout summary","targets":["Downloads/Walkout_Summary_20260804.pdf"]}`;
`targets_glob`, `targets_regex` (relative to `~`), absolute targets (`/Applications/Claude.app`), `"calc":"12"` and
`"same_name_ok": true` are also accepted. Reference numbers on
the author's Mac (70 cases): 93 % top-1, 97 % top-3, median 2.1 s, ~20k tokens/search; date cases (22): 86 % top-1.

## 5b. Developer loop

```bash
make test        # 12 XCTest unit tests (calculator, query words, settings/action matching, merge order, website matching)
make install     # build (signed with your identity if present) + copy to /Applications + launch
make eval        # the three grounded eval sets through the shipped CLI
make package     # ../Armada-package.zip without build artefacts
```

## 5c. Spotlight choreography (what the panel reproduces)

Measured from a 120 fps `screencapture -V` recording of macOS 26 Spotlight over a white window, frame by frame
(`Sources/App/Liquid.swift` holds the constants):

* Capsule 640×56, radius 28, centred, top 12.7 % down the screen (or Spotlight's own remembered spot from
  `com.apple.Spotlight lastWindowPosition`); results panel 640 wide, same radius, max 469 pt tall (6½ rows).
* Rows 56 pt (icon 36, title 17 pt, subtitle 13 pt), chips row 46 pt with 24 pt capsules, selection = white 13 %.
* Open: on screen within ~30 ms (one faint frame, then full). Close: 85 ms, alpha (1 − t/T)^1.5 with a 4 % zoom.
* Results appear: height springs from 70 % of the way with velocity (ω 26 rad/s, ζ 0.8, ~4 pt overshoot);
  rows fade in over ~100 ms. ⎋: critically damped collapse (ω 31) to the capsule.
* Spotlight also pinches four mode buttons off the capsule with a liquid split; that is intentionally *not* reproduced.
* Text selection in the field is Spotlight's #6885ad on white; the field is non-vibrant (vibrant text views composite
  the selection plus-lighter through the blur and turn it cyan).

## 6. Project map

```
project.yml                 xcodegen spec (bundle id ai.codiv.Armada, LSUIElement, URL scheme armada://)
Armada.xcodeproj         generated; safe to regenerate with `xcodegen generate`
Sources/App/main.swift             entry: CLI mode (--search/--set-key/--ping/--doctor/--finder-results/--ax-probe/…) or the app
Sources/App/AppDelegate.swift      hotkey, panel show/hide via the choreographer, login item, URL scheme, onboarding
Sources/App/GlassPanel.swift       borderless NSPanel: hudWindow material under a per-frame mask + specular rim; non-vibrant field editor
Sources/App/HotKey.swift           Carbon RegisterEventHotKey wrapper; Spotlight-shortcut detection
Sources/Core/SemanticSearch.swift  the engine: name channel → Blink-style walk (choice per folder, mass flow) → rerank
Sources/Core/Spotlight.swift       mdfind name/content channels + local scan for index gaps
Sources/Core/CodivClient.swift     /v1/systemone client, retries, ordered JSON criteria
Sources/Core/Preview.swift         220-char previews (Spotlight text index, PDFKit); secret-name guard
Sources/Core/FileSystem.swift      cached listings, ignore rules, display paths, dates with relative age
Sources/Core/Settings.swift        UserDefaults settings; key file
Sources/Core/AppIndex.swift        Spotlight-style app launcher index (prefix/initials/alias matching) + safe calculator
Sources/Core/SystemIndex.swift     System Settings panes (verified x-apple.systempreferences ids), actions, web search
Sources/Core/WebIndex.swift        websites from Safari/Chromium/Firefox history + bookmarks (sqlite immutable reads, favicons)
Sources/App/Liquid.swift           Spotlight's measured geometry/timing; window choreographer (display link, springs, mask)
Sources/App/FinderIntegration.swift Finder / Open-panel bridge (AX focus + ⏎ tap → scoped search → ranked links folder)
Sources/Core/Usage.swift           os.Logger categories, frecency store (opens → boost + Recents), Codiv usage meter
Sources/Core/Permissions.swift     Full Disk Access / Accessibility settings deep links, FDA probe
Tests/Unit/ArmadaTests.swift    XCTest target (pure logic; no network)
Makefile                           build / install / test / eval / package
Sources/UI/*                       SearchController, SpotlightViews (panel), SettingsView
Tests/run_eval.py, eval_example.json  grounded evaluation harness (the author's private sets are not shipped)
scripts/setup.sh                   the one-command install; scripts/make_icon.swift; scripts/winshot.swift (window capture)
```

## 7. Things that bit us (read before debugging)

* **Keychain**: don't move the key to the Keychain. `SecItemCopyMatching` blocks forever in CLI mode waiting for a
  GUI prompt after each rebuild (signature changed).
* **`mdfind` via `Process`**: read stdout to EOF *before* `waitUntilExit`, otherwise a result set over 64 KB
  dead-locks the pipe. Already handled in `Spotlight.mdfind`.
* **Spotlight index gaps**: some files never show up in `mdfind` (e.g. freshly written `.sql`). The local scan
  channel covers Desktop/Documents/Downloads/iCloud three levels deep; the walk covers the rest.
* **`Settings` name clash**: the app's `Settings` class shadows SwiftUI's `Settings` scene → use `SwiftUI.Settings`.
* **CLI mode must pump the main run loop** (`RunLoop.main.run(until:)`), not block on a semaphore — the engine
  reports progress on the main actor.
* Codiv returns 403 for Python's default User-Agent; URLSession's default is fine.
* **Vibrancy bleaches the text selection**: an NSTextField inside an NSVisualEffectView draws its selection
  plus-lighter through the blur (cyan). The panel installs its own non-vibrant field editor with Spotlight's colours.
* **Finder in search mode has no target**: `target of front Finder window` errors once the window says "Searching …",
  so the bridge remembers each window's folder before the search starts and can read the scope button as a fallback.
  Finder windows don't expose `AXDocument`; Open panels expose `AXURL` on their file rows, which gives the folder.
* **`log` is a zsh builtin**: use `/usr/bin/log stream --info --predicate 'subsystem == "ai.codiv.Armada"'`.
* **Accessibility trust is per launch context**: a CLI run from a terminal inherits the terminal's trust; the app
  launched via `open` needs its own entry in Privacy & Security › Accessibility.
* **Panel dismissal**: the panel is a non-activating NSPanel but the app *is* activated on show; a hidden SwiftUI
  helper window can briefly take key status, so `GlassPanel.resignKey` reclaims it and dismissal is driven by
  `NSApplication.didResignActiveNotification` only. Never resize the panel with `setFrame(_:display:animate:)` — it
  blocks the main thread and eats keystrokes; use `animator()`.
* **Apps only appear in the Full Disk Access list after they touched protected data** — `Permissions.hasFullDiskAccess`
  deliberately probes several protected paths at launch for that reason.
* Choice questions accept at most 128 options; big flat folders are shortlisted to the frontier size (45–90).

## 8. Privacy notes to relay to the user

File names, paths (relative to `~`), sizes, dates and — if "Send short text previews" is on (default) — the first
220 characters of candidate files are sent to Codiv. Files whose names suggest secrets (`.env`, keys, passwords,
recovery codes, …) never get previews. `~/Library` (except iCloud Drive), caches, `node_modules`, `.git` and build
folders are never searched. Nothing else leaves the machine.
