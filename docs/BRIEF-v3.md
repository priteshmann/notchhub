# NotchHub v3 — verify every module against rendered output + GitHub-style focus heatmap

Binding. Builds on v2 (docs/BRIEF-v2.md). Same constraints (macOS 27 host, Swift 6.4, CLT only).

## 1. Debug driver (so a non-human can test the real app)
Gated by `UserDefaults` key `debugDriver` (bool) in suite `com.pritesh.notchhub`. OFF by default; when off
NOTHING in this section runs (no timer, no file reads). When on, the app polls
`~/Library/Logs/notchhub-cmd.txt` every 0.5 s, executes each line, then truncates the file. Commands:
- `expand` / `collapse` / `toggle`
- `tab <moduleId>` (select a tab; expands if needed)
- `snapshot <name>` → renders the hosting view with `cacheDisplay` to `~/Library/Logs/notchhub-<name>.png`
  AND appends `snapshot <name> host=<frame> window=<frame>` to `~/Library/Logs/NotchHub.log`
- `focus start` / `focus pause` / `focus skip` / `focus reset`
- `caffeine on` / `caffeine off`
- `transient <text>` (push a transient so the collapsed overlay can be snapshotted)
- `clip select <index>` (simulate clicking a clipboard row = copy back)
- `notes set <text>` (replace the scratchpad text through the same path the editor uses)
Each command writes `cmd <line> ok|err <reason>` to the log. Never ship with the flag defaulting on.

## 2. GitHub-style focus heatmap (replaces the 7-day chart in the Focus tab) — COPY GITHUB EXACTLY
The owner wants the GitHub contribution graph, as-is, in dark mode: a trailing YEAR that rolls forward
(the rightmost column is the current week; month labels follow automatically, so "Oct" is the last label
now and "Nov" appears as November starts).
- Grid: last 52 weeks (columns, oldest left) × 7 days (rows, Sunday→Saturday top→bottom like GitHub),
  square 7 pt, gap 1.5 pt, corner radius 1.5 pt. Weeks start on Sunday (GitHub convention).
- Palette (GitHub dark): 0 min → `#161B22` with a 1 px `#FFFFFF0D` border; 1–24 → `#0E4429`;
  25–49 → `#006D32`; 50–99 → `#26A641`; ≥100 → `#39D353`.
- Month labels across the top (8 pt, `#8B949E`), placed above the first column whose first day falls in
  that month; skip a label when two would overlap. Row labels `Mon`/`Wed`/`Fri` on the left (8 pt, same grey).
- Legend bottom-right: `Less` ▢▢▢▢▢ `More` (the five colours, 7 pt squares). Bottom-left: the total,
  "N h M min · S sessions in the last year".
- Today's square: 1 pt white outline. While a FOCUS session is running it pulses (opacity 0.6↔1.0,
  1.2 s ease-in-out, repeating) — "it lights up".
- Future days in the current week are not drawn (like GitHub).
- `.help("Oct 1 · 50 min · 2 sessions")` on each square.
- Width: the Focus tab makes the panel 480 pt wide (the panel width is per selected tab; other tabs stay
  400). The grid is 52 × 8.5 = 442 pt plus 26 pt of row labels; use 6 pt horizontal padding in the grid
  area. Panel height for Focus grows to fit (timer block + buttons + today row + ~95 pt grid + legend).
- Data: completed focus sessions from the existing history. Pure helper
  `FocusHeatmap.cells(history:today:calendar:)` returning 52×7 cells `{date, minutes, sessions, level, isToday, isFuture}`
  + month-label positions, with Swift Testing tests: level thresholds, Sunday-first row mapping, 52-week window,
  today index, future-day masking, a month-label dedupe case.

## 3. Verify every module by DRIVING THE REAL APP (not offscreen renders)
Enable the flag with `defaults write com.pritesh.notchhub debugDriver -bool true`, `./build.sh --install`,
then write commands to the cmd file and READ EACH PNG WITH THE IMAGE READER before concluding. Required checks:
- Focus: `focus start` → wait 3 s → `snapshot focus-running` (expanded, shows countdown + heatmap with today pulsing) → `collapse` → `snapshot focus-collapsed` (wings: time left / progress right) → `focus pause`.
- Tab strip: the selected tab must show a BLACK icon on the white pill (v2 snapshot showed a blank white pill — fix if real).
- Clipboard: `pbcopy` three different strings 1 s apart → `tab clipboard` → `snapshot clip` (3 rows, newest first) → `pbcopy` the same string twice → still one new row. `clip select 1` → `pbpaste` prints that row's text.
- Notes: `notes set hello world` → `snapshot notes` → `defaults read com.pritesh.notchhub notes.text` (or whatever the key is) contains it within 1 s.
- Battery: header text matches `pmset -g batt` (percent; charging/remaining state).
- Caffeine: `caffeine on` → `pmset -g assertions | grep -i notchhub` shows PreventUserIdleDisplaySleep → `caffeine off` → gone. Header cup filled vs outlined in snapshots.
- Now Playing: with NO player running (`pgrep -x Music; pgrep -x Spotify` empty) → `tab nowplaying` → `snapshot np-idle` shows the "nothing playing" state, and afterwards `pgrep` is STILL empty (the module must never launch a player). Do NOT start playback (no sound on the owner's machine).
- Calendar + Mirror: `tab calendar` / `tab mirror` → snapshot. If access is not granted, the inline "Allow in System Settings" message must render; do NOT trigger or click any permission dialog beyond what the first open shows.
- Shelf: `tab shelf` → snapshot of the empty state with the drop hint. (Drag cannot be automated; keep the unit test.)
- Transient: `transient Charging · 64%` → `collapse` → `snapshot transient` within 1 s (slide-in overlay visible).
- Settings window: open via the driver? No — just confirm `SettingsWindow` builds; leave the window untested.
Fix every defect you find, re-run that check, and keep the PNGs (list their paths in the report).

## 4. Definition of done
- `swift build` zero warnings beyond the 2 known linker ones; `swift test` green (v1 + v2 + heatmap tests).
- Every check in §3 either PASSED with a PNG path, or is listed as FAILED/UNVERIFIABLE with the exact reason.
- Finish with `defaults delete com.pritesh.notchhub debugDriver`, delete the cmd file, `./build.sh --install` once more so the
  owner is running the final build with the driver off. Update README (heatmap; one line on the debug driver).
