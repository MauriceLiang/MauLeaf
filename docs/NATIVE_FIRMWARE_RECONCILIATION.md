# Native firmware reconciliation and one-time full charge - P5

## Startup / wake reconciliation

The reconciliation policy compares the desired MauLeaf action with the observed firmware state:

- Limited mode: configure the selected upper/lower pair if the limit is inactive or the stored values differ.
- Full / always: deactivate only when the firmware limit is active.
- Full / once: deactivate for the temporary full-charge window; the one-time coordinator owns restoration.
- Matching states are no-ops. Repeated wake notifications must not generate redundant writes.
- Force-discharge remains blocked until adapter-cut semantics are verified.

The policy is pure and can be called after app launch, sleep/wake, or a battery-state refresh. It does not execute any SMC operation.

## One-time full-charge state machine

A persisted job records:

- a unique job ID
- the original upper and lower thresholds to restore
- an absolute expiry timestamp

The coordinator makes these decisions:

| Condition | Decision |
|---|---|
| AC connected, below 100%, before expiry | Continue charging |
| Battery reports 100% or fully charged | Restore the saved limit |
| Job expires | Restore the saved limit |
| User cancels | Restore the saved limit |
| AC is disconnected or unknown | Keep the job pending until AC is confirmed |
| Battery telemetry is unavailable while AC is connected | Restore the saved limit |

If the job reaches a terminal condition while unplugged, restoration is deferred; it is not silently discarded. When AC returns, the persisted job can be reconciled and restored.

## Safety and integration status

- The coordinator does not write SMC.
- The reconciliation policy does not write SMC.
- All tests use plain in-memory values.
- The current app still uses the existing batt workflow.
- The native helper still exposes only read-only status and plan operations.

The next integration stage can reuse the existing per-user LaunchAgent lifecycle, replacing only its batt-specific operations after the native firmware backend has passed hardware validation.
