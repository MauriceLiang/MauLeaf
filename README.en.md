[简体中文](README.md) | [English](README.en.md)

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

MauLeaf lets you set a charging limit for a Mac that usually stays plugged in, and charge it fully before heading out. A leaf in your menu bar gives you access to charging modes, battery power readings, and options for handling a battery level above your limit, without repeatedly entering terminal commands.

Built with SwiftUI + AppKit, MauLeaf uses the bundled open-source utility [batt](https://github.com/charlie0129/batt) for low-level charging control. Previously named ChargeCap, the app adopts the MauLeaf name starting with v0.7.0.

## Features

| Feature | What it does |
| --- | --- |
| Charging limits | Set a limit between 50% and 95%. Presets apply immediately; slider changes apply automatically after you stop dragging. |
| Full charging on demand | Charge fully once, then restore your previous limit, or continuously allow charging to 100%. |
| Above-limit handling | Keep using the power adapter, or actively use the battery until it reaches your limit. The latter requires device support. |
| Battery power readings | View charging and discharging power with adaptive refresh while the panel is open. Extra power sampling stops when the panel closes. |
| Launch at login | Opt in or out yourself. No login item is registered by default; the switch reflects system registration. |
| One-click language switching | Click “English” or “中文” at the bottom of the panel to switch immediately. Your choice is saved. |
| Compact menu bar interface | Choose a monochrome or green leaf, click outside to dismiss the panel, and see operation feedback at the bottom without shifting controls. |
| Release control on normal quit | Restore adapter power and remove the charging limit before quitting, with verification. Saved settings are reapplied on the next launch. |
| Graphical installation and removal | Install the bundled, pinned control component through macOS authorization. A separate uninstaller is included. |

Active battery discharge has protection for a closed lid, abnormal temperature, invalid safety readings, and timeout. It pauses after a one-time full charge to avoid immediately draining the battery you just charged. See [Charging behavior and operating limits (Chinese)](docs/CHARGING.md) for details.

## Requirements

- Apple Silicon (arm64) supported release: macOS 13+.
- Intel (x86_64) EXPERIMENTAL read-only preview: battery information only. Charging control, batt installation and removal are disabled. Intel charging hardware is **NOT validated**.
- Administrator authorization for the initial system component installation. Everyday operations use the installed service.
- On Apple Silicon, charging-control capabilities depend on batt's device report. The Intel preview is NOT a full-featured charging controller.

## Installation

1. From [GitHub Releases](https://github.com/MauriceLiang/MauLeaf/releases/latest), choose `MauLeaf-<version>-macos-arm64.dmg` (supported) or `MauLeaf-<version>-macos-x86_64-EXPERIMENTAL.dmg` (Intel read-only preview).
2. Open the DMG, drag `MauLeaf.app` into `Applications`, and launch it. The image also includes `Uninstall MauLeaf.app`.
3. The Apple Silicon release can install bundled batt. The Intel preview contains no batt or uninstaller and disables all charging-control operations.
4. Select a charging mode and limit. Results appear at the bottom of the panel. Status updates automatically on launch and whenever you open the panel.
5. The interface defaults to Chinese. Click “English” at the bottom of the panel to switch to English, or “中文” to switch back. Your language choice is remembered on the next launch.

The current package is locally ad-hoc signed and has not been notarized by Apple, so macOS may block its first launch. After confirming the download source, follow the system prompts in System Settings → Privacy & Security to allow it to open.

MauLeaf does not overwrite batt installations from Homebrew or other sources. If an existing service is unavailable or lacks the necessary permissions, the app reports an error; resolve the existing installation first.

### Upgrading from ChargeCap

Quit ChargeCap normally before replacing it with MauLeaf. Your existing settings, installation receipt, and working batt service are reused, so the component does not need to be reinstalled. After confirming MauLeaf works, you can remove the old `ChargeCap.app`. Do not run both versions at the same time.

Some internal identifiers and data directories retain the old name for compatibility. See the [compatibility reference (Chinese)](docs/CHARGING.md#从-chargecap-升级的兼容约定).

## Everyday use

- **Usually plugged in:** Choose control mode (`控制模式`) and set a limit. If the battery is already above the limit, the default behavior keeps using adapter power and lets the battery level decrease naturally.
- **Heading out:** Choose full charging → charge fully once (`直接充满 → 仅充满一次`). The previous limit is restored at 100%, and you can cancel at any time.
- **Always need a full battery:** Choose full charging → continuously allow full charging (`直接充满 → 持续允许充满`). Returning to control mode restores your saved limit.
- **Actively reduce the battery level:** Select the corresponding strategy in control mode. Adapter power is restored when the target is reached or a protection condition is triggered. You can manually resume after a pause.

The battery ring shows a lightning bolt while charging, a plug when connected to power without charging, and the app’s leaf silhouette in its original orientation while using the battery. Low Power Mode is indicated by the ring color and status text.

With the panel open, power readings update about every 2 seconds while charging or discharging, and every 5 seconds while idle. Closing the panel stops extra sampling; background status checks and safety monitoring continue. These are battery-side readings, **not charger input power**. A dash (`—`) appears when the system provides no valid data.

**Closing the panel and quitting the app are different actions.** A normal quit waits for ongoing operations, stops tasks, and verifies that charging control has been released. If cleanup fails, the app keeps the error visible and lets you try quitting again. The batt service stays installed with no charging limit.

### Launch at login

Turn “Launch at login” on or off below the menu bar icon settings. The app does not register itself by default; if a registration already exists, its system state is shown. Install MauLeaf in `Applications` before enabling this option.

This launches the app after you log in to your Mac. Quitting normally preserves your choice. If approval is pending, click “Manage Login Items” and allow MauLeaf in System Settings before it can launch automatically. Turn the switch off at any time to unregister it. The app refreshes the status when you return from System Settings.

This uses the native macOS [SMAppService login item API](https://developer.apple.com/documentation/servicemanagement/smappservice).

## Uninstallation

If launch at login is enabled, turn it off first. Quit MauLeaf normally, then run `Uninstall MauLeaf.app` from the installation image. The uninstaller first attempts to restore default charging control, then removes the app-managed component, tasks, settings, and both old and new main app names from `/Applications`. You can delete the uninstaller afterward. Externally installed copies of batt are preserved.

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
