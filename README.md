# NotchHub

A hub that lives in the MacBook notch: Pomodoro focus timer, Now Playing, a file Shelf, clipboard
history, a scratchpad, battery, calendar, Caffeine and a camera mirror. It floats above every window
and every Space (fullscreen apps included) on the built-in (notched) screen. v2 of NotchPomodoro.

## Install on another Mac (for friends)

Two ways. Both need macOS 14 or newer.

**A. Download the app (no tools needed)**
1. Download `NotchHub.zip` from the latest GitHub release and unzip it.
2. Move `NotchHub.app` into your `Applications` folder.
3. First launch: macOS will say the app is from an unidentified developer because it is not notarized.
   On macOS 15 or newer: try to open it once, then go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.
   On macOS 14: right-click the app → **Open** → **Open**.
4. The app lives in the notch and in the menu bar (no Dock icon). To start it at login, open the gear → General → Launch at login.

**B. Build it yourself (safest, no Gatekeeper step)**
```
xcode-select --install          # once, if you don't have Command Line Tools
git clone https://github.com/priteshmann/notchhub.git
cd notchhub && ./build.sh --install
```

Hotkeys: ⌃⌥P start/pause the pomodoro, ⌃⌥N open/close the panel.

## Build (Command Line Tools only, no Xcode)

```sh
./build.sh            # swift build -c release, assemble dist/NotchHub.app, ad-hoc sign
./build.sh --install  # also copy to ~/Applications, quit NotchPomodoro (v1) if running, launch NotchHub
swift test            # Swift Testing under CLT (XCTest when Xcode is installed)
```

If the very first `swift test` after a clean build reports "plugin for module 'TestingMacros' not
found", run it again: that is a Command Line Tools build race, not a test failure.

Upgrading from v1: `./build.sh --install` quits NotchPomodoro but does not delete it. Your v1 focus
settings and history are copied into NotchHub on first launch. Remove the old app with
`rm -rf ~/Applications/NotchPomodoro.app` (and turn off its login item in System Settings › General ›
Login Items if you had enabled it).

## Using the notch

- **Idle:** a black shape exactly the size of the notch (invisible on a black menu bar).
- **Collapsed with something to show:** wings grow beside the notch. Priority: a transient overlay
  ("Charging · 64%", "Copied", "AirDrop sent", 2.5 s each) > a running Pomodoro > Now Playing > idle.
  The shape flares into the menu bar with concave top fillets and has 12 pt bottom corners.
- **Expanded:** hover the notch (or click it, or press ⌃⌥N). Header strip beside the notch: battery on
  the left, Caffeine cup + Settings gear on the right. Below it the tab strip (and the next calendar
  event on the right), then the selected module. Width 400 pt (480 pt on Focus); height depends on the tab.
  Collapses 0.35 s after the mouse leaves the shape, or on Esc. Opened by hotkey or menu, it stays open
  until the mouse has visited it once (or ⌃⌥N / Esc).
- **Right-click** the collapsed notch for the same menu as the menu bar item.
- **Menu bar item** (🍅, ☕ while Caffeine is on): Start/Pause, Skip, Reset, Open panel, Caffeine
  durations, Launch at login, Settings…, Quit. There is no Dock icon.

### Hotkeys (Carbon, no Accessibility permission)

- **⌃⌥P** start / pause the focus timer from any app.
- **⌃⌥N** expand / collapse the notch.

## Modules

Every module can be switched off in Settings (gear in the panel, or menu bar › Settings…). Off = gone
from the tab strip and its background work stops.

