[简体中文](README.md) | [English](README.en.md)

> [!CAUTION]
> **The native preview targets Apple Silicon, macOS 15, and the validated MacBookPro18,1 / mBoot-20457.41.3 hardware profile only. Intel builds are discontinued. macOS 26/27 and other unverified environments cannot enable new charging limits. Restoration of a saved original state uses a separate hardware-identity check.**

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

MauLeaf keeps only daily charging limits and one-time full charge. The menu bar always displays a green leaf.

This preview uses MauLeaf's own AppleSMC controller and bundled privileged native service. It contains no batt executable, third-party firmware assets, or third-party control invocations.

## Features

| Feature | Description |
| --- | --- |
| Opt-in limit control | Limits are off on first launch; the user must select “Enable charging limit” before firmware is changed |
| Charging limit | 50–95%, with a slider and 70/75/80/85/90/95% presets; while disabled, changes are saved locally only |
| Disable limit | Restore the original bfF0, bfD0, and bfE0 values captured before activation; remove the snapshot only after read-back verification |
| One-time full charge | Temporarily disable the current limit; restore it at 100%, on cancellation, or after a 10-hour deadline |
| Battery status | Show current percentage and power-source state |
| Menu bar | Fixed green leaf; no percentage text or style selector |

There are no live-power cards, active-discharge mode, permanent full-charge mode, login-item controls, or third-party control-component installer UI.

## Original firmware state and uninstall safety

When the limit is enabled for the first time, the root helper reads all three registers and saves their original values, device model, system firmware, and architecture to:

    /Library/Application Support/MauLeaf/original-firmware-state.json

The snapshot is root-owned with mode 0600 and is stored outside the app bundle. Changing the charging limit never overwrites this original snapshot.

- **Disable charging limit:** The helper disables the limit, restores the original upper threshold, resume threshold, and activation byte, then verifies all three values before deleting the snapshot.
- **Complete uninstall:** After normal app quit, the bundled uninstaller restores the exact original bfF0/bfD0/bfE0 registers on either AC or verified battery-only power, then independently rechecks the SMC state and pending jobs before deleting the app, privileged Helper, LaunchDaemon, recovery files, and every bundled install/uninstall/recovery script.
- **No AC power:** Immediate full restore is enabled only on the physically verified MacBookPro18,1, mBoot-20457.41.3, macOS 15, arm64. IOKit and pmset must both confirm battery-only supply, battery level must be >=30%, charging inactive, and the original inactive snapshot must be valid. If any step fails, the app, helper, and snapshot are retained for a later safe retry; an incomplete uninstall is never reported as success.
- **OS upgrades:** Restoration is allowed only when the model, system firmware, and Apple Silicon architecture still match the snapshot. A saved original state can therefore be restored even if the new OS blocks enabling new limits.

**Preview 4 and earlier releases did not save the pre-activation thresholds.** If an upgraded installation has an active limit but no snapshot, MauLeaf displays a migration warning. Disabling that legacy state clears only the activation flag and keeps the current thresholds; the historical values cannot be reconstructed. If Preview 5 is enabled again afterward, those retained values become the new snapshot baseline. They represent the currently readable state, not the true values from before Preview 4.

## Hardware scope and safety

The currently validated write target is:

- Model: MacBookPro18,1 (Apple M1 Pro)
- OS: macOS 15
- Firmware: mBoot-20457.41.3
- Architecture: arm64
- AppleSMC registers: bfF0, bfD0, and bfE0

Before enabling or changing a charging limit, the helper checks the model, firmware, OS, register metadata, AC power, and explicit user consent. Every write is read back; failures trigger an attempt to restore the previous state. New limit writes are blocked without AC power or when the hardware profile does not match.

> [!IMPORTANT]
> The actual charge-stop and resume percentages still require AC-powered testing on the target M1 Pro. A successful register write and read-back do not prove that the battery will stop charging at the selected percentage. Treat this as a hardware-validation preview, not a verified battery-management release.

