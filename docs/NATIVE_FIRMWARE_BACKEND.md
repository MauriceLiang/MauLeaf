# Native AppleSMC firmware controller

## Scope

MauLeaf's native-only preview uses the firmware-managed AppleSMC register family:

| Key | Meaning | Expected payload |
| --- | --- | --- |
| `bfF0` | Activation | 1 byte: `0x00` off, `0x02` active |
| `bfD0` | Upper threshold | 4-byte little-endian percentage |
| `bfE0` | Resume threshold | 4-byte little-endian percentage |

The app talks only to the authenticated MauLeaf XPC helper. The menu-bar process does not open a raw SMC write transport.

## Transaction engine

- Validates the 50–95% upper-limit range and a lower resume threshold below the upper limit.
- Applies the sequence: deactivate → write upper → write lower → activate.
- Reads back each write with bounded retries.
- Skips writes when the observed active state already matches.
- Attempts to restore the exact pre-write state after any failure.
- If rollback cannot be verified, makes a final attempt to leave the firmware limit inactive and reports the failure.
- Never exposes a generic SMC-key write method.

## Write authorization

The root helper creates a write permit only when all checks pass:

- exact model `MacBookPro18,1`
- exact firmware `mBoot-20457.41.3` (read recursively from the IODeviceTree, including nested nodes)
- macOS major version 15 and arm64
- helper effective UID is root
- AC power is connected
- the app has received explicit user confirmation for native firmware writes

The helper independently reads model, firmware, AC power and battery telemetry. The app cannot supply these values as trusted facts.

## Hardware evidence boundary

The hardware-probe work identified AppleSMC access on the target MacBookPro18,1 and a readable `bfF0` activation key. The full `bfD0`/`bfE0` metadata, write permissions, and real charge-enforcement behavior still require AC-powered target-device verification.

A successful fake-transport test proves transaction logic only. A successful real register read-back proves that the values were stored/read back, not that charging stops and resumes at the expected percentages. Do not describe the enforcement behavior as verified until the battery has been observed crossing the upper and lower thresholds.

## Tests

`tests/FirmwareLimitCoreTests.swift` covers request validation, key metadata, byte encoding, transaction order, idempotency, bounded retry, read-back, authorization, rollback and failure-to-inactive behavior.

`tests/FirmwareLimitHelperServiceTests.swift` covers the XPC service with a fake transport, including guarded writes and one-time restore. CI never writes to physical hardware.
