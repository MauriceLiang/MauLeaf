#!/bin/bash
# MauLeaf emergency uninstaller for macOS 26 / 27.
# Run as your normal macOS user: bash Scripts/uninstall-macos26-27.sh
set -euo pipefail

if [ "$(/usr/bin/uname -s)" != "Darwin" ]; then
  echo "This script runs only on macOS." >&2
  exit 1
fi
if [ "$(/usr/bin/id -u)" -eq 0 ]; then
  echo "Run as your normal user, not with sudo. The script requests sudo when needed." >&2
  exit 1
fi

MAJOR="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)"
if [ "$MAJOR" != "26" ] && [ "$MAJOR" != "27" ]; then
  echo "This emergency uninstaller is intended for macOS 26 and 27 only (detected: $MAJOR)." >&2
  exit 1
fi

TARGET="/usr/local/bin/batt"
DAEMON_PLIST="/Library/LaunchDaemons/cc.chlc.batt.plist"
RECEIPT="/Library/Application Support/ChargeCap/managed-install"
DAEMON_LABEL="cc.chlc.batt"
USER_UID="$(/usr/bin/id -u)"

echo "MauLeaf / ChargeCap emergency removal (macOS $MAJOR)"
echo "This removes verified MauLeaf-managed components, the app and its settings."
echo "It does NOT remove another vendor's batt, reset all login items, or modify SIP."
echo "Keep the Mac connected to power. Review this script before running it."
printf "Type UNINSTALL to continue: "
read -r CONFIRM < /dev/tty
if [ "$CONFIRM" != "UNINSTALL" ]; then
  echo "Cancelled."
  exit 0
fi

# Verify system component ownership BEFORE stopping or deleting anything.
RECEIPT_MATCH=0
if [ -f "$RECEIPT" ] && /usr/bin/grep -qx 'source=MauLeaf' "$RECEIPT"; then
  RECEIPT_MATCH=1
elif [ -e "$RECEIPT" ]; then
  echo "Installation receipt is unknown; refusing to modify batt. File: $RECEIPT" >&2
  exit 2
fi

DAEMON_MATCH=0
if [ -e "$DAEMON_PLIST" ]; then
  PLIST_LABEL="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$DAEMON_PLIST" 2>/dev/null || true)"
  PLIST_ARGS="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$DAEMON_PLIST" 2>/dev/null || true)"
  if [ "$PLIST_LABEL" != "$DAEMON_LABEL" ] || [[ "$PLIST_ARGS" != *"$TARGET"* ]]; then
    echo "Unexpected batt daemon configuration; refusing to modify it." >&2
    exit 3
  fi
  DAEMON_MATCH=1
fi

MANAGED=0
if [ "$RECEIPT_MATCH" -eq 1 ] || [ "$DAEMON_MATCH" -eq 1 ]; then
  MANAGED=1
  for other in /opt/homebrew/bin/batt /opt/homebrew/sbin/batt /usr/local/sbin/batt; do
    if [ -x "$other" ]; then
      echo "Another batt installation exists ($other); refusing to touch the system service." >&2
      exit 4
    fi
  done
  if [ ! -x "$TARGET" ]; then
    echo "Managed batt executable is missing; cannot safely restore power control." >&2
    exit 5
  fi
  if [ ! -f "$DAEMON_PLIST" ] && /bin/launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
    echo "A batt service is running without its expected plist; refusing to remove it." >&2
    exit 6
  fi
fi

# Do not erase an unknown application that happens to have the same name.
check_app() {
  local app="$1"
  if [ ! -e "$app" ]; then return 0; fi
  local bundle_id
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$bundle_id" != "com.local.chargecap" ]; then
    echo "Unexpected bundle identifier at $app ($bundle_id); no files removed." >&2
    exit 7
  fi
}
check_app "/Applications/MauLeaf.app"
check_app "/Applications/ChargeCap.app"

