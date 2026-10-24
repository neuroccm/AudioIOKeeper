# Audio IO Keeper: system stability review

Reviewed commit: `3ff97034e82b9453d2de02f87a3d15d8647f1775` (version 1.1.0), 2026-10-24. Clean repository; no code changes made.

## Summary

No critical or high-severity defect, direct kernel-panic mechanism, or demonstrated whole-system crash was found. Two medium-severity concerns remain. Both affect defensive behavior around an unhealthy audio subsystem or a competing default-device writer.

The earlier review in the repository covers an older revision. Its principal issues have been substantially addressed: normal reads/writes use a serial background worker, notifications are coalesced, the stream buffers one ping, reconciliation is serialized, restore attempts have a throttle, and the visible activity log is capped at 12 entries. The findings below concern gaps in the current implementation.

## Findings

### 1. Medium: listener registration can still block the main thread

Locations: `AudioIOKeeper/AudioHardwareWorker.swift:67–75`; `AudioIOKeeper/AudioHardwareClient.swift:163–188`; `AudioIOKeeper/AppModel.swift:69–80`.

At launch, the main-actor app delegate calls `AppModel.start()`. That calls `worker.start()` synchronously, which immediately calls `client.addChangeListener()`. Installation invokes `AudioObjectAddPropertyListenerBlock` three times on the calling thread. None of these registrations is dispatched to the worker queue. Supplying `listenerQueue` selects the queue for subsequent callbacks; it does not move registration itself onto that queue.

If a registration blocks while HAL initializes or waits on the audio service, launch and the main event loop block with it. The menu and Quit action cannot respond during that call. This is a conditional application hang risk; it is not evidence of a system crash or kernel panic. No stalled registration was reproduced.

The README states, “No synchronous Core Audio call ever runs on the main thread, so a stalled driver can't freeze the menu or the Quit button.” Startup does not fully satisfy that contract.

Recommendation: enqueue listener installation on the existing serial hardware queue, before the initial snapshot. Preserve the install-once guard and callback coalescing. Add a worker test with gated listener installation to verify that starting the model returns without waiting for registration.

### 2. Medium: sustained conflicts repeatedly reduce the restore cooldown

Locations: `AudioIOKeeper/KeeperEngine.swift:87–105,108–110,138–140`.

The exponential backoff exponent is calculated from the number of restores remaining in a rolling 60-second window. During a continuous conflict, the older attempts expire as cooldowns grow. That reduces the exponent even though the pin has never stayed selected and no user reset occurred.

A portable translation of the current policy, with a competitor switching away immediately after each restore and a 50 ms notification debounce, produces initial cooldowns of:

`2, 4, 8, 16, 32, 4, 4, 8, 8, 16, 16, 32, 2, …` seconds.

Over one simulated hour it issues 294 restore attempts, including 49 in the final ten minutes. The cooldown never reaches the configured 60-second cap in this scenario. These are modeled attempts, not measured HAL operations or CPU consumption.

This is still much safer than the previous unthrottled loop. However, persistent competition continues to cause more system audio reconfiguration than the documented growing backoff suggests, with recurring short intervals and potential audio interruptions. There is no evidence from this review that this rate alone exhausts resources or causes a panic.

Recommendation: track the escalation level separately from the rolling immediate-retry budget. Preserve escalation during an unresolved conflict and reset it after a verified stable period or a deliberate user change. Add a long-duration simulated-clock test crossing several rolling-window boundaries; the current tests primarily cover initial exhaustion and the first retry.

## Kernel panics and resource use

The application has no audio render/capture loop, driver, kernel/system extension, private API, network client, or direct kernel-memory access. Its system writes select public default-device properties. Manual inspection found no additional high-confidence memory-corruption path, unbounded automatic task accumulation, or busy polling loop in normal use.

Using public APIs does not rule out triggering a macOS or third-party driver defect. Diagnosing a reported kernel panic requires the actual panic report and device/driver details; this review provides no evidence attributing one to this app.

## Verification and limitations

- Manually reviewed every application and test Swift source, including unsafe HAL pointer handling, locking, asynchronous work, listener lifetime, throttling, settings, UI actions, and retained collections. Also inspected README, contribution rules, prior stability review, handover, entitlements, project configuration, packaging script, and CI.
- Portable throttle model passed its reproduction assertions under Python 3.14.4 on Ubuntu 26.04.1. Reproduce from the repository root with `python3 /path/to/throttle-review-model.py`. This is a translation of the policy, not a Swift test or a performance benchmark.
- Native build, unit tests, SwiftLint, Instruments profiling, hot-plug/wake checks, and stalled-driver testing are blocked here: the Linux host has no Xcode/macOS SDK, Swift, or SwiftLint. Historical macOS results in HANDOVER.md were read as context and were not rerun.
- CodeRabbit automated review is blocked: CLI 0.9.0 reports signed out. No automated review pass completed.
- Source files remain unchanged. No commit or remote write was made.
