#!/bin/bash
set -euo pipefail

# Installed by MauLeaf's privileged installer at a root-owned path. This
# one-shot cleanup is independent of MauLeaf.app: users may delete the app
# immediately after queuing recovery while unplugged.
LABEL="com.local.chargecap.firmware-helper"
HELPER="/Library/PrivilegedHelperTools/$LABEL"
DAEMON="/Library/LaunchDaemons/$LABEL.plist"
SUPPORT="/Library/Application Support/MauLeaf"
MARKER="$SUPPORT/deferred-uninstall.pending"
RECOVERY="$SUPPORT/background-recovery.pending"
SCRIPT="$SUPPORT/complete-deferred-uninstall.sh"

[[ "$EUID" -eq 0 ]] || exit 1
[[ -f "$MARKER" && -x "$HELPER" && -f "$DAEMON" ]] || exit 2
[[ ! -L "$HELPER" && ! -L "$DAEMON" && ! -L "$SCRIPT" ]] || exit 3

# Let the XPC restore call finish before unloading the system service.
sleep 2

PLIST_LABEL=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$DAEMON" 2>/dev/null || true)
PLIST_PROGRAM=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$DAEMON" 2>/dev/null || true)
IDENTIFIER=$(/usr/bin/codesign -dv --verbose=2 "$HELPER" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p')
[[ "$PLIST_LABEL" == "$LABEL" && "$PLIST_PROGRAM" == "$HELPER" && "$IDENTIFIER" == "$LABEL" ]] || exit 4

# A second, fresh hardware read is mandatory; NEVER remove recovery
# capability if firmware is still active or any snapshot/job is present.
"$HELPER" --verify-clean-and-inactive

# The cleanup script runs as an independent child of the helper. Remove
# fully verified files first, then unload launchd LAST: bootout may terminate
# descendants of the launchd job, including this finalizer process.
/bin/rm -f "$DAEMON" "$HELPER"
# No pending restore is possible at this point (verified above).
/bin/rm -f "$RECOVERY" "$MARKER"
# Delete only MauLeaf-owned cleanup files. Keep any unrelated files intact.
/bin/rm -f "$SCRIPT"
/bin/rmdir "$SUPPORT" >/dev/null 2>&1 || true

# The running daemon still has an open image; unload it after all files are
# removed. A crash here leaves no persisted helper or startup configuration.
if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
  /bin/launchctl bootout "system/$LABEL"
fi
echo "MauLeaf deferred firmware recovery and helper removal completed."