echo "Stopping the two named applications (if running)..."
/usr/bin/pkill -x MauLeaf >/dev/null 2>&1 || true
/usr/bin/pkill -x ChargeCap >/dev/null 2>&1 || true
if /usr/bin/pgrep -x MauLeaf >/dev/null 2>&1 || /usr/bin/pgrep -x ChargeCap >/dev/null 2>&1; then
  echo "The app is still running. Disable its login item and retry." >&2
  exit 8
fi

if [ "$MANAGED" -eq 1 ]; then
  echo "Requesting administrator access for the VERIFIED MauLeaf-managed batt..."
  /usr/bin/sudo -v

  echo "Restoring adapter power..."
  if ! /usr/bin/sudo "$TARGET" adapter enable; then
    echo "Adapter recovery failed. Do NOT remove the service; check power state manually." >&2
    exit 9
  fi

  echo "Attempting to remove charge limits..."
  if DISABLE_OUTPUT="$(/usr/bin/sudo "$TARGET" disable 2>&1)"; then
    printf '%s\n' "$DISABLE_OUTPUT"
  elif [[ "$DISABLE_OUTPUT" == *"charging control is not supported on this Mac"* ]]; then
    echo "Warning: batt disable is unsupported on this macOS version."
    echo "Proceeding with batt's official uninstall/reset operation."
  else
    printf '%s\n' "$DISABLE_OUTPUT" >&2
    echo "Unexpected reset error. System component left in place." >&2
    exit 10
  fi

  echo "Uninstalling batt using its own uninstall command..."
  /usr/bin/sudo "$TARGET" uninstall

  # Only remove files after the official command succeeded and launchd stopped.
  if /bin/launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
    /usr/bin/sudo /bin/launchctl bootout "system/$DAEMON_LABEL"
  fi
  if /bin/launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
    echo "Daemon is still running; leaving its files untouched." >&2
    exit 11
  fi

  /usr/bin/sudo /bin/rm -f "$DAEMON_PLIST" "$TARGET" /etc/batt.json /tmp/batt.log "$RECEIPT"
  /usr/bin/sudo /bin/rmdir "/Library/Application Support/ChargeCap" >/dev/null 2>&1 || true
else
  echo "No verified MauLeaf-managed batt was found; existing batt files are preserved."
  if [ -e "$TARGET" ] || /bin/launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
    echo "Attention: an unverified batt installation exists and was NOT removed."
  fi
fi

# Remove only MauLeaf/ChargeCap-owned per-user tasks and preferences.
for label in dev.mauriceliang.chargecap.once dev.mauriceliang.chargecap.discharge; do
  /bin/launchctl bootout "gui/$USER_UID/$label" >/dev/null 2>&1 || true
  /bin/rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
/bin/rm -rf "$HOME/Library/Application Support/ChargeCap" \
  "$HOME/Library/Application Support/MauLeaf" \
  "$HOME/Library/Caches/ChargeCap" "$HOME/Library/Caches/MauLeaf" \
  "$HOME/Library/Caches/com.local.chargecap" \
  "$HOME/Library/Saved Application State/com.local.chargecap.savedState" \
  "$HOME/Library/Saved Application State/MauLeaf.savedState"
/bin/rm -f "$HOME/Library/Preferences/com.local.chargecap.plist" \
  "$HOME/Library/Preferences/ChargeCap.plist" \
  "$HOME/Library/Preferences/MauLeaf.plist" \
  "$HOME/Library/Preferences/dev.mauriceliang.MauLeafLayoutTests.plist"

for app in "/Applications/MauLeaf.app" "/Applications/ChargeCap.app"; do
  if [ -e "$app" ]; then
    /usr/bin/sudo /bin/rm -rf "$app"
  fi
done

echo ""
echo "Removal completed. Restart the Mac and check System Settings > Battery."
echo "Also check System Settings > General > Login Items & Extensions and"
echo "remove/disable any remaining MauLeaf or ChargeCap login entry manually."
echo "If charging remains abnormal, do not force-delete other power services."
echo "Only paths checked above were handled; files in other locations are untouched."
