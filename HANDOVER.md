# Audio IO Keeper — Session Handover

Written 2026-10-23 (late evening session). Read this first in the next session.

## What this app is

Native Swift macOS menu-bar app ("Audio IO Keeper", macOS 14+, Swift 6 strict
concurrency, App Sandbox + Hardened Runtime). It pins the user's chosen
default input/output devices and restores them whenever macOS switches
defaults automatically (AirPods removed, iPhone Continuity mic, displays
grabbing audio). Public Core Audio APIs only; no drivers/extensions; every
action shown in an activity log. Full details: `README.md`, `CONTRIBUTING.md`.

Repository: https://github.com/neuroccm/AudioIOKeeper (public, MIT)
Local canonical copy: `/Users/houman/Downloads/AudioIOKeeper` (see sync note)
Working clone used this session: `/tmp/AudioIOKeeper-work` (ephemeral, clean)

## Current state

GitHub `main` = `0c77bea` — "Stability: anti-thrash restore throttling +
off-main-thread HAL worker". CI green on every push so far (GitHub Actions
job "Build, test, lint": XcodeGen freshness, SwiftLint --strict,
`xcodebuild test`, 25 unit tests).

Commit history:

1. `35baa05` Initial release (app, tests, CI, CodeRabbit config, docs)
2. `6ba23bb` CI: actions/checkout v5
3. `0c77bea` Stability implementation (below) + Rescan button

### Implemented

- Keeper engine (`AudioIOKeeper/KeeperEngine.swift`): pure restore decision
  + `RestoreThrottle` per direction — 3 immediate restores/60 s window,
  then exponential cooldowns 2 s → 60 s, one retry per cooldown,
  quiet-period + on-user-change reset, `.conflicted` UI status.
- HAL worker (`AudioIOKeeper/AudioHardwareWorker.swift`): all Core Audio
  reads/writes serialized on a dedicated queue off the main thread;
  coalesced/debounced change pings; sequenced snapshots, stale results
  rejected by `AppModel`.
- `AppModel` reconcile loop (async), pins stored as persistent device UIDs,
  first-launch adopts current defaults as pins, activity log (cap 12),
  Launch-at-login via `SMAppService`.
- Rescan button (popover header + Settings → Devices): forces a fresh
  hardware snapshot + pin re-check (dock/hub moves).
- Tests (`AudioIOKeeperTests/`): fake worker emits own-write notifications
  and models a competing writer; coverage for throttling, stale snapshot,
  rescan-restore, throttle policy, engine, settings. 25 tests, CI-passing.
- CodeRabbit: `.coderabbit.yaml` committed (assertive profile, auto-review
  on every PR, path instructions). **The user states the CodeRabbit GitHub
  App already has all their repos allowed** — so PRs should be reviewed
  automatically. No PR has been opened yet to prove it end-to-end.

### Verified on real hardware (initial build, `35baa05` era)

- Ran the sandboxed app on the user's Mac; pins adopted automatically:
  output = Scarlett Solo USB, input = Yeti Nano.
- Externally switched output → MacBook Pro Speakers: app restored Scarlett
  within ~2 s. Switched input → iPhone Continuity mic: restored Yeti
  immediately. Probe used: `/tmp/audio_probe` (source `/tmp/audio_probe.swift`,
  supports `set-output <UID>` / `set-input <UID>`; default invocation lists
  devices + current defaults). Rebuild it with
  `swiftc -O -o /tmp/audio_probe /tmp/audio_probe.swift -framework CoreAudio`.
- An early bug was caught this way: keeper must start in the AppDelegate,
  NOT from the menu popover's `onAppear` (MenuBarExtra content is lazy).

## The one outstanding task — DONE (2026-10-24)

**Build & run the current code locally and re-run the live
switch-and-restore check: completed.** On the 1.1.0 tree (stability work
plus the release polish below): 25 unit tests pass locally, ad-hoc Debug
build launched, and with present-device pins the probe check passed in
both directions — output switched to the BenQ display was restored to
MacBook Pro Speakers within ~3 s, and input switched to the iPhone
Continuity mic was restored to MacBook Pro Microphone. The user's stored
pins (Scarlett Solo USB / Yeti Nano, both disconnected at the time) and
the pre-test system defaults were restored afterwards and verified. The
waiting behavior for a disconnected pin was also observed live
(no forced switch).

