# Contributing to Audio IO Keeper

Thanks for helping keep everyone's audio devices put.

## Development setup

Requirements: macOS 14+, Xcode 16+, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
git clone https://github.com/neuroccm/AudioIOKeeper.git
cd AudioIOKeeper
xcodegen generate
open AudioIOKeeper.xcodeproj
```

`project.yml` is the source of truth for the Xcode project. If you change it,
re-run `xcodegen generate` and commit the regenerated project.

## Before opening a pull request

1. Build and run the tests:

   ```sh
   xcodebuild test -scheme AudioIOKeeper -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
   ```

2. Run SwiftLint (`brew install swiftlint`):

   ```sh
   swiftlint
   ```

3. If you changed keeper behavior, add or update the unit tests in
   `AudioIOKeeperTests/`. The decision logic in `KeeperEngine` is pure and
   hardware-free on purpose — keep it that way, and keep all Core Audio calls
   inside `CoreAudioHardwareClient`.

## Pull requests

- Every PR is automatically reviewed by
  [CodeRabbit](https://www.coderabbit.ai/); please respond to its comments or
  explain why a suggestion does not apply.
- CI (build, unit tests, SwiftLint) must be green.
- Keep PRs focused: one behavior change per PR, with a clear description of
  what changed and how you verified it.
- Match the existing style: Swift 6, strict concurrency clean, no force
  unwraps, documented public APIs.

## Project principles

- **Never break the system.** Only public Core Audio default-device
  properties are touched. No private APIs, drivers, or extensions.
- **Never fight the user.** A choice made inside the app updates the pin;
  only automatic system switches are reverted.
- **Never act invisibly.** Anything the keeper does must appear in the
  activity log and the unified log.
- **Wait, don't thrash.** A disconnected pinned device is waited for, never
  substituted silently.
