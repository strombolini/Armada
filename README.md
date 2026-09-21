# Armada

Describe the file you want; Jev finds it. A Spotlight-style ⌘ Space search for macOS whose ranking is done by
[Codiv](https://codiv.ai)'s OpenJev System One model (Jev-compatible API) instead of string matching.

```
⌘ Space   →   "the lease for my apartment"   →   ~/Documents/Personal/Lease/lease_123_main_st.pdf   99%
```

## What it does

* **⌘ Space panel** — looks and behaves like macOS 26 Spotlight: big search field, filter chips, result rows with
  icon · kind · size · date · folder, ↑/↓ ⏎ to open, ⌘⏎ to show in Finder, ⌘Y Quick Look, ⌘C to copy the file, ⎋ to
  dismiss. The last query stays selected so typing replaces it. The panel remembers where you drag it.
* **Apps, settings, actions, math — like Spotlight** — "claud" puts Claude (with its icon) first and ⏎ launches it;
  prefix, word-prefix, initials ("vsc"), compact names ("flyjuggle") and aliases ("ppt", "settings") all work.
  "bluetooth" / "dark mode" / "keyboard shortcuts" open the right System Settings pane; "lock screen", "empty trash",
  "sleep", "eject", "restart" are one-row actions (destructive ones confirm); "15% of 80" shows 12; the last row
  searches the web. ⌘1–⌘9 open the nth result. An empty query shows your Recents.
* **Websites — like Spotlight, for the browser you use** — "youtube" shows youtube.com (with its favicon) above the
  files, "vice documentary" finds the page you visited. Read locally from Safari (needs Full Disk Access), Chrome,
  Brave, Edge, Arc, Vivaldi and Firefox history + bookmarks; never sent to Codiv. Toggle in Settings › Search locations.
* **Scope** — home folder, iCloud Drive, and Dropbox / Google Drive / OneDrive (~/Library/CloudStorage) by default;
  external and network volumes optional. `~/Library`, caches, `node_modules`, `.git`, build folders are never searched.
* **Learns from you** — things you open through Jev rank a little higher next time (decays over a month).
* **Natural language, names, dates** — "old resume" vs "recent resume" give different files; "resume" ignores dates.
  A bare file name (or any word of it) surfaces instantly via Spotlight, with or without Codiv.
* **Always running** — menu-bar agent, no Dock icon, launches at login. ⌘Q only hides the panel; quit from the menu-bar icon.
* **Inside Finder and Open panels, using their own UI** — type into Finder's search field (or an app's Open panel
  search field) and press ⏎: the same engine runs *scoped to the folder that window shows* and the window switches
  to a plain Finder list of every file the standard search would show, ranked by Jev (Back returns to the folder).
  Until ⏎, and whenever Codiv is unreachable, the standard search is what you get. Needs Accessibility.
* **Looks and moves like Spotlight** — the capsule, the results panel, rows, chips, fonts and every animation
  (open, results springing open, ⎋ collapsing, close fade + zoom) were measured frame by frame from a 120 fps
  recording of macOS 26's Spotlight and reproduced (see AGENTS.md § Spotlight choreography). The one deliberate
  difference is the search icon filling left→right while Jev works.
* **Offline** — if Codiv can't be reached, ⌘ Space still opens with name matches (or, optionally, the real Finder).

## How the search works (Blink-style, on Codiv)