Also completed since: real app icon (all sizes + `packaging/` sources),
native About panel from the popover plus an expanded Settings → About,
single-lookup device resolution for restores
(`kAudioHardwarePropertyDeviceForUID`), version 1.1.0, and
`scripts/make-dmg.sh` producing `AudioIOKeeper-1.1.0.dmg` (app +
Applications shortcut + `packaging/README.txt` + LICENSE; ad-hoc signed,
not notarized). The Downloads copy is synced with GitHub `main`; the
stale partial `KeeperEngine.swift` edits are gone, and
`audioiokeeper-stability-review.md` is committed (original file, with a
Resolution section) at the user's request.

## Environment gotchas (why the local build is outstanding)

This session's shell environment degraded mid-work; both issues are
machine/session state, not code:

1. **macOS TCC vs `~/Downloads`:** reads/writes intermittently return
   "Operation not permitted". The responsible process is **Terminal.app**
   (Muse CLI runs inside it; there is no "Muse Code" TCC entry).
   Fix: System Settings → Privacy & Security → Files and Folders →
   Terminal → enable Downloads Folder (or Full Disk Access), then
   **fully restart Terminal** — grants apply to fresh processes. Moving
   the repo out of `~/Downloads` (e.g. `~/Developer`) also sidesteps it.
   Symptom check: `cat audioiokeeper-stability-review.md` in the repo.
2. **Nested sandbox failure:** Swift builds died with
   `sandbox-exec: sandbox_apply: Operation not permitted` and
   `xcodebuild test` with "Failed to prevent system sleep" (-536870199).
   A fresh Terminal/session is expected to clear this. Until then,
   CI is the build/test gate of record.

Because of (1), this session's stability work was done in a clean clone at
`/tmp/AudioIOKeeper-work` and pushed from there. Consequences for the
Downloads copy:

- It is still at `6ba23bb` with **two uncommitted partial edits** to
  `KeeperEngine.swift` (an early draft of the throttle/status changes —
  fully superseded by `0c77bea`; discard with the checkout command above).
- `audioiokeeper-stability-review.md` (the review document, user-owned)
  sits **untracked** in that folder. It was read in full and implemented;
  it was NOT committed (don't commit a retyped copy; if the user wants it
  in the repo, commit the original file itself).

## Key files

| File | Role |
| --- | --- |
| `AudioIOKeeper/AudioIOKeeperApp.swift` | Entry point; AppDelegate starts keeper at launch |
| `AudioIOKeeper/AppModel.swift` | `@Observable` state, reconcile loop, enforcement, activity log |
| `AudioIOKeeper/KeeperEngine.swift` | Pure decisions: `KeeperEngine`, `RestoreThrottle`, `DirectionStatus` |
| `AudioIOKeeper/AudioHardwareWorker.swift` | Serialized async HAL queue, snapshots, ping coalescing |
| `AudioIOKeeper/AudioHardwareClient.swift` | Only file calling Core Audio C APIs |
| `AudioIOKeeper/SettingsStore.swift` | UserDefaults: pins (UIDs), keep toggles |
| `AudioIOKeeper/MenuContentView.swift` | Popover UI incl. Rescan, conflict state |
| `project.yml` | XcodeGen source of truth (run `xcodegen generate` after edits; CI enforces freshness) |
| `.github/workflows/ci.yml`, `.swiftlint.yml`, `.coderabbit.yaml` | CI gate, lint, auto-review config |

## Product decisions already made (don't re-litigate silently)

- Bundle ID `com.neuroccm.AudioIOKeeper`; MIT license; macOS 14 minimum.
- Disconnected pinned device: wait and restore on return, never substitute.
- During a competing-writer conflict, restoration is intentionally NOT
  instant (throttled) — documented in README.
- Branch protection on `main` intentionally left OFF (user's direct pushes
  must keep working); recommended to the user as optional.
- App icon: waveform + padlock, generated into
  `AppIcon.appiconset` (sources in `packaging/`); menu-bar icon is an SF
  Symbol status light. Public .app releases need a paid Developer ID for
  signing/notarization — not yet set up (DMG builds are ad-hoc signed).

## Suggested next steps after the local build

1. Open a small PR to prove CodeRabbit auto-review fires (user says the app
   is installed account-wide).
2. Design a real app icon.
3. Release build + notarization once a Developer ID is available;
   optionally wire `/tmp/audio_probe`-style checks into a manual QA note.
4. Delete this file or fold what's still relevant into `CONTRIBUTING.md`
   once the local build is done — it documents one session's state, not
   evergreen project docs.