| Module | What it does | Permission (asked lazily) |
|---|---|---|
| **Focus** | The v1 Pomodoro (wall-clock end dates, resumes after relaunch) + a GitHub-style heatmap of the last 52 weeks (Sunday on top, GitHub dark greens: 1-24 / 25-49 / 50-99 / 100+ focused minutes a day, hover a square for its day). Today is outlined and pulses while a focus session runs; month labels roll forward with the year. The Focus tab is 480 pt wide, the others 400 pt. Settings: lengths, sessions before long break, sound, auto-start. | Notifications, the first time a session starts. |
| **Now Playing** | Spotify and Apple Music via AppleScript: artwork, title/artist, scrubber (seek), previous / play-pause / next, player volume. Collapsed: artwork left of the notch, 3-bar visualizer right (animates only while playing). Polls every 2 s while a player runs and the panel is open, 5 s otherwise, not at all when neither app runs. Never launches a player. Setting: Automatic / Spotify only / Music only. | Automation (Apple Events) for Spotify / Music, the first time you open the tab (skipped if already granted). |
| **Shelf** | Drop files on the collapsed notch (it opens on the Shelf tab while a file drag hovers it) or on the Shelf tab. Drag a file out to any app, ⌘-click to remove, double-click to open, Clear, AirDrop. Items persist as bookmarks (security-scoped when available) and follow renames/moves. | None. |
| **Clipboard** | Last 50 (configurable 10 to 200) text / URL / image copies, polled every 0.5 s. Click a row to copy it back ("Copied"). Pin items (pinned never age out). Search. "Ignore passwords" (skips `org.nspasteboard.ConcealedType`) is on by default. | None. |
| **Notes** | One plain-text scratchpad, autosaved 300 ms after each change, word count, Copy all. | None. |
| **Battery** | Percent + time remaining in the header strip; transients on plug / unplug and at 20 % and 10 % (both configurable). IOKit power-source notifications + a 60 s refresh. | None. |
| **Calendar** | Read-only EventKit. Header shows the next event today ("Standup in 12m"); the tab lists today's remaining events with a **Join** button for Zoom / Google Meet / Teams links found in the URL, location or notes. Refreshes on calendar changes and every 5 min. Settings: which calendars to include. | Calendars (full access, read-only use), the first time you open the tab. |
| **Caffeine** | Cup in the header strip toggles an `IOPMAssertion` (PreventUserIdleDisplaySleep) for the default duration (30 m / 1 h / 2 h / until off; set in Settings). Every duration is also in the menu bar item. | None. |
| **Mirror** | Live camera preview, mirrored. The capture session runs only while the Mirror tab is visible. | Camera, the first time you open the tab. |

Any denied permission shows an inline message with an "Allow in System Settings" button; nothing crashes.

## Where data lives

UserDefaults domain `com.pritesh.notchhub` (`~/Library/Preferences/com.pritesh.notchhub.plist`):

| Key | Contents |
|---|---|
| `settings`, `history`, `inFlight` | Focus settings, completed sessions (cap 2000), current session (END timestamp). Copied once from `com.pritesh.notchpomodoro`. |
| `hub.settings` | Enabled modules, selected tab, idle notch width override, "show on all displays". |
| `nowPlaying.settings` | Player preference, whether the Automation prompt has been triggered. |
| `shelf.items` | Shelf bookmarks + names. |
| `clipboard.history`, `clipboard.settings` | Text and URL history (images are kept in memory only), size, ignore passwords. |
| `notes.text` | The scratchpad. |
| `battery.settings`, `calendar.settings`, `caffeine.settings` | Thresholds, excluded calendars, default duration. |

Reset everything: `defaults delete com.pritesh.notchhub`. Debug log of panel show/expand/collapse:
`~/Library/Logs/NotchHub.log`.

Debug driver (for automated checks, off by default): `defaults write com.pritesh.notchhub debugDriver -bool true`
and relaunch; the app then runs commands written to `~/Library/Logs/notchhub-cmd.txt` (`expand`, `tab focus`,
`snapshot <name>` → `~/Library/Logs/notchhub-<name>.png`, `focus start`, `caffeine on`, `transient <text>`,
`clip select <0-based row>`, `notes set <text>`, `wait <s>`) and logs each one. Turn it off with
`defaults delete com.pritesh.notchhub debugDriver`.

## Notes

- Ad-hoc signed, not sandboxed, no hardened runtime. Notifications and Launch at login need the app
  bundle; a bare `swift run` skips them.
- The Settings window is a normal window, so opening it activates NotchHub; the notch panel itself
  never activates the app.
- v2 targets the built-in (notched) screen only ("Show on all displays" is shown but disabled). On a
  Mac without a notch it shows a 200x32 shape at the top of the main screen.
