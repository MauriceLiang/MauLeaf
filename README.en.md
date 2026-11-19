[简体中文](README.md) | [English](README.en.md)

> [!CAUTION]
> **Compatibility warning (2026-11-10): Current MauLeaf releases do NOT support macOS 26 or macOS 27. Do not install or continue relying on MauLeaf on either release.**
>
> Bundled **batt v0.8.0** has shown unsupported charging control and failed quit/GUI uninstall on macOS 27. **Already upgraded? Follow the [emergency removal guide](docs/MACOS_26_27_UNINSTALL.md#english) and [guarded uninstall script](Scripts/uninstall-macos26-27.sh).** macOS 26 is designated unsupported too; identical symptoms have not been verified on every device.

<p align="center">
  <img src="Assets/MauLeafIcon-1024.png" width="128" alt="MauLeaf leaf icon">
</p>

<h1 align="center">MauLeaf</h1>

<p align="center">A lightweight macOS menu bar app for charge management</p>

<p align="center">
  <a href="https://github.com/MauriceLiang/MauLeaf/releases/latest">Download</a> ·
  <a href="CHANGELOG.md">Changelog (Chinese)</a> ·
  <a href="https://github.com/MauriceLiang/MauLeaf/issues">Report an issue</a>
</p>

MauLeaf is a lightweight macOS menu-bar utility focused on two actions: set a daily charging limit, or temporarily charge to 100% once before heading out. The menu bar uses a green leaf by default.

Built with SwiftUI + AppKit, v0.8.0-preview.1 still uses the pinned open-source utility [batt](https://github.com/charlie0129/batt) for actual charging control. The in-house AppleSMC backend currently contains read-only probing, policy and transaction code, but real activation and charge-enforcement behavior have not yet been validated on the target Mac; it does not control charging in this preview. Previously named ChargeCap, the app adopts the MauLeaf name starting with v0.7.0.

## Features

| Feature | What it does |
| --- | --- |
| Charging limit | Adjust the limit from 50–95%, with quick presets and automatic application after slider changes. |
| One-time full charge | Temporarily release the limit and restore the saved limit after reaching 100%; cancellation is available. |
| Battery status | Show the current percentage and power-source state. |
| Green menu-bar leaf | Always use the green leaf; no percentage text or icon-style setting. |
| Minimal interface | Remove live power readings, active discharge, permanent full-charge mode, and login-item controls. |
| Installation and removal | Install the control component when needed; a separate uninstaller is included. |

> [!IMPORTANT]
> **This is a feature-simplification preview, not a batt-free release.** The native SMC backend has not yet passed real activation and charging-enforcement tests on the target M1 Pro. To keep charging controls functional, this preview temporarily retains batt v0.8.0 as its actual backend. Do not treat this build as the final native implementation.

## Requirements

- Apple Silicon (arm64): originally targeted macOS 13–15. **Current releases do NOT support macOS 26 or 27; do not install or continue using them.**
- Intel (x86_64) EXPERIMENTAL read-only preview: battery information only. Charging control, batt installation and removal are disabled. Intel charging hardware is **NOT validated**.
- Administrator authorization for the initial system component installation. Everyday operations use the installed service.
- On Apple Silicon, charging-control capabilities depend on batt's device report. The Intel preview is NOT a full-featured charging controller.

### Intel experimental preview disclaimer

**The maintainer currently has no Intel Mac available for testing. MauLeaf has not been installed, launched, or tested on physical Intel hardware.** A successful GitHub Actions compilation or automated check does **not** establish that the software works on Intel Macs. Actual behavior—including launch, UI, battery readings, installation, uninstallation, system compatibility, and stability—**is unknown**.

This is an **unverified experimental preview, not an officially supported Intel release**. To reduce risk, this build does not bundle batt and disables charging control and system-service installation or removal. Do not rely on it for critical or production battery management. Users who choose to download, install, or use this preview should independently assess compatibility and risks and back up important data.

The software is provided **AS IS**, without warranties of Intel compatibility, merchantability, fitness for a particular purpose, or error-free operation. To the extent permitted by applicable law, the developer disclaims liability for loss arising from use of the experimental preview. Nothing here excludes rights or liability that cannot legally be excluded, and the project's open-source licenses remain applicable.

## Installation

**Do NOT install this release on macOS 26 or 27.** Already upgraded? Use the [emergency removal guide](docs/MACOS_26_27_UNINSTALL.md#english) rather than relying on an affected in-app uninstall action.

1. From [GitHub Releases](https://github.com/MauriceLiang/MauLeaf/releases/latest), choose `MauLeaf-<version>-macos-arm64.dmg` (supported) or `MauLeaf-<version>-macos-x86_64-EXPERIMENTAL.dmg` (Intel read-only preview).
2. Open the DMG and drag `MauLeaf.app` to `Applications`. **Only the supported Apple Silicon DMG** also contains `Uninstall MauLeaf.app`; the Intel preview does not include an uninstaller.
3. The Apple Silicon preview can install bundled batt. The Intel preview contains no batt or uninstaller and disables all charging-control operations.
4. On Apple Silicon, you can select charging modes and limits. On the Intel experimental preview, only battery information is visible and charging settings are not available.
5. The interface defaults to Chinese. Click “English” at the bottom of the panel to switch to English, or “中文” to switch back. Your language choice is remembered on the next launch.

The current package is locally ad-hoc signed and has not been notarized by Apple, so macOS may block its first launch. After confirming the download source, follow the system prompts in System Settings → Privacy & Security to allow it to open.

MauLeaf does not overwrite batt installations from Homebrew or other sources. If an existing service is unavailable or lacks the necessary permissions, the app reports an error; resolve the existing installation first.

### Upgrading from ChargeCap

Quit ChargeCap normally before replacing it with MauLeaf. Your existing settings, installation receipt, and working batt service are reused, so the component does not need to be reinstalled. After confirming MauLeaf works, you can remove the old `ChargeCap.app`. Do not run both versions at the same time.

Some internal identifiers and data directories retain the old name for compatibility. See the [compatibility reference (Chinese)](docs/CHARGING.md#从-chargecap-升级的兼容约定).

## Everyday use

- **Daily limit:** Drag the slider or choose a 70%, 75%, 80%, 85%, 90%, or 95% preset. Slider changes are applied automatically after adjustment; the reported backend state is checked afterward.
- **One-time full charge:** Select “Charge to 100%”. The current limit is temporarily released and restored after the battery reaches 100%. You can cancel early with “Cancel and restore limit”.
- **Menu bar:** A green leaf is always shown. Click it to open the panel. Closing the panel does not cancel an active one-time charge task.

The panel keeps the current battery percentage and power-source state as supporting information, but no longer displays live power readings. Permanent full-charge mode, active discharge, and menu-bar style selection have been removed.

**Quitting the app** stops the one-time task and follows the current cleanup procedure. On the next launch, MauLeaf reapplies the saved charging limit. Closing the panel is not the same as quitting the app.

## Uninstallation

**On macOS 26/27, download and run [`Scripts/uninstall-macos26-27.sh`](Scripts/uninstall-macos26-27.sh)** instead of relying on the broken GUI uninstaller. The [entire script is also provided in the bilingual guide](docs/MACOS_26_27_UNINSTALL.md#完整卸载脚本可直接复制) for copying and review.

```bash
curl -fL --output mauleaf-uninstall.sh \
  https://raw.githubusercontent.com/MauriceLiang/MauLeaf/main/Scripts/uninstall-macos26-27.sh
bash mauleaf-uninstall.sh
```

Read the script and keep the Mac connected to power. **Do not run the whole script via `sudo bash`**; it requests specific privileges when required.

> [!WARNING]
> **macOS 26/27: Do not rely on the GUI uninstaller. Read the [emergency removal guide](docs/MACOS_26_27_UNINSTALL.md#english), inspect [Scripts/uninstall-macos26-27.sh](Scripts/uninstall-macos26-27.sh), and run it as a normal user.** It verifies backend ownership and restores adapter power before removing a verified managed service.

Quit MauLeaf normally, then run `Uninstall MauLeaf.app` from the installation image. If an older version left a login item registered, disable it separately in macOS System Settings → General → Login Items. The uninstaller first attempts to restore default charging control, then removes the app-managed component, tasks, settings, and both old and new main app names from `/Applications`. You can delete the uninstaller afterward. Externally installed copies of batt are preserved.

To remove only the control component while keeping MauLeaf, use the component removal action (`卸载组件`) in the main panel.

## Operating limits

- Force quitting, crashes, or power loss can bypass normal quit cleanup, leaving persistent charging limits in place. Relaunch the app and quit normally to release control.
- One-time full charging combines a temporary override in the pinned batt version with background checks about every 20 seconds. During sleep, it cannot guarantee immediate restoration at 100%; a 10-hour timed restoration provides a fallback.
- Active discharge depends on the system and control service remaining operational. Cutting adapter power with the lid closed may put a Mac using an external display to sleep. Timed restoration is not guaranteed to run immediately during sleep or while the service is stopped.
- Automated checks cover logic and offscreen layout. Real hardware charging/discharging, normal quit, physical power connection changes, sleep, and long-term energy use still need further validation. See the [technical reference (Chinese)](docs/CHARGING.md) for details.

## Local development

Run source regression tests:

```bash
git clone https://github.com/MauriceLiang/MauLeaf.git
cd MauLeaf
bash tests/run.sh
```

[GitHub Actions](https://github.com/MauriceLiang/MauLeaf/actions) builds and publishes both DMGs on `vX.Y.Z` tags using `Scripts/ci/package-macos.sh` (the deleted `build.command` is no longer needed). Versions are derived from tags. See [Releasing](docs/RELEASING.md).

Tests use a simulated control component and do not execute real hardware-control commands. They cover mode transitions, limit restoration, protection and quit flows, adaptive sampling, and feedback that does not shift the layout.

| Directory | Contents |
| --- | --- |
| `Sources/` | Main app, charging logic, and independent background checkers |
| `Assets/` | Application icon and menu bar assets |
| `tests/` | Logic, simulated backend, and offscreen layout regression checks |
| `Vendor/` | Pinned component version and third-party license |
| `docs/` | Operating reference, icon guide, and release records |

Documentation (Chinese): [Charging behavior](docs/CHARGING.md) · [Building and releasing](docs/RELEASING.md) · [Icon guide](docs/ICON_GUIDE.md). When reporting an issue, include your macOS version, chip model, app version, reproduction steps, and error details. Remove personal information before submitting.

## License and acknowledgments

MauLeaf is licensed under the [Apache License 2.0](LICENSE). The original ChargeCap [MIT notice](LICENSES/ChargeCap-Original-MIT.txt) is retained.

Thanks to [charlie0129/batt](https://github.com/charlie0129/batt) for the underlying control functionality. The bundled component is pinned to `v0.8.0`, invoked as a separate CLI utility, and remains under its [GPL-2.0 license](Vendor/BATT-LICENSE.txt). A corresponding source archive is included with each Release. The project license does not change the component's license.