On first launch, the app requests administrator authorization to install MauLeaf's own AppleSMC privileged service. The service is built from this repository and does not expose a generic SMC write interface.

## Installation

1. Download MauLeaf-<version>-macos-arm64.dmg from [GitHub Releases](https://github.com/MauriceLiang/MauLeaf/releases).
2. Drag MauLeaf.app into Applications and launch it.
3. On first launch, approve installation of the MauLeaf native firmware service when macOS asks.
4. Select a charging limit, connect AC power, and click “Enable charging limit”.

Only Apple Silicon arm64 packages are built and published. Intel builds are discontinued.

## Everyday use

- **While disabled:** Moving the slider or choosing a preset only saves the local preference; no firmware register is written.
- **Enable charging limit:** Click the prominent “Enable charging limit” button. The first hardware write requires explicit confirmation, and the helper saves the original snapshot first.
- **Change the limit:** Once enabled, the slider and presets apply immediately without overwriting the original snapshot.
- **Disable charging limit:** Click “Disable charging limit” to restore the three original register values.
- **One-time full charge:** Available only while a MauLeaf limit is enabled. When the one-time task finishes, the current MauLeaf limit is restored. You can then disable the limit to restore the original snapshot.
- **Quit normally:** Restore the original registers immediately on AC or on the validated battery-only profile under its additional safeguards. If battery-only recovery is unavailable, preserve a durable pending recovery request and helper. A **Quit anyway** option may remain available for failures, but it is not a completed safe uninstall. Forced deletion and crashes cannot guarantee firmware restoration.

## Complete uninstall — AC and battery power

First launch the latest preview once to ensure the installed privileged Helper has been upgraded. Then quit MauLeaf **normally** from its menu bar. Run this single command from Terminal:

```bash
sudo "/Applications/MauLeaf.app/Contents/Resources/MauLeafNativeControl/uninstall-native-firmware-helper.sh"
```

The command restores the **exact original firmware state**, independently verifies bfF0 is inactive and no unfinished job remains, then removes `/Applications/MauLeaf.app`, the root-owned privileged Helper, LaunchDaemon, saved recovery state, and **every installed MauLeaf install/uninstall/finalizer script**. There is no need to manually drag the app to the Trash after success.

AC power is not required on the exact verified M1 Pro/macOS 15 firmware profile when both power-source sensors agree, the battery is >=30%, it is not charging, and the original snapshot was inactive and matches the current machine. If restoration or verification fails, the script exits with an error **without deleting the app or recovery components**. Connect AC or diagnose the underlying issue and retry. There is no force-delete-without-restore option.

Preview 4 and earlier did not capture the historical thresholds; unknown original values cannot be reconstructed. Directly deleting the app or privileged service in Finder does not invoke the restore transaction and cannot be guaranteed safe.

## Development and tests

    git clone https://github.com/MauriceLiang/MauLeaf.git
    cd MauLeaf
    bash tests/run.sh

Automated tests use an in-memory fake SMC transport and do not write to real hardware. GitHub Actions builds releases; preview tags use vX.Y.Z-preview.N.

## Project layout

| Directory | Contents |
| --- | --- |
| Sources/ | SwiftUI menu-bar app, AppleSMC transaction controller, privileged XPC service |
| Support/ | Native LaunchDaemon configuration |
| Scripts/ | Native service install/uninstall and CI packaging |
| Tools/ | Read-only hardware probe and isolated validation tools |
| tests/ | Firmware transactions, snapshot restore, helper, and UI regression tests |
| docs/ | Hardware boundaries, charging behavior, and release notes |

## License

MauLeaf is licensed under [Apache License 2.0](LICENSE), retaining the original ChargeCap [MIT notice](LICENSES/ChargeCap-Original-MIT.txt). This preview does not bundle third-party charging-control software or firmware assets.