Heavily inspired by [ellipsis-dev/blink](https://github.com/ellipsis-dev/blink): at every directory level one `choice`
question asks OpenJev which entry most likely *is* — or *contains* — what you described; probability mass flows down the
tree like Blink's walkers. On top of that:

1. **Spotlight name channel** (instant): `mdfind -name` per query word, weighted by how rare each word is, plus a
   shallow local scan of Desktop/Documents/Downloads/iCloud that covers files Spotlight hasn't indexed.
2. **Walk**: the home folder and the standard user folders are asked in one parallel round; big flat folders are
   shortlisted (name hits, subfolders, type-matching and newest files); small subfolders are flattened so one request
   routes across several levels; each folder option carries a peek at its children. Every option carries its modified
   (and created) date with a relative age, and the instructions say to use dates only when the query mentions time.
3. **Content channel**: Spotlight full-text hits for distinctive words, IDF-weighted, preferring short shallow files
   (a note that *is* about the words) over deep source trees.
4. **Rerank**: one final `choice` over ≤60 candidates with a 220-character text preview each (from Spotlight's text
   index / PDFKit), which fixes the order. An interim rerank runs concurrently with the second walk round so the ordered
   list shows ~1 s earlier.

Typical search: 6–9 Codiv requests, ~12–20k input tokens, 1.5–2.5 s cold (faster warm — directory listings, previews
and whole results are cached). Name-shaped queries ("resume.pdf", "IMG_4021") use a smaller budget; the walk only
starts after a real pause in typing (420 ms), while apps/settings/calculator answer within ~60 ms without Codiv.
Settings shows a live meter: tokens this month, per search, and the share of the free 100M quota used.

## Setup

**Install (release folder):** get a free key at <https://codiv.ai/signup> (Dashboard → Create key), then
`CODIV_API_KEY=sk-codiv-... ./install.sh`. The app opens a checklist for the two macOS permissions (Full Disk Access,
Accessibility). **Coding agents: read [AGENTS.md](AGENTS.md).**

1. Build: `xcodegen generate && xcodebuild -project Armada.xcodeproj -scheme Armada -configuration Release -derivedDataPath build CODE_SIGN_IDENTITY=- build`
   (the built app is `build/Build/Products/Release/Armada.app`; copy it to `/Applications`).
2. API key: paste it in Settings (menu bar › Settings…), or `"/Applications/Armada.app/Contents/MacOS/Armada" --set-key sk-codiv-…`.
   It is stored in `~/Library/Application Support/Armada/api-key` (mode 600).
3. **⌘ Space** is Armada's alone: while Jev owns ⌘ Space it switches Spotlight's own shortcut off (and restores it when
   you quit Jev or pick another key in Settings). ⌥ Space also opens Armada.
4. **Full Disk Access** (one switch instead of a prompt per folder): the app asks on first launch → System Settings ›
   Privacy & Security › Full Disk Access → turn on Armada (click “+” if it isn't listed).
5. **Accessibility** (only for the Finder / Open-panel search): System Settings › Privacy & Security › Accessibility →
   turn on Armada. Without it, ⌘ Space works fully and Finder just searches the standard way.

## Headless CLI (used by the tests)

```
"/Applications/Armada.app/Contents/MacOS/Armada" --search "the ikea receipt" [--root PATH] [--fast|--balanced|--thorough] [--json] [--verbose]
"/Applications/Armada.app/Contents/MacOS/Armada" --ping | --doctor | --set-key KEY | --apps claud | --sites youtube | --calc "15% of 80"
"/Applications/Armada.app/Contents/MacOS/Armada" --finder-results "syllabus for the lab course" --root ~/Downloads   # what ⏎ in Finder does
"/Applications/Armada.app/Contents/MacOS/Armada" --ax-probe        # what the Finder bridge sees (front app, focused field, folder)
```

## Evaluation

The engine was tuned against grounded sets built on the author's own Mac (the target file was picked first, then
described in natural language without telling the engine the name — by content, purpose, date, partial name, or as a
folder): 70 file cases, 22 date-discrimination cases ("walkout summary from august 12", "old resume" vs "recent
resume") and 50 app-launcher/calculator cases. Last run: files 93 % top-1 / 97 % top-3, dates 86 % top-1, launcher
100 % top-1. Those sets name private files, so they are not in this repository; `Tests/eval_example.json` shows the
format and `python3 Tests/run_eval.py --set …` runs any set through the shipped CLI, reporting top-1/3/10, MRR,
latency and tokens per style. Build your own from your files — AGENTS.md § 5 says how.

Privacy: file names, sizes, dates and (optionally) 220-character previews of candidate files are sent to Codiv. Files
whose names suggest secrets (.env, keys, passwords, recovery codes…) never get previews; `~/Library` (except iCloud
Drive), caches, `node_modules`, `.git`, build folders etc. are never searched.
