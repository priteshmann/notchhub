# NotchHub v2 — "the best Mac notch" (binding brief, builds ON TOP of v1 Pomodoro)

v1 (docs/BRIEF.md) shipped the window mechanics + Pomodoro engine. v2 keeps every v1 behaviour
and turns the panel into a modular hub. Same constraints: macOS 27, Swift 6.4, CLT only, SwiftPM,
no third-party packages, no Xcode project. Rename the product to **NotchHub** (bundle id
`com.pritesh.notchhub`, executable `NotchHub`, app `NotchHub.app`); keep the Pomodoro code.

## Architecture
- `NotchModule` protocol: `id`, `title`, `systemImage`, `collapsedPriority: Int`,
  `collapsedView: AnyView?` (nil = nothing to show), `expandedView: AnyView`, `start()`, `stop()`.
- `HubStore` (@MainActor ObservableObject) owns the module list, the selected tab, and a
  `transient` queue (short-lived collapsed overlays such as "Charging 64%", "Copied", "AirDrop
  sent") with auto-dismiss after 2.5s.
- Collapsed bar content = highest-priority module that has something to show, overridden by any
  active transient. Priority: transient > Pomodoro running > Now Playing > idle (plain notch).
- Expanded panel: a top tab strip (SF Symbols, 20pt tap targets) and the selected module's view
  below. Panel height grows per module (Pomodoro 180, Shelf 200, Clipboard 240, Notes 220),
  animated. Width 400. Hover/leave/Esc collapse rules unchanged from v1.
- Every module is independently toggleable in Settings (off = hidden from the tab strip and
  its background work stops). Settings becomes a real `NSWindow` (standard titled window,
  opened from the gear + the status item), with one section per module.
- All permissions (Automation, Calendar, Camera, Notifications) requested lazily on first use
  of that module, never at launch. Each permission failure degrades to an inline "Allow in
  System Settings" message, never a crash.

## Modules (all required)
1. **Focus** — the v1 Pomodoro, unchanged, plus a 7-day bar chart of focused minutes in the
   expanded view (SwiftUI `Charts` is fine, it is a system framework).
2. **Now Playing** — Spotify and Apple Music via `NSAppleScript` (public API; polls every 2s
   only while the app is running and the panel is visible, 5s otherwise; stops when neither
   app is running — check `NSRunningApplication` first, never launch the player).
   Reads: player state, track, artist, album, duration, position, artwork (Music: artwork
   data; Spotify: `artwork url` then download with URLSession, cached by URL).
   Collapsed: 18pt artwork left of the notch, 3-bar animated "visualizer" right (animates only
   while playing). Expanded: artwork 72pt, title/artist, scrubber (seek via AppleScript
   `set player position`), prev / play-pause / next, volume slider (player volume).
3. **Shelf** — drop any files onto the collapsed notch OR the expanded Shelf tab. Items persist
   (security-scoped bookmarks in UserDefaults). Grid of file icons (`NSWorkspace.shared.icon`),
   name under each, drag OUT to any app (NSItemProvider with the file URL), ⌘-click to remove,
   "Clear" and "AirDrop" (uses `NSSharingService(named: .sendViaAirDrop)`) buttons. While a drag
   hovers the collapsed notch, expand into the Shelf tab automatically.
4. **Clipboard** — history of the last 50 text/URL/image copies (poll `NSPasteboard.general
   .changeCount` at 0.5s). List with type icon, preview (one line, 60 chars), relative time.
   Click = copy back + transient "Copied". Pin items (pinned never age out). Search field.
   Toggle "Ignore passwords" (skip when `org.nspasteboard.ConcealedType` is present) default ON.
5. **Notes** — one plain-text scratchpad (TextEditor), autosaved to UserDefaults on every
   change (debounced 300ms), word count in the corner, "Copy all" button.
6. **Battery** — IOKit power sources (`IOPSCopyPowerSourcesInfo`). Transient on power
   connect/disconnect ("Charging · 64%" / "On battery · 64%") with a green/orange fill
   animation; low battery transient at 20% and 10%. Shows percent + time remaining in the
   panel header strip (always visible above the tabs).
7. **Calendar** — EventKit, read-only. Header strip shows the next event today ("Standup in
   12m") and the Calendar tab lists today's remaining events with a "Join" button when the
   notes/location/URL contain a Zoom/Meet/Teams link (regex). Refresh on
   `EKEventStoreChanged` and every 5 min.
8. **Caffeine** — a cup icon in the header strip; toggling creates/releases an
   `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep)`. Optional
   timer (30m / 1h / 2h / until off). Also in the status item menu.
9. **Mirror** — a tab with the FaceTime camera preview (AVCaptureSession, `AVCaptureVideoPreviewLayer`
   in an NSViewRepresentable), session runs ONLY while the tab is visible. Mirrored horizontally.

## Collapsed-bar polish
- The black shape must blend with the real notch: no visible seam, corner radius on the
  bottom-outer corners 12pt, inner corners (where the shape meets the notch) curved INWARD
  (draw a custom `Shape` with the two concave fillets) so it reads as one object.
- Transients slide in from behind the notch (offset + opacity, 0.25s spring).
- Idle state is exactly notch-sized and fully black — invisible on a black menu bar.
- `⌃⌥N` global hotkey toggles expand/collapse (in addition to v1's ⌃⌥P).
- Right-click the collapsed notch = status item menu.

## Settings window sections
General (launch at login, hotkeys shown, idle notch width override, "show on all displays"
OFF by default — v2 still targets the built-in screen only), one section per module with its
enable toggle and its own options (Pomodoro durations, Now Playing player preference,
Clipboard size/ignore-passwords, Battery thresholds, Calendar calendars-to-include, Caffeine
default duration).

## Definition of done
- `./build.sh` zero warnings; `./build.sh --install` installs `~/Applications/NotchHub.app`
  and launches it (owner will run the install step).
- Every module works with its permission granted and degrades cleanly without it.
- `swift test` keeps the v1 engine tests green and adds: clipboard dedupe (same changeCount
  twice = one entry; same text twice in a row = one entry), shelf bookmark round-trip, transient
  queue ordering/expiry (inject a clock).
- README documents every module, every permission it asks for and why, both hotkeys, and
  where data is stored (UserDefaults suite `com.pritesh.notchhub`).
