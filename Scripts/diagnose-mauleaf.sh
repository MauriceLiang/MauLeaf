#!/usr/bin/env bash
# MauLeaf read-only issue diagnostics.
# Never use sudo. No system modifications, privileged reads or log collection.
set -u
set -o pipefail
export LC_ALL=C

usage() {
  cat <<'HELP'
MauLeaf read-only diagnostics

Usage:
  bash Scripts/diagnose-mauleaf.sh
  bash Scripts/diagnose-mauleaf.sh --help

Copy the printed report into a GitHub Issue:
https://github.com/MauriceLiang/MauLeaf/issues/new?template=bug_report.md

This script does NOT require sudo, install/uninstall components, modify
charging, inspect SMC registers, read passwords or upload anything.
Review the output before sharing.
HELP
}

if [[ $# -gt 1 ]] || { [[ $# -eq 1 ]] && [[ "$1" != "--help" ]]; }; then
  usage >&2
  exit 2
fi
if [[ $# -eq 1 ]]; then
  usage
  exit 0
fi

if [[ "$(id -u 2>/dev/null)" == "0" ]]; then
  printf '%s\n' 'Do not run this diagnostic with sudo or as root.' >&2
  exit 2
fi
if [[ "$(uname -s 2>/dev/null)" != "Darwin" ]]; then
  printf '%s\n' 'This diagnostic is for macOS only.' >&2
  exit 2
fi

unknown="unavailable"
safe_token() {
  if [[ "$1" =~ ^[A-Za-z0-9._-]{1,80}$ ]]; then
    printf '%s' "$1"
  else
    printf '%s' "$unknown"
  fi
}
file_presence() {
  if [[ -e "$1" ]]; then
    printf 'present'
  else
    printf 'not visible'
  fi
}
directory_presence() {
  if [[ -d "$1" ]]; then
    printf 'present'
  else
    printf 'not visible'
  fi
}
get_plist_version() {
  /usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$1" 2>/dev/null || true
}

os_version="$(safe_token "$(sw_vers -productVersion 2>/dev/null || true)")"
model="$(safe_token "$(sysctl -n hw.model 2>/dev/null || true)")"
architecture="$(safe_token "$(uname -m 2>/dev/null || true)")"

# Parse ONLY the firmware version key. Never print the raw ioreg tree:
# that tree can contain hardware identifiers and serial numbers.
firmware_raw="$(ioreg -p IODeviceTree -l -w0 2>/dev/null \
  | awk -F '"' '$2 == "system-firmware-version" { print $4; exit }' || true)"
firmware="$(safe_token "$firmware_raw")"

battery_raw="$(pmset -g batt 2>/dev/null || true)"
power_source="$unknown"
if [[ "$battery_raw" == *"'AC Power'"* ]]; then
  power_source="AC"
elif [[ "$battery_raw" == *"'Battery Power'"* ]]; then
  power_source="Battery"
fi
battery_pct="$(printf '%s\n' "$battery_raw" \
  | awk 'match($0, /[0-9][0-9]?[0-9]?%/) { print substr($0, RSTART, RLENGTH); exit }' || true)"
if [[ -z "$battery_pct" ]]; then
  battery_pct="$unknown"
fi

app="/Applications/MauLeaf.app"
app_presence="$(directory_presence "$app")"
app_version="$unknown"
app_signature="not checked (app not found)"
if [[ -d "$app" ]]; then
  app_version="$(safe_token "$(get_plist_version "$app/Contents/Info.plist")")"
  if codesign --verify --strict "$app" >/dev/null 2>&1; then
    app_signature="valid"
  else
    app_signature="invalid or unverifiable"
  fi
fi

helper="/Library/PrivilegedHelperTools/com.local.chargecap.firmware-helper"
daemon="/Library/LaunchDaemons/com.local.chargecap.firmware-helper.plist"
recovery="/Library/Application Support/MauLeaf"
helper_presence="$(file_presence "$helper")"
daemon_presence="$(file_presence "$daemon")"
recovery_presence="$(directory_presence "$recovery")"
snapshot="not visible"
if [[ -d "$recovery" ]]; then
  if [[ -r "$recovery" && -x "$recovery" ]]; then
    snapshot="$(file_presence "$recovery/original-firmware-state.json")"
  else
    snapshot="unknown (protected directory)"
  fi
fi

# launchctl print is a query only. An unprivileged failure does not prove that
# the service is unregistered, so never report such a failure as "disabled".
launchd_status="not verifiable as current user"
if launchctl print system/com.local.chargecap.firmware-helper >/dev/null 2>&1; then
  launchd_status="registered"
fi

supported="no (current verified profile does not match)"
case "$os_version" in
  15|15.*)
    if [[ "$model" == "MacBookPro18,1" &&
          "$architecture" == "arm64" &&
          "$firmware" == "mBoot-20457.41.3" ]]; then
      supported="matches current verified profile (AC and safety checks still required)"
    fi
    ;;
esac

printf '%s\n' 'MauLeaf diagnostic report (read-only, v1)'
printf 'Generated (UTC): %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf 'unavailable')"
printf 'macOS: %s\n' "$os_version"
printf 'Model identifier: %s\n' "$model"
printf 'Architecture: %s\n' "$architecture"
printf 'System firmware: %s\n' "$firmware"
printf 'Power source: %s\n' "$power_source"
printf 'Battery level: %s\n' "$battery_pct"
printf 'Verified write profile: %s\n' "$supported"
printf 'MauLeaf in /Applications: %s\n' "$app_presence"
printf 'MauLeaf app version: %s\n' "$app_version"
printf 'App code signature: %s\n' "$app_signature"
printf 'Privileged Helper binary: %s\n' "$helper_presence"
printf 'LaunchDaemon plist: %s\n' "$daemon_presence"
printf 'Launchd service: %s\n' "$launchd_status"
printf 'Recovery directory: %s\n' "$recovery_presence"
printf 'Original firmware snapshot: %s\n' "$snapshot"
printf '%s\n' 'Note: "not visible" is not proof that root-owned files are absent.'
printf '%s\n' 'Privacy: no serial numbers, username, hostname, IP, logs, passwords,'
printf '%s\n' '         recovery file contents or raw SMC registers are collected.'
printf '%s\n' 'No firmware writes, service changes, or network uploads were performed.'
