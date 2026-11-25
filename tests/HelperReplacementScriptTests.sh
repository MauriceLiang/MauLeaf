#!/bin/bash
set -euo pipefail

ROOT="${1:?repository root is required}"
INSTALLER="$ROOT/Scripts/install-native-firmware-helper.sh"

bash -n "$INSTALLER"
bash -n "$ROOT/Scripts/uninstall-native-firmware-helper.sh"
bash -n "$ROOT/Scripts/complete-deferred-uninstall.sh"

grep -Fq 'launchctl bootout "system/$LABEL"' "$INSTALLER"
grep -Fq 'launchctl bootstrap system "$PLIST_TARGET"' "$INSTALLER"
grep -Fq '/bin/rm -f "$TARGET" "$PLIST_TARGET" "$FINALIZER"' "$INSTALLER"
grep -Fq 'Do NOT remove JOB_DIR or any' "$INSTALLER"

# Replacing the executable must never delete the persistent state directory
# or its snapshot, pending-restore, one-time-charge and deferred-uninstall data.
if grep -Eq '/bin/rm -rf "\$JOB_DIR"|/bin/rm -f "\$JOB_DIR"/\*' "$INSTALLER"; then
  echo "Helper replacement must not recursively delete persistent recovery data." >&2
  exit 1
fi

echo "HelperReplacementScriptTests: PASS (service-only uninstall/reinstall preserves recovery data)"
