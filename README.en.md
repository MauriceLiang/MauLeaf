[简体中文](README.md) | [English](README.en.md)

> [!CAUTION]
> **This preview only targets Apple Silicon, macOS 15, and the explicitly validated hardware profile. Charging control is unsupported on macOS 26/27, Intel, and other unverified models.**

<p align="center">
  <img src="Assets/MauLeafIcon-1024.png" width="128" alt="MauLeaf leaf icon">
</p>

<h1 align="center">MauLeaf</h1>

<p align="center">A lightweight, native macOS menu-bar charging utility</p>

<p align="center">
  <a href="https://github.com/MauriceLiang/MauLeaf/releases">Download Preview</a> ·
  <a href="CHANGELOG.md">Changelog</a> ·
  <a href="https://github.com/MauriceLiang/MauLeaf/issues">Report an issue</a>
</p>

MauLeaf keeps only two charging actions: set a daily charge limit, or charge to 100% once. The menu bar always displays a green leaf.

**This preview removes the third-party charging backend completely.** It contains no batt executable, third-party firmware assets, or batt invocation code. Charging settings are handled by MauLeaf's own AppleSMC controller through a bundled privileged native service.

## Features

| Feature | Description |
| --- | --- |
| Charging limit | 50–95%, with a slider and 70/75/80/85/90/95% presets |
| One-time full charge | Temporarily disable the firmware limit; restore it at 100%, on cancellation, or after a 10-hour deadline |
| Battery status | Show current percentage and power-source state |
| Menu bar | Fixed green leaf; no percentage text or style selector |

There are no live-power cards, active-discharge mode, permanent full-charge mode, login-item controls, or third-party control-component installer UI.

## Hardware scope and safety

The initial target profile is:

- Model: MacBookPro18,1 (Apple M1 Pro)
- OS: macOS 15
- Firmware: mBoot-20457.41.3
- AppleSMC registers: `bfF0`, `bfD0`, and `bfE0`

Before writing, the helper checks the model, firmware, OS, register metadata, AC power, and explicit user consent. Every write is read back; failures trigger an attempt to restore the previous state. **Writes are blocked when AC power is disconnected or the hardware profile does not match.**

> [!IMPORTANT]
> Native control is connected to the app, but the actual stop and resume percentages still require AC-powered testing on the target M1 Pro. A successful register write and read-back do not prove that the battery will actually stop charging at the selected percentage. Treat this as a hardware-validation preview, not a verified battery-management release.

On first launch, the app requests administrator authorization once to install MauLeaf's own AppleSMC privileged service. The service is built from this repository and is not batt; it does not expose a generic SMC write interface. The old “Install control component” card is removed.

## Installation

1. Download the Apple Silicon `MauLeaf-<version>-macos-arm64.dmg` from [GitHub Releases](https://github.com/MauriceLiang/MauLeaf/releases).
2. Drag `MauLeaf.app` into Applications and launch it.
3. On first launch, approve installation of the MauLeaf native firmware service when macOS asks.
4. Wait until the native firmware limit is reported as available, then connect AC power before changing the limit.

The Intel package is an untested read-only experiment. It contains no privileged native service and provides no charging control. macOS 26/27 are outside the supported range.

### Upgrading from an older release

If an earlier MauLeaf release installed a third-party charging-control service, remove that old service using the uninstaller from the older release before installing this preview. The new app does not invoke, detect, overwrite, or automatically uninstall control software from other sources.

## Everyday use

- **Charging limit:** Connect AC power, then move the slider or choose a preset. The first write requires one explicit native-firmware confirmation.
- **One-time full charge:** Select “Charge to 100%”. The native helper monitors the battery and restores the saved limit at 100% or after 10 hours. If the task finishes while unplugged, the restore job remains pending until AC power is connected again.
- **Quitting the app:** A configured firmware limit remains active in system firmware. The one-time restore task is managed independently by the MauLeaf privileged service.

## Uninstall the native service

First make sure no one-time restore job is pending, then run the bundled script:

```bash
sudo "/Applications/MauLeaf.app/Contents/Resources/MauLeafNativeControl/uninstall-native-firmware-helper.sh"
```

The script removes only MauLeaf's own LaunchDaemon and helper. It does not rewrite the current firmware limit. You can then move `MauLeaf.app` to the Trash.

## Development and tests

```bash
git clone https://github.com/MauriceLiang/MauLeaf.git
cd MauLeaf
bash tests/run.sh
```

Automated tests use an in-memory fake SMC transport and do not write to real hardware. GitHub Actions builds releases; preview tags use `vX.Y.Z-preview.N`.

## Project layout

| Directory | Contents |
| --- | --- |
| `Sources/` | SwiftUI menu-bar app, AppleSMC transaction controller, privileged XPC service |
| `Support/` | Native LaunchDaemon configuration |
| `Scripts/` | Native service install/uninstall and CI packaging |
| `Tools/` | Read-only hardware probe and isolated validation tools |
| `tests/` | Firmware transactions, helper, restore-job, and UI regression tests |
| `docs/` | Hardware boundaries, charging behavior, and release notes |

## License

MauLeaf is licensed under [Apache License 2.0](LICENSE), retaining the original ChargeCap [MIT notice](LICENSES/ChargeCap-Original-MIT.txt). This preview no longer bundles third-party charging-control software or firmware assets.
