# Audio IO Keeper — Session Handover

Updated: **2026-11-20 (23:12 EST)**. Read this first in the next session.

## What this app is

Native Swift macOS menu-bar app (**Audio IO Keeper**, macOS 14+, Swift 6 strict concurrency, App Sandbox + Hardened Runtime). It pins the user's chosen default input and output audio devices (plus optional system sound-effects output) and restores them whenever macOS switches defaults automatically (AirPods removed, iPhone Continuity mic appearing, USB mics hijacking speaker output, displays grabbing audio). Uses public Core Audio HAL properties only; no drivers, extensions, or audio capture/playback; every action is logged in the popover's activity log and `OSLog`.

- Repository: `https://github.com/neuroccm/AudioIOKeeper` (public, MIT)
- Canonical local workspace: `/Users/houman/Downloads/AudioIOKeeper`

---

## Current state (1.3.1, build 10 — released on `main`, tagged `v1.3.1`)

- **Git `main` / tag `v1.3.1`:** Includes all **v1.3.1 (build 10)** fixes & augmentations, updated Markdown documentation (`README.md`, `HANDOVER.md`, `packaging/README.txt`), and a new GitHub Pages site (`docs/index.html` + `docs/icon.png`).
- **Built & verified Release DMGs (Universal `arm64` + `x86_64`, ad-hoc signed with Hardened Runtime + App Sandbox, `hdiutil verify` valid):**
  - `/Users/houman/Desktop/AudioIOKeeper-1.3.1.dmg`
  - `/Users/houman/Downloads/AudioIOKeeper/AudioIOKeeper-1.3.1.dmg`
- **Test suite:** **61 / 61 unit & regression tests passing** (`xcodebuild test -project AudioIOKeeper.xcodeproj -scheme AudioIOKeeper -destination platform=macOS CODE_SIGNING_ALLOWED=NO`), zero Swift 6 strict-concurrency warnings.

---

## What was diagnosed, fixed, and augmented in 1.3.1

### 1. Root causes of the "devices not detecting / selectable to pin" bug

1. **Collapsed `0 pt` device list in `MenuBarExtra(.window)` (`AudioIOKeeper/MenuContentView.swift`):**
   - `ViewThatFits(in: .vertical)` previously fell back to `ScrollView { devicesStack }.frame(maxHeight: 360)` with no minimum/fixed height.
   - Because `model.devices` starts empty at launch and populates asynchronously from `AudioHardwareWorker`, `NSHostingController.sizeThatFits(in: .zero)` collapsed the `ScrollView` branch (`178 pt` total window height — fitting only Header + Activity Log + Footer, leaving `0 px` for Output/Input rows) once 8 devices (9 rows) + log entries arrived.
   - **Fix:** Replaced `ViewThatFits` with deterministic sizing: `<= 10` combined rows render `devicesStack.fixedSize(horizontal: false, vertical: true)` directly; `> 10` rows use `ScrollView { devicesStack }.frame(height: 360)` so `minHeight` is never `0`. Also added `.onAppear { model.refreshOnMenuOpen() }`.
   - **Regression guard:** `MenuBarSymbolTests.testMenuContentViewNeverCollapsesWhenDevicesPopulateAsynchronously`.

2. **Button hit-testing wedge in non-activating `MenuBarExtra` panels (`AudioIOKeeper/MenuContentView.swift`):**
   - Unified logs (`com.apple.AppKit:Gestures` → `GesturePhaseQueue.InvalidTransition Code=1`, `Marking view as no longer exclusive`) showed `.buttonStyle(.plain)` SwiftUI gesture buttons wedging inside the non-activating `MenuBarExtra` window alongside `.contextMenu`.
   - **Fix:** Switched both the device-row button and the pin button to `.buttonStyle(.borderless)` (with explicit `.foregroundStyle(.primary)` on the label), which backs each control with a native AppKit `NSButton` (`SwiftUIAppKitButton`) that accepts first-mouse clicks immediately.

