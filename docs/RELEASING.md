# MauLeaf release process

## Preview release

1. All feature work is merged into main through a pull request.
2. The build-release workflow runs the macOS 15 test job.
3. A successful push to main automatically creates the next vX.Y.Z-preview.N tag using VERSION.
4. The release build runs only on the Apple Silicon macos-15 runner and produces one arm64 DMG.
5. The workflow verifies the bilingual preview notes, app bundle, native helper, code signatures, and SHA-256 manifest before publishing a prerelease.

Preview 5 no longer builds, packages, or publishes Intel artifacts. The release pipeline also does not bundle batt or any third-party charging-control executable.

## Local build

On an Apple Silicon Mac with Xcode Command Line Tools installed, run:

    ./build.command

The script reads VERSION, invokes the same package script as GitHub Actions, and writes the arm64 DMG to dist/.

## Release notes

- Maintain the Chinese and English sections in docs/releases/PREVIEW_TEMPLATE.md.
- Document the exact preview behavior and hardware-validation boundaries.
- Do not claim that register read-back proves physical charging enforcement.
- State clearly that only Apple Silicon arm64 is supported and that Intel builds are discontinued.

## Safety checks

- The test workflow uses a fake SMC transport and never writes to physical hardware.
- New limit writes remain restricted to the validated MacBookPro18,1 / mBoot-20457.41.3 / macOS 15 / arm64 profile, AC power, and explicit confirmation.
- Original-state restore must retain its snapshot until all three firmware registers have been read back and verified.
- The uninstaller must not remove the helper, LaunchDaemon, or snapshot if restoration fails or AC power is unavailable.
- Legacy Preview 4 installations without a saved original snapshot must be described as best-effort deactivation only; historical thresholds cannot be reconstructed.
