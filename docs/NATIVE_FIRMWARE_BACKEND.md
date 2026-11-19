# Native AppleSMC firmware backend

MauLeaf uses a repository-owned AppleSMC controller and a privileged XPC helper. The app process never receives a raw SMC transport.

## Enable flow

- The first enable request reads and validates bfF0, bfD0, and bfE0.
- Before the first firmware write, the helper persists the exact original state and hardware identity in a root-owned snapshot.
- The helper applies the requested upper and resume thresholds, reads every write back, and verifies the final active state.
- Subsequent upper-limit changes reuse the original snapshot and never overwrite it.

## Disable and uninstall flow

- Disable restores the exact original activation byte and both thresholds.
- The restore transaction deactivates first, restores the upper and lower values, restores the original activation byte, and reads all three keys back.
- The snapshot is deleted only after exact verification.
- Failed restoration retains the snapshot and schedules a durable retry marker.
- The uninstaller invokes the helper's standalone restore mode before removing the LaunchDaemon or binary. Missing AC power or any failed verification leaves the service and snapshot in place.

Restoration is authorized only for the same saved model, system firmware, and arm64 architecture. It may run after a macOS major-version upgrade, but it cannot write a new charging limit on an unvalidated OS.

Preview 4 and earlier had no original-state snapshot. A legacy active limit can only be deactivated; the previous threshold values cannot be reconstructed.

## Hardware boundary

New limit writes remain restricted to MacBookPro18,1, mBoot-20457.41.3, macOS 15, arm64, root privileges, AC power, and explicit user consent. Successful register read-back does not prove the physical charge-stop percentage. The target M1 Pro still requires real AC-powered observation.

## Tests

The core and service tests use an in-memory fake transport. They cover exact restore order, snapshot persistence, permission mode, AC-power deferral, background retry, OS-upgrade restore authorization, legacy Preview 4 migration, and failure retention. CI never writes to physical hardware.
