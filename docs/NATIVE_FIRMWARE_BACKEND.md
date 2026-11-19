# Native firmware charge-limit core (P2)

## Scope

P2 adds a testable transaction engine for the firmware-managed AppleSMC keys:

| Key | Meaning | Expected payload |
|---|---|---|
| \`bfF0\` | Activation | 1 byte: \`0x00\` off, \`0x02\` active |
| \`bfD0\` | Upper threshold | 4-byte little-endian percentage |
| \`bfE0\` | Resume threshold | 4-byte little-endian percentage |

The engine is intentionally isolated from the current MauLeaf application. It is not linked into the menu-bar app, does not install a helper, and cannot be triggered by the current UI.

## What is implemented

- A read-only state reader and transaction planner.
- A validated request model matching MauLeaf's existing 50–95% upper-limit range.
- The required transaction order: deactivate → write upper → write lower → activate.
- Per-write read-back verification with bounded retries.
- Idempotency: an already active, matching limit is a no-op.
- Rollback to the exact pre-transaction state after a failure.
- If rollback cannot be confirmed, a final attempt to leave the firmware limit inactive and verify that state.
- A write permit that refuses changes unless all runtime conditions are true:
  - exact target model \`MacBookPro18,1\`
  - exact observed firmware \`mBoot-20457.41.3\`
  - macOS major version 15 and arm64
  - administrator privileges
  - AC power connected
  - MauLeaf and batt are not running
  - explicit user confirmation supplied
- An injected SMC transport so transaction tests never access real hardware.

The metadata validator accepts either the exact expected key width/type or size-zero unpopulated metadata (with an absent or matching type). In either case, direct reads must return the exact expected payload length and valid values. This follows the observed behavior of some Apple firmware, where a live key can report unpopulated metadata.

## Hardware evidence boundary

The user's probe established that \`bfF0\` is readable with a one-byte \`ui8\` shape on this MacBookPro18,1. The exact behavior of the full bf* family on this machine is not yet proven.

A separate public reference implementation reports real-hardware enforcement on a MacBook Air M3 with firmware \`mBoot-20457.1.29\`. That is a different model and firmware build; it is a useful protocol reference, not proof for this MacBook Pro's \`mBoot-20457.41.3\`.

P2 therefore implements and tests the transaction algorithm, but does not claim the target Mac's firmware accepts the writes or enforces the limit.

## Current safety status

- The real AppleSMC transport is present for isolated helper-side use, but is not called by MauLeaf.app.
- The transaction engine is not connected to the app, the launchd service, or any UI action.
- CI uses only an in-memory fake transport. It performs zero SMC writes.
- No SMC operation was run on the user's Mac as part of this change.
- Do not enable the firmware limit on the target Mac until the user can connect AC power and perform the dedicated hardware session.

## Verification

Run the full repository test suite:

~~~bash
bash tests/run.sh
~~~

The suite includes pure transaction tests for ordering, little-endian encoding, idempotency, read-back, write gating, rollback, and failure-to-inactive behavior.

## Next integration steps

1. Complete the dedicated hardware session on the target Mac: confirm bfD0/bfE0 presence, metadata, values, write permission, and actual charge enforcement while AC is connected.
2. Add a narrowly scoped privileged helper. Do not perform privileged SMC writes directly from the unprivileged menu-bar process.
3. Integrate the helper through an authenticated IPC boundary and a single serialized controller.
4. Migrate existing settings and one-time-full-charge behavior only after the firmware backend is verified.
5. Remove batt only after end-to-end regression, sleep/wake, reboot, and recovery tests pass.

Until those steps are complete, the released MauLeaf behavior remains unchanged and continues to use its existing backend.
