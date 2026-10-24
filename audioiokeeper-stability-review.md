# Audio IO Keeper: resource and stability review

Reviewed revision: `6ba23bb6c97aaf6794a7dd5679d33ef0b404369d` (clean working tree).

## Findings

### 1. High: conflicting default-device changes can cause indefinite restore thrashing

**Locations:** `AudioIOKeeper/AppModel.swift:62–69,94–115`; `AudioIOKeeper/KeeperEngine.swift:31–40`.

The engine only checks whether the current default differs from an available pin. Every subsequent change notification can trigger the same restore again after the 50 ms debounce. There is no restore budget, cooldown, escalation, or backoff. The current-equals-pin check prevents a loop from the app's own notification when the default stays put, but does not prevent a loop when another utility, an automation, or hardware policy keeps switching it back. A successful property write is also not proof that the device will remain selected.

**Trigger:** keep the pinned device present/alive while another component repeatedly reasserts a different system default. Each side's write can trigger the other indefinitely.

**Impact:** repeated system audio reconfiguration, possible audio interruptions, repeated full device enumeration and unified logging, and sustained work in the app and audio subsystem. The activity log itself is bounded to 12 entries; this finding is about repeated work, not an unbounded log array. Actual CPU or energy consumption was not measured.

**Evidence:** a deterministic Python model of the existing decision and debounce flow settles after one restore with only its own notification. With another writer changing the default 10 ms after each restore, it performs 1,000 restores in 60 simulated seconds and 2,000 in 120 seconds. This demonstrates the missing stop condition; it is not an execution of Swift or CoreAudio.

**Recommendation:** add per-direction tracking of repeated drift, bounded immediate retries, and increasing cooldowns; show the conflict in the UI and retry at a controlled rate. This qualifies the README's immediate-restoration promise during persistent conflicts and should be documented explicitly. Test a successful write followed by another change, not only a fake that accepts and retains the new default. The existing fake does not emit the app's own write notifications or model competing writers.

### 2. Medium: synchronous HAL calls can freeze the app and allow callback tasks to accumulate

**Locations:** `AudioIOKeeper/AppModel.swift:21,51–53,72–76,103–105,123–134`; `AudioIOKeeper/AudioHardwareClient.swift:36–38,49–57,79–110,168–207`.

`AppModel` is isolated to the main actor. Startup, refresh, device selection, and enforcement all synchronously call the CoreAudio client there. Enumeration performs multiple HAL property queries for every device; every restore enumerates the devices again before writing the default. Moving notifications onto a listener queue does not move these actual queries or writes off the main thread.

**Trigger:** a slow or unresponsive HAL/audio-driver operation during enumeration or a default-device change.

**Impact:** that operation blocks the menu UI, including Keep and Quit controls, for its duration. There is no application-level containment of a stalled call. Notifications each create a new main-actor task before debounce runs, so notifications arriving while the main thread is blocked can also queue up. A native hang or memory increase was not reproduced on this Linux host.

**Recommendation:** serialize synchronous HAL reads and writes on a dedicated worker, send completed snapshots to the main actor, and coalesce notifications before creating UI tasks. Preserve ordering and reject stale results so an older operation cannot overwrite a newer pin selection. A Swift task timeout alone cannot cancel a C call that is already blocked.

## Kernel panics and other checks

No direct kernel-panic mechanism or demonstrated whole-system crash was found. The application contains no driver, kernel/system extension, audio streaming, or direct kernel-memory access. It uses public CoreAudio default-device APIs and enables App Sandbox. This does not prove that a macOS or third-party driver bug cannot be triggered by device switching; diagnosing a specific panic requires its panic report and hardware/driver context.

Manual inspection covered every application and test Swift file, CoreAudio pointer/buffer handling and return-status checks, listener ownership and locking, task scheduling, retained collections, settings, entitlements, project settings, and CI. Normal operation is event driven, not continuously polled. The UI activity log is capped at 12, listeners are installed once per client, and callbacks capture the client/model weakly. No additional high-confidence crash or major resource issue was identified in these paths.

## Verification and limits

- Portable adversarial logic model: passed the ordinary self-notification, sustained competing-writer, and bounded activity-log scenarios. Python 3.14.4; no real device or driver was exercised.
- Native command attempted: `xcodebuild test -scheme AudioIOKeeper -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`. Blocked: `xcodebuild` unavailable (exit 127); the host is Ubuntu, without macOS SDKs.
- Native app build, Swift unit tests, Instruments CPU/memory measurements, hot-plug/wake testing, and kernel stability testing remain unverified. The findings are static risks, not confirmed macOS failures.
- No repository code was changed.

## Resolution

Both findings were addressed on `main` (stability implementation plus the
1.1.0 release polish that committed this document):

- **Finding 1 (restore thrashing):** a per-direction `RestoreThrottle`
  (`AudioIOKeeper/KeeperEngine.swift`) allows 3 immediate restores per
  rolling 60 s window, then imposes exponential cooldowns (2 s doubling,
  capped at 60 s) with exactly one retry per served cooldown. Sixty
  seconds with the pin stably in place, a new in-app selection, or toggling
  keeping resets it. While throttled, the popover shows a conflicted state.
  The README qualifies the immediate-restoration behavior during
  persistent conflicts. The test fake emits the app's own write
  notifications, and `testCompetingWriterIsThrottledNotFoughtForever`
  drives a competing writer that reasserts its default after every restore.
- **Finding 2 (synchronous HAL on the main actor):** all Core Audio reads
  and writes run on a dedicated serialized queue in
  `AudioIOKeeper/AudioHardwareWorker.swift`, off the main thread;
  `AppModel` only applies finished, sequence-numbered snapshots and
  rejects stale ones, so a slow read cannot overwrite a newer pin.
  Change notifications are coalesced/debounced in the worker into a
  single ping before any main-actor work is spawned. Restores also no
  longer re-enumerate all devices: the target is resolved in one
  `kAudioHardwarePropertyDeviceForUID` lookup
  (`AudioIOKeeper/AudioHardwareClient.swift`). As noted in the review, a
  HAL call already blocked in C still cannot be cancelled — it now stalls
  only the worker queue, not the UI.

Verification: full unit suite and SwiftLint pass locally on macOS and in
CI; the current build was additionally run on real hardware with an
external switch-and-restore probe (see `HANDOVER.md`). Instruments
CPU/memory measurements and stalled-driver behavior remain unmeasured.
