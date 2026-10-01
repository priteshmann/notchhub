# NotchPomodoro — design brief (binding for the implementer)

Owner: Pritesh. Target machine: MacBook Air 13" (2560x1664, notch), macOS 27, Swift 6.4,
Command Line Tools ONLY (no Xcode.app, no xcodebuild). Build must be `swift build` + a shell
script that assembles a `.app` bundle. Nothing else is available.

## What it is
A Pomodoro timer that lives IN the notch. It is always visible on top of every window and every
Space (fullscreen apps too), so Pritesh can glance up and see how much focused work is done
today without leaving whatever he is doing.

## Behaviour
1. **Collapsed (idle, default):** a black rounded shape that hugs the notch — same width as the
   notch, same height as the menu bar — so it looks like the notch itself. Visually invisible
   until something is running.
2. **Collapsed (running):** the shape grows ~110px to each side of the notch. Left of the notch:
   the remaining time `mm:ss` in monospaced white text. Right of the notch: a thin progress bar
   (or ring) filling as the session elapses, plus a tiny label "Focus" / "Break" / "Long break".
   Colour: focus = warm orange (#FF6B4A), break = green (#34C759), long break = blue (#0A84FF).
3. **Expanded (hover or click on the notch area):** animates (spring, ~0.35s) down into a panel
   ~360x180 hanging from the notch, black with 24pt corner radius on the bottom corners, white
   text. Contents:
   - Big remaining time (48pt rounded monospaced).
   - Phase label + "Session 2 of 4".
   - Buttons: Start / Pause (toggles), Skip (to next phase), Reset.
   - Today's row: "🍅 x N today · 125 min focused" (N = completed focus sessions since local
     midnight; minutes = sum of completed focus minutes). Tomatoes render as filled/unfilled
     circles, max 12 shown, then "+N".
   - A small gear icon → settings popover: focus length (default 25), short break (5), long
     break (15), sessions before long break (4), sound on/off, auto-start next phase on/off,
     launch at login on/off.
   Collapses when the mouse leaves the panel (0.4s delay) or on Esc.
4. **Session end:** play a system sound (NSSound "Glass") if enabled, send a user notification
   ("Focus done — take 5"), flash the collapsed bar colour 3 times. If auto-start is off, the
   collapsed bar shows the NEXT phase at full duration, paused.
5. **Global hotkey:** ⌃⌥P toggles start/pause from any app (use a Carbon `RegisterEventHotKey`
   — no Accessibility permission needed). Mention it in the settings popover.
6. **Menu bar status item** (fallback + quit): shows "🍅 24:59" while running, menu with
   Start/Pause, Reset, Open panel, Launch at login, Quit. Required because the app has no Dock
   icon (`LSUIElement = true`).
7. **Persistence:** UserDefaults. Keys: settings, `history` as an array of
   `{startedAt, endedAt, phase, minutes}` for completed sessions (cap 2000 rows), and the
   in-flight session so a relaunch resumes the countdown correctly (store the END timestamp,
   not elapsed seconds — wall clock based, never drift with Timer ticks).

## Window mechanics (the hard part — get these exactly right)
- `NSPanel`, `styleMask: [.borderless, .nonactivatingPanel]`, `isOpaque = false`,
  `backgroundColor = .clear`, `hasShadow = false` (collapsed) / `true` (expanded),
  `level = .statusBar + 1` (`NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)`),
  `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`,
  `isMovableByWindowBackground = false`, `hidesOnDeactivate = false`, `isReleasedWhenClosed = false`.
- Position: the BUILT-IN screen (`NSScreen.screens.first { $0.safeAreaInsets.top > 0 }`,
  fallback `NSScreen.main`). Notch geometry: `screen.safeAreaInsets.top` is the notch height;
  notch width = `screen.frame.width - auxiliaryTopLeftArea.width - auxiliaryTopRightArea.width`
  (both are available on macOS 12+). Fallback when no notch: 200x32 centered at top.
- The panel frame is always centered horizontally on the notch and its top edge is the screen's
  top edge. Collapsed height = notch height; expanded height = notch height + 180.
- Mouse tracking: an `NSTrackingArea` on the content view with `.mouseEnteredAndExited,
  .activeAlways`. Expanded state must be able to receive clicks WITHOUT activating the app
  (`.nonactivatingPanel` + override `canBecomeKey` = true so buttons work, but never call
  `NSApp.activate`).
- Re-position on `NSApplication.didChangeScreenParametersNotification`.
- Content: SwiftUI via `NSHostingView`; keep the hosting view's `safeAreaInsets` ignored
  (`.ignoresSafeArea()`), the notch itself is just part of the black shape.

## Project layout
```
~/notch-pomodoro/
  Package.swift              # swift-tools-version 5.9, macOS 13 min, one executableTarget "NotchPomodoro"
  Sources/NotchPomodoro/
    main.swift               # NSApplication boot, AppDelegate, setActivationPolicy(.accessory)
    AppDelegate.swift
    NotchWindow.swift        # the NSPanel + geometry + tracking
    NotchView.swift          # SwiftUI collapsed/expanded views
    SettingsView.swift
    PomodoroEngine.swift     # ObservableObject: state machine, wall-clock timer, persistence
    Hotkey.swift             # Carbon hotkey
    StatusItem.swift
    Notifier.swift           # UNUserNotificationCenter + sound
  Resources/Info.plist       # CFBundleIdentifier com.pritesh.notchpomodoro, LSUIElement true,
                             # CFBundleName NotchPomodoro, NSHumanReadableCopyright
  build.sh                   # swift build -c release; assemble NotchPomodoro.app under ./dist;
                             # copy Info.plist; codesign --force --sign - ; optional --install
                             # copies to ~/Applications and (re)launches it
  README.md                  # how to build, install, hotkey, where data lives
```
- `UNUserNotificationCenter` requires a bundle: guard so it never crashes when run as a bare
  `swift run` binary (check `Bundle.main.bundleIdentifier != nil` before requesting auth).
- Swift 6 strict concurrency: mark UI types `@MainActor`; no data races, no warnings.
- No third-party dependencies. No Xcode project. No storyboards/xibs.

## Definition of done
- `./build.sh` succeeds with zero warnings on this machine.
- `./build.sh --install` puts `NotchPomodoro.app` in `~/Applications` and launches it.
- Launching shows nothing but a notch-hugging black shape; hovering expands it; Start runs;
  the collapsed bar shows the countdown on top of a fullscreen app and on every Space.
- Quit from the menu bar item works. Relaunch resumes a running session at the right time.
- Add `Tests/NotchPomodoroTests/EngineTests.swift` (XCTest) covering: phase sequencing
  (4 focus → long break), today-count rollover at local midnight, resume-from-persisted-end-time.
  `swift test` passes. If XCTest is unavailable under CLT, say so in the final report and keep
  the test file compiling under `#if canImport(XCTest)`.
