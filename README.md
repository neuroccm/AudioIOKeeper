# Audio IO Keeper

A tiny native macOS menu-bar app that keeps your chosen audio **input** and
**output** devices exactly where you put them.

macOS loves to switch audio devices on its own: take out an AirPod, walk near
your iPhone, plug in a display — and your mic or speakers silently change
mid-call. Audio IO Keeper pins the devices you choose in the app and, whenever
macOS moves a default on its own, moves it straight back.

## How it works

- You pick an output and an input device in the menu-bar popover. That choice
  is the pin, and it takes effect immediately.
- The app listens for Core Audio default-device changes. If a default drifts
  away from your pin (AirPods removed, Continuity iPhone mic appearing, a new
  display grabbing audio…), it is restored right away.
- If your pinned device disconnects, nothing is forced and nothing breaks:
  macOS uses its own fallback, the app shows a warning state, and your pin is
  restored the moment the device comes back.
- If something else keeps switching a default back (another utility, an
  automation), the keeper does not fight it switch-for-switch: after a few
  immediate restores it backs off with growing cooldowns (2 s up to 60 s),
  retries periodically, and shows a conflict state in the popover. During
  such a conflict restoration is deliberately *not* instant — that
  qualifies the "restored right away" behavior above, which applies to
  ordinary one-off switches.
- Moving between docks or hubs? The **Rescan** button (popover header, and
  in Settings) re-reads the connected devices and re-checks your pins, for
  the rare cases where a hot-plug change was missed.
- Keeping can be switched off per direction (input/output) at any time.
- Every action the keeper takes is shown in the popover's activity log. An app
  that overrides system behavior should never act invisibly.

### Safety

Audio IO Keeper only reads and writes the standard system-default input/output
device — the exact same Core Audio properties that **System Settings → Sound**
uses. It installs no drivers, kernel/system extensions, or audio plug-ins,
uses no private APIs, never records or plays audio, has no network code, and
runs in the App Sandbox with the Hardened Runtime. Quitting the app leaves
your system exactly as it was; there is nothing to uninstall beyond the app
itself.

## Requirements

- macOS 14 (Sonoma) or later

## Install

Download the latest build from
[Releases](https://github.com/neuroccm/AudioIOKeeper/releases), or build it
yourself (below). Optionally enable **Launch at login** in Settings so it is
always on guard.

> First launch: the app adopts whatever input/output macOS is already using
> as the initial pins, so "keep what I have" works immediately — change them
> any time from the popover.

## Build from source

Requirements: Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
git clone https://github.com/neuroccm/AudioIOKeeper.git
cd AudioIOKeeper
xcodegen generate
open AudioIOKeeper.xcodeproj   # or: xcodebuild build -scheme AudioIOKeeper
```

The generated `.xcodeproj` is committed for convenience; `project.yml` is the
source of truth — re-run `xcodegen generate` after editing it.

Run the tests:

```sh
xcodebuild test -scheme AudioIOKeeper -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Build a shareable disk image (ad-hoc signed, not notarized — recipients
open it once via right-click → Open):

```sh
scripts/make-dmg.sh   # writes ./AudioIOKeeper-<version>.dmg
```

## Architecture

| File | Role |
| --- | --- |
| `AudioIOKeeperApp.swift` | App entry point, menu-bar scene, launch-time keeper start |
| `AppModel.swift` | Single source of truth (`@Observable`, `@MainActor`) — state, enforcement, activity log |
| `KeeperEngine.swift` | Pure, hardware-free decision logic: restore-or-not, plus the anti-thrash `RestoreThrottle` |
| `AudioHardwareWorker.swift` | Serializes all HAL calls on a dedicated queue off the main thread; coalesced change pings; sequenced snapshots so stale reads can't overwrite newer writes |
| `AudioHardwareClient.swift` | The one place that talks to Core Audio (behind a protocol for testing) |
| `SettingsStore.swift` | Typed `UserDefaults` access; pins stored as persistent device UIDs |
| `MenuContentView.swift` / `SettingsView.swift` | SwiftUI popover and Settings window |
| `LoginItemManager.swift` | Launch-at-login via `SMAppService` |

Design notes:

- Devices are identified by their persistent Core Audio **UID**, never by the
  volatile `AudioDeviceID`, so pins survive reboots and reconnects.
- Enforcement is loop-free by construction: restoring a pin fires a change
  notification, but the engine sees "current == pin" and does nothing. A
  *competing* writer is handled by `RestoreThrottle`: bounded immediate
  restores, then exponential cooldowns with a visible conflict state.
- No synchronous Core Audio call ever runs on the main thread, so a stalled
  driver can't freeze the menu or the Quit button.
- Swift 6 with complete strict-concurrency checking.

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
Every pull request is automatically reviewed by
[CodeRabbit](https://www.coderabbit.ai/) and must pass CI (build, unit tests,
SwiftLint).

## License

[MIT](LICENSE)