3. **Core Audio hot-plug, slow-waking displays/docks, and HAL plugin quirks (`AudioIOKeeper/AudioHardwareClient.swift`):**
   - **Per-device HAL listeners (`syncDeviceListeners`):** Added wildcard-scope listeners on each `AudioObjectID` for `IsAlive`, `StreamConfiguration`, `IsHidden`, `CanBeDefaultDevice`, `Name`, and `DataSource`. Docks, DisplayPort/HDMI monitors, and Bluetooth headsets often finish initializing streams/liveness *after* `kAudioHardwarePropertyDevices` has already fired; per-device listeners catch those transitions automatically without manual rescanning.
   - **Driver fallbacks & memory safety:**
     - `isDeviceAlive` now defaults to `true` via `uint32PropertyIfPresent` when a virtual/aggregate driver omits `kAudioDevicePropertyDeviceIsAlive`.
     - `canBeDefaultDevice` / `canBeDefaultSystemDevice` check directional scope first, then fall back to `kAudioObjectPropertyScopeGlobal` before defaulting to `true`.
     - `hasSelectableChannels` falls back to `kAudioDevicePropertyStreams` when `StreamConfiguration` is not implemented, and clamps `AudioBufferList.mNumberBuffers` to the allocated byte count *before* constructing `UnsafeMutableAudioBufferListPointer`.
     - `deviceID(forUID:)` uses `kAudioHardwarePropertyTranslateUIDToDevice` (O(1)) and falls back to scanning `deviceObjectIDs()` if a virtual driver omits UID translation.
     - Watches `kAudioHardwarePropertyServiceRestarted` to tear down and re-install HAL listeners cleanly if `coreaudiod` restarts.

### 2. Augmentations included in 1.3.1

- **Duplicate device name disambiguation (`AudioIOKeeper/AudioDevice.swift`, `AudioIOKeeper/AudioIOKeeperApp.swift`):**
  - On setups like the user's dual `BenQ EX3203R` endpoints (`HDMI` + `DisplayPort`), `AudioDevice.disambiguatedNames(for:)` qualifies colliding names by port (`BenQ EX3203R (HDMI)` vs `BenQ EX3203R (DisplayPort)`), or appends a 4-char UID token (`BenQ EX3203R (DisplayPort · 4E78)`) if both name and port match. Unique names stay untouched.
- **Direct device selection & pinning in Settings (`AudioIOKeeper/SettingsView.swift`):**
  - Upgraded **Settings → Locked devices** from static text to interactive `Picker` menus + `Unpin` buttons for both Output and Input (including disconnected-pin display), plus a toggle for locking system alert/sound-effects output (`kAudioHardwarePropertyDefaultSystemOutputDevice`) and `SMAppService` approval/error feedback (`AudioIOKeeper/LoginItemManager.swift`).
- **Post-wake & transient failure resilience (`AudioIOKeeper/AppModel.swift`, `AudioIOKeeper/SettingsStore.swift`, `AudioIOKeeper/AudioHardwareWorker.swift`, `AudioIOKeeper/KeeperEngine.swift`):**
  - `handleSystemWake()` reconciles immediately on `NSWorkspace.didWakeNotification` *and* runs a 1.5 s follow-up scan (`wakeFollowUpDelay`) for slow-waking DisplayPort/HDMI/dock audio.
  - Queued/in-flight HAL write cancellation with rollback on unpin (`WriteCancellation`), transient write-failure logging & 1 s retry scheduling, and monotonic `RestoreThrottle` backoff with continuous `stableSince` quiet-period reset.
- **Universal Release DMG (`scripts/make-dmg.sh`):**
  - Uses `-destination 'generic/platform=macOS'` so Release builds produce a Universal (`arm64` + `x86_64`) app bundle, staged into an isolated `mktemp -d` directory with `trap` cleanup.

---

## Architecture & guardrails (do not break)

