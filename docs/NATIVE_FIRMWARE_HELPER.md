# MauLeaf privileged firmware helper — P3

## Scope

This stage adds a small, on-demand LaunchDaemon and XPC boundary for the native firmware-limit subsystem.

The helper currently exports only two read-only operations:

- \`readState\`: read \`bfF0\`, \`bfD0\`, and \`bfE0\`, then return the observed state.
- \`makePlan\`: validate a requested 50–95% upper threshold and return the ordered transaction plan without executing it.

There is intentionally no XPC method for applying, activating, or deactivating a firmware limit.

## Process model

- Launchd owns the Mach service \`com.local.chargecap.firmware-helper\`.
- The helper runs as root from \`/Library/PrivilegedHelperTools\`.
- Only a client whose code-signing identifier is \`com.local.chargecap\` is accepted.
- The client uses one XPC connection per request.
- When the last client disconnects, the helper exits after 20 seconds; launchd starts it again on the next request.
- The app does not yet connect to this helper, and the existing charging UI/backend are unchanged.

## Install / uninstall

After downloading and extracting the helper artifact, run:

~~~bash
sudo ./install-native-firmware-helper.sh
~~~

To remove this read-only helper:

~~~bash
sudo ./uninstall-native-firmware-helper.sh
~~~

These scripts refuse to overwrite an existing helper and validate the launchd label before removal.

## Safety boundary

- The helper has no exported write operation.
- The XPC protocol contains no generic SMC-key write method.
- The current app UI cannot trigger firmware writes.
- The helper's status and plan methods are read-only.
- The firmware transaction engine remains separately guarded by the exact device/firmware, administrator, AC-power, controller-conflict, and explicit-confirmation permit.
- No helper was installed or run on the user's Mac as part of this change.

The helper is deliberately a read-only integration milestone. Do not add a mutating XPC method or connect a UI action to \`FirmwareLimitController.configure\` until real write/read-back and charging-enforcement behavior have been verified on the target MacBookPro18,1 while connected to AC power.
