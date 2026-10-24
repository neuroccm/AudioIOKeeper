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

## The one outstanding task

**Build & run the current code (`0c77bea`) locally on the user's Mac and
re-run the live switch-and-restore check.** CI proves the code builds and
tests pass; the new build has not yet run on real hardware. The app
process currently running on the Mac (if still alive) is the OLD ad-hoc
Debug build from `/tmp/AudioIOKeeperDerived/` — quit it before launching
the new build.

Exact sequence for the next session:

```sh
cd /Users/houman/Downloads/AudioIOKeeper
git checkout -- AudioIOKeeper/KeeperEngine.swift   # discard stale partial edits (see below)
git pull                                            # -> 0c77bea or later
xcodegen generate
xcodebuild test -project AudioIOKeeper.xcodeproj -scheme AudioIOKeeper \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project AudioIOKeeper.xcodeproj -scheme AudioIOKeeper \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" \
  -derivedDataPath /tmp/AudioIOKeeperDerived
pkill -x AudioIOKeeper || true
open /tmp/AudioIOKeeperDerived/Build/Products/Debug/AudioIOKeeper.app
/tmp/audio_probe | grep DEFAULT                    # note current defaults
/tmp/audio_probe set-output BuiltInSpeakerDevice   # simulate auto-switch
sleep 2 && /tmp/audio_probe | grep DEFAULT         # expect pin restored
```

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
- App icon is still a placeholder (empty iconset); menu-bar icon is an SF
  Symbol status light. Public .app releases need a paid Developer ID for
  signing/notarization — not yet set up.

## Suggested next steps after the local build

1. Open a small PR to prove CodeRabbit auto-review fires (user says the app
   is installed account-wide).
2. Design a real app icon.
3. Release build + notarization once a Developer ID is available;
   optionally wire `/tmp/audio_probe`-style checks into a manual QA note.
4. Delete this file or fold what's still relevant into `CONTRIBUTING.md`
   once the local build is done — it documents one session's state, not
   evergreen project docs.