| File | Lines | Responsibility & constraints |
| --- | ---: | --- |
| `AudioIOKeeper/AudioHardwareClient.swift` | 395 | **Only** file allowed to import `CoreAudio` or call Core Audio C APIs (enforced by `.coderabbit.yaml`). |
| `AudioIOKeeper/AudioDevice.swift` | 183 | Value types (`AudioDirection`, `TransportType`, `AudioDevice`, `ActivityEntry`) + `AudioHardwareClient` protocol + name disambiguation. |
| `AudioIOKeeper/AudioHardwareWorker.swift` | 284 | Serialized off-main-thread HAL queue, debounced change pings, sequenced snapshots, cancellation/rollback. |
| `AudioIOKeeper/KeeperEngine.swift` | 211 | Pure, hardware/I/O-free `KeeperEngine`, `RestoreThrottle`, `DirectionStatus`. Any logic change requires unit tests. |
| `AudioIOKeeper/AppModel.swift` | 378 | `@MainActor` `@Observable` state, user actions, reconcile & enforcement loop. |
| `AudioIOKeeper/SettingsStore.swift` | 233 | `UserDefaults` persistence + `AppModel` persistence, pause/resume, rescan, and wake helpers. |
| `AudioIOKeeper/AudioIOKeeperApp.swift` | 179 | Entry point (`AppDelegate` starts keeper at launch + wake observer), `MenuBarExtra` scene, derived UI accessors. |
| `AudioIOKeeper/MenuContentView.swift` | 349 | Menu-bar popover UI. Keep `.buttonStyle(.borderless)` and deterministic non-`ViewThatFits` sizing. |
| `AudioIOKeeper/SettingsView.swift` | 199 | Settings window (Output/Input lock pickers, system sound effects toggle, 15-min unlock, Launch at login). |
| `AudioIOKeeper/LoginItemManager.swift` | 81 | `LoginItemManaging` protocol + `SMAppService.mainApp` wrapper. |

### Strict CI / lint / privacy invariants

1. **SwiftLint (`swiftlint --strict` in `.github/workflows/ci.yml`):**
   - `file_length <= 400` (warning = error under `--strict`), `type_body_length <= 300`, `function_body_length <= 50`, `line_length <= 130` (non-comment), `identifier_name >= 2` (`id` excluded), plus `empty_count`, `explicit_init`, `fatal_error_message`, `first_where`. Every Swift file in `AudioIOKeeper/` and `AudioIOKeeperTests/` currently satisfies these limits.
2. **XcodeGen sync (`project.yml` ↔ `AudioIOKeeper.xcodeproj`):**
   - `xcodegen` and `swiftlint` are **not** installed locally on this Mac, so if you edit `project.yml` (especially adding/removing files or build settings), update `AudioIOKeeper.xcodeproj/project.pbxproj` identically (or install `xcodegen` and run `xcodegen generate`) before pushing — CI fails if `xcodegen generate` produces a diff.
3. **App Sandbox entitlements (`AudioIOKeeper/AudioIOKeeper.entitlements`):**
   - Keep `com.apple.security.app-sandbox = true` **without** `com.apple.security.device.audio-input`. Core Audio HAL device enumeration (both input and output) and default-device switching work inside App Sandbox without `audio-input`; leaving it out avoids unnecessary Microphone TCC prompts and preserves the "never records audio" safety guarantee.

---

## Local environment gotchas (macOS 27.2.1 / Xcode 27.2)

- **Nested sandbox & `xcodebuild`:** Running `xcodebuild` inside a sandboxed agent shell fails because Swift's `@Observable` macro server (`swift-plugin-server`) calls `sandbox_apply` (`Operation not permitted`) and `xcodebuild test` calls `IOPMAssertionCreateWithName` (`-536870199`). Run `xcodebuild test` and `scripts/make-dmg.sh` outside the inner CLI sandbox.
- **Zsh `log` builtin:** Always invoke `/usr/bin/log show --info --predicate 'subsystem == "com.neuroccm.AudioIOKeeper"'` (not bare `log`, which hits zsh's builtin).
- **Sandboxed preferences path:** The installed app stores `UserDefaults` in `~/Library/Containers/com.neuroccm.AudioIOKeeper/Data/Library/Preferences/com.neuroccm.AudioIOKeeper.plist` (not `~/Library/Preferences/`).

---

## Suggested next steps

1. Enable GitHub Pages in repo **Settings → Pages** (Source: **Deploy from a branch**, Branch: `main`, Folder: `/docs`) so `docs/index.html` is served at `https://neuroccm.github.io/AudioIOKeeper/`.
2. Create the GitHub Release for tag `v1.3.1` and attach `AudioIOKeeper-1.3.1.dmg`.
3. Verify the GitHub Actions CI run on `main` (`xcodegen generate` sync, `swiftlint --strict`, and `xcodebuild test`).
