# MauLeaf privileged native firmware helper

## Purpose

The helper is the only process allowed to perform AppleSMC firmware writes. It is built for Apple Silicon arm64 from this repository and bundled inside:

    MauLeaf.app/Contents/Resources/MauLeafNativeControl/

It runs as root through the LaunchDaemon com.local.chargecap.firmware-helper. The XPC client accepts only the code-signing identifier com.local.chargecap. Intel builds are not produced.

## Installation and upgrade

On first app launch, MauLeaf checks the native helper connection and protocol version. If the service is missing or an older helper is installed, the app runs the bundled installer with administrator authorization, then verifies the updated helper version before enabling controls.

The installer validates the helper's code-signing identifier and existing LaunchDaemon metadata. It upgrades only an existing helper whose label, path, and signing identifier all match MauLeaf; unrelated same-name services are not overwritten. Snapshot and pending recovery files are preserved during helper upgrades.

## XPC surface

The helper exports only the operations required by MauLeaf:

- readState: read and validate bfF0, bfD0, and bfE0, and report snapshot/restore state.
- makePlan: return the transaction plan without writing.
- applyLimit: save the original state on first activation, then apply an explicit upper/lower pair after target, AC-power, and confirmation checks.
- beginOneTimeCharge: persist the one-time restore job, then deactivate the current MauLeaf limit.
- cancelOneTimeCharge: persist cancellation and restore the current MauLeaf limit when AC power is available.
- restoreOriginalState: restore the exact pre-MauLeaf firmware state and verify every register.
- oneTimeChargeStatus: report whether a one-time full-charge job is pending.

There is no arbitrary key/value write API.

## Original firmware snapshot

Before the first successful MauLeaf limit activation, the helper reads all three firmware registers and persists their exact values plus device identity to:

    /Library/Application Support/MauLeaf/original-firmware-state.json

The snapshot includes schema version, activation byte, upper threshold, lower threshold, model identifier, system firmware, architecture, capture time, and a durable restore-request flag. It is root-owned with mode 0600. It is stored outside the app bundle and is never overwritten when the user changes the charging limit.

The helper writes the snapshot before changing any register. If snapshot persistence fails, the firmware write is not attempted. A failed limit transaction tries to restore the snapshot; if that cannot be verified, the snapshot is retained and a background restore request is scheduled.

## Disable and restore

The user-facing disable operation:

1. Saves a durable restore-request marker.
2. Cancels any pending one-time full-charge job.
3. Requires AC power and an authorized helper.
4. Deactivates the limit, restores the saved upper and lower thresholds, and restores the original activation byte.
5. Reads all three registers back and compares them with the snapshot.
6. Deletes the snapshot and marker only after exact verification.

The restoration permit is restricted to the same Mac model, system firmware, and arm64 architecture recorded in the snapshot. It may run after a macOS version upgrade even when enabling a new limit is blocked on that OS. If model, firmware, or architecture no longer matches, restoration is blocked and the snapshot is retained.

## Persistent background restoration

The original snapshot is stored at:

    /Library/Application Support/MauLeaf/original-firmware-state.json

A pending restore marker is stored at:

    /Library/Application Support/MauLeaf/restore-original-state.pending

Both one-time full-charge jobs and original-state restoration create one unified keepalive marker:

    /Library/Application Support/MauLeaf/background-recovery.pending

The LaunchDaemon uses PathState only on this unified marker, so either type of background recovery keeps the helper alive and restarts it after a crash or reboot. The helper retries every 20 seconds when AC power is available. The marker is removed only when no background recovery remains.

The one-time full-charge job remains separate:

    /Library/Application Support/MauLeaf/one-time-charge.json

One-time completion restores the current MauLeaf limit; disabling MauLeaf restores the original pre-MauLeaf state instead.

## Normal app quit and uninstallation

Normal app termination is now treated as a verified restore transaction. The app waits for any in-flight firmware operation to finish, invokes the privileged restore operation if a managed snapshot, active limit, or one-time full-charge job exists, and then performs independent state and job read-back. It asks macOS to terminate only when the firmware limit is inactive and both the recovery snapshot and one-time task have been cleared. On failure or missing AC power, the app cancels normal termination and displays an error; the root-owned snapshot and background recovery mechanisms remain available. Legacy Preview 4 states without an original snapshot can only have the activation flag cleared, never historical thresholds reconstructed. Force Quit, crash, and sudden power loss can bypass graceful termination and do not guarantee immediate restoration.

## Uninstallation

Launch the current Preview 5 app once so it can install the matching native helper, then connect AC power, quit MauLeaf, and run:

    sudo "/Applications/MauLeaf.app/Contents/Resources/MauLeafNativeControl/uninstall-native-firmware-helper.sh"

The script stops the LaunchDaemon and runs the installed helper in standalone restore mode. It removes the LaunchDaemon, helper, and system support directory only after the original state is restored and verified and all recovery files are gone.

If AC power is unavailable or the restore fails, the script retains the snapshot, helper, and LaunchDaemon. When the restore marker exists, it reboots the LaunchDaemon so the background helper can retry after AC power returns. The user can rerun the uninstaller after the restore completes.

Preview 4 and earlier did not persist the original thresholds. If an active legacy limit exists without a snapshot, the helper can only clear the activation byte and preserve the current threshold values. It explicitly reports that the historical original thresholds cannot be reconstructed. If the user enables Preview 5 again afterward, those retained values become the new snapshot baseline; they are not the true pre-Preview-4 values.

## Safety and validation

- New limit writes require the exact validated MacBookPro18,1, mBoot-20457.41.3, macOS 15, arm64 profile, root privileges, AC power, and explicit user consent.
- Snapshot restoration requires the saved model, system firmware, and architecture to match; it does not permit arbitrary new limit values.
- Each SMC write is read back and verified.
- The snapshot is never deleted after a failed or partial restore.
- Transactions are serialized and guarded by a watchdog.
- CI uses an in-memory fake transport only. No hardware writes occur in automated tests.
- Actual charge-stop and resume behavior on the target M1 Pro remains to be observed on AC power.
