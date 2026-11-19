# MauLeaf privileged native firmware helper

## Purpose

The helper is the only process allowed to perform AppleSMC firmware writes. It is built from this repository and bundled inside:

`MauLeaf.app/Contents/Resources/MauLeafNativeControl/`

It runs as root through the LaunchDaemon `com.local.chargecap.firmware-helper`. The XPC client accepts only the code-signing identifier `com.local.chargecap`.

## Installation

On first app launch, MauLeaf checks the native helper connection. If the service is missing or an older read-only helper is installed, the app runs the bundled installer with one administrator authorization prompt. The old “install control component” panel is not part of the UI.

The installer validates the helper's code-signing identifier and existing LaunchDaemon metadata. It upgrades only an existing helper whose label, path, and signing identifier all match MauLeaf; unrelated same-name services are not overwritten.

## XPC surface

The helper exports only the operations required by MauLeaf:

- `readState`: read and validate `bfF0`, `bfD0`, and `bfE0`.
- `makePlan`: return the transaction plan without writing.
- `applyLimit`: apply an explicit upper/lower pair after target, AC-power and confirmation checks.
- `beginOneTimeCharge`: persist the restore job, then deactivate the current limit.
- `cancelOneTimeCharge`: persist cancellation and restore when AC power is available.
- `oneTimeChargeStatus`: report whether a restore job is pending.

There is no arbitrary key/value write API.

## Persistent one-time restore

The helper stores the restore job at:

`/Library/Application Support/MauLeaf/one-time-charge.json`

The file is root-owned with mode 0600. The LaunchDaemon uses PathState on this file to remain alive while a task is pending and restart after a crash or reboot. The helper polls battery state every 20 seconds, restores at 100%, on cancellation, or at the 10-hour deadline, and waits for AC power before performing the restore write.

If telemetry is unavailable while AC is connected, the helper restores the saved limit rather than leaving the limit disabled. If restore fails, it retains the job and retries.

## Uninstallation

Run the bundled script as administrator:

```bash
sudo "/Applications/MauLeaf.app/Contents/Resources/MauLeafNativeControl/uninstall-native-firmware-helper.sh"
```

The script refuses to remove the service while a one-time restore job remains. It removes only the MauLeaf LaunchDaemon and helper and does not rewrite the current firmware setting.

## Safety and validation

- The helper checks the exact target identity and AC power immediately before each write.
- Each SMC write is read back and verified.
- Transactions are serialized and guarded by a watchdog.
- CI uses an in-memory fake transport only. No hardware writes occur in automated tests.
- Actual charge-stop and resume behavior on the target M1 Pro remains to be observed on AC power.
