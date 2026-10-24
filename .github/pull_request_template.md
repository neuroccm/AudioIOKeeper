## What changed

<!-- One behavior change per PR. Say what and why. -->

## How it was verified

<!-- e.g. unit tests added/updated; manual check: switched default output
     away from the pin and watched it restore. -->

## Checklist

- [ ] `xcodebuild test` passes
- [ ] `swiftlint --strict` is clean
- [ ] Keeper behavior changes have matching unit tests
- [ ] No Core Audio calls outside `AudioHardwareClient.swift`
- [ ] Anything the keeper does is still visible in the activity log
