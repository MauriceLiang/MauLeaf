[简体中文](README.md) | [English](README.en.md)

<p align="center">
  <img src="Assets/MauLeafIcon-1024.png" width="120" alt="MauLeaf">
</p>

<h1 align="center">MauLeaf</h1>

<p align="center">A lightweight native macOS menu-bar charging utility</p>

<p align="center">
  <a href="https://github.com/MauriceLiang/MauLeaf/releases/latest">Download stable release</a> ·
  <a href="https://github.com/MauriceLiang/MauLeaf/issues/new?template=bug_report.md">Report a problem</a> ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

MauLeaf uses SwiftUI + AppKit and its own AppleSMC controller for two focused features: **charging limits** and **one-time full charge**. It lives in the menu bar as a green leaf, with no detached main window and no batt dependency.

> [!CAUTION]
> **A stable release does not imply universal hardware support.** New firmware charging-limit writes are restricted to **MacBookPro18,1 (M1 Pro) + macOS 15 + mBoot-20457.41.3 + arm64**. macOS 26/27, Intel, and unverified devices cannot activate new limits. Battery viewing may still work on other devices. Actual charge-stop and resume percentages have not yet completed full physical validation; successful register read-back is not proof of real charging behavior.

## Download and install

Get the **macOS Apple Silicon arm64 DMG** from the [latest stable Release](https://github.com/MauriceLiang/MauLeaf/releases/latest), then drag MauLeaf.app to Applications and open it.

The current package is **ad-hoc code-signed, without Apple Developer ID signing or notarization**. If macOS cannot verify the developer, first check that the installer came from this repository's official Release, then review available options in System Settings → Privacy & Security. Do not disable system security protections or run untrusted installers.

**Launch is read-only and does not request an administrator password, install the Helper, or enable charging limits.** You can see battery and power status and choose a local limit. Only when you explicitly click **Disabled** on the top charging-limit status row will MauLeaf request permission to install or update the privileged Helper if needed, then apply a guarded firmware change after confirmation.

## Features and controls

| Feature | Behavior |
| --- | --- |
| Battery and power | Fixed green menu-bar leaf; popover shows battery level and current power source |
| Charging limit | Click the top-card Disabled status to enable, or the active status to disable |
| Limit setting | 50–95% slider and 70 / 75 / 80 / 85 / 90 / 95% presets; settings are local only when disabled |
| One-time full charge | Start or cancel from the top card, available only while MauLeaf is managing an active limit |
| Settings | Switch between Simplified Chinese and English inside the popover |
| Quit | Restore and verify original firmware, then retain or remove native control components |

Before first activation, the privileged Helper snapshots the original bfF0, bfD0 and bfE0 values with device identity in a root-owned recovery file. Later limit changes or one-time full charge never overwrite the snapshot. Disabling a limit restores all original values with read-back verification; unknown states or failed restores are never reported as safe.

### Quit and uninstall

| Choice | Behavior | Administrator password |
| --- | --- | --- |
| Keep components and quit | Restore and verify original firmware; preserve launchd registration; Helper exits when idle and is reusable next launch | Normally not required |
| Remove components and quit | Restore and verify original firmware, then remove the installed Helper, LaunchDaemon and related recovery components; app remains until moved to Trash | Required when deleting privileged components |
| Cancel | Return to the app without cleanup | Not required |

On battery power alone, full restoration is allowed only when the validated identity and all additional checks pass (including independent power-source checks, battery at least 30%, and a valid original snapshot). **Failed restoration blocks normal removal and retains recovery data.** Force Quit, crashes, and dragging the App to Trash directly cannot guarantee firmware restoration.

If you previously kept the components and later want a complete uninstall, run the bundled uninstaller *while MauLeaf.app still exists*:

~~~bash
sudo "/Applications/MauLeaf.app/Contents/Resources/MauLeafNativeControl/uninstall-native-firmware-helper.sh"
~~~

That is the **uninstaller**, not the password-free **diagnostic script** below. Never manually delete the root Helper or recovery snapshot before restoring firmware.

## Not working? Run diagnostics and open an Issue

If the menu-bar icon is missing, the limit control cannot be enabled, the Helper fails, authorization keeps appearing, firmware state shows unknown, or quitting fails, do not modify SMC registers or remove recovery files manually.

**Step 1: Download and run the repository's read-only diagnostic script in Terminal.**

~~~bash
curl -fL https://raw.githubusercontent.com/MauriceLiang/MauLeaf/main/Scripts/diagnose-mauleaf.sh -o MauLeaf-diagnose.sh
bash ./MauLeaf-diagnose.sh
~~~

If you have cloned the repository, you may instead run:

~~~bash
bash Scripts/diagnose-mauleaf.sh
~~~

The script reports macOS version, model identifier, firmware version, architecture, power/battery status, the standard installed app version/signature, and whether the Helper, LaunchDaemon, recovery directory and launchd service are visible. **It does not need sudo, change firmware or services, upload data, or collect serial numbers, usernames, IPs, passwords, full logs or recovery contents.** Root-protected files may be invisible to ordinary users; "not visible" does not prove they are absent.

**Step 2: [Open a bug Issue](https://github.com/MauriceLiang/MauLeaf/issues/new?template=bug_report.md)** and include:

1. The failure, reproduction steps, expected and actual behavior.
2. MauLeaf version and whether AC power is connected; redact screenshots of error dialogs if helpful.
3. The full terminal diagnostic output in the Issue template's diagnostic report section.

Review all content before posting: do not disclose passwords, device serials, personal paths, tokens, or private system logs. The diagnostic script is *not* a repair script; its report helps maintainers distinguish unsupported hardware, permission failures, and unavailable services.

[Inspect diagnostic source](Scripts/diagnose-mauleaf.sh) · [Browse existing Issues](https://github.com/MauriceLiang/MauLeaf/issues)

## Development and limitations

~~~bash
git clone https://github.com/MauriceLiang/MauLeaf.git
cd MauLeaf
bash tests/run.sh
~~~

Automated tests use a fake SMC backend and do not write actual battery firmware. CI produces and verifies Apple Silicon arm64 DMGs. New work must preserve explicit opt-in, minimal privilege, original-state snapshots, and fail-closed recovery.

- [Native firmware backend and safety](docs/NATIVE_FIRMWARE_BACKEND.md)
- [Charging behavior and known limits](docs/CHARGING.md)
- [Changelog](CHANGELOG.md)

## License

[Apache License 2.0](LICENSE), with the original ChargeCap [MIT notice](LICENSES/ChargeCap-Original-MIT.txt).
