#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/Scripts/diagnose-mauleaf.sh"

bash -n "$SCRIPT"
bash "$SCRIPT" --help | grep -Fq 'read-only diagnostics'
if bash "$SCRIPT" --unsupported >/dev/null 2>&1; then
    echo "Unexpected diagnostic argument was accepted" >&2
    exit 1
fi

# Enforce the no-privileged-write, no-raw-log design contract.
if grep -Eq '(^|[[:space:]])(sudo|osascript|rm|mv|killall|security|curl|wget)[[:space:]]' "$SCRIPT"; then
    echo "Read-only diagnostics must not run privileged, destructive or network commands" >&2
    exit 1
fi
if grep -Eq 'launchctl[[:space:]]+(bootout|bootstrap|kickstart|enable|disable)' "$SCRIPT"; then
    echo "Read-only diagnostics must not change launchd state" >&2
    exit 1
fi
grep -Fq 'launchctl print system/com.local.chargecap.firmware-helper' "$SCRIPT"
grep -Fq 'original-firmware-state.json' "$SCRIPT"
grep -Fq 'system-firmware-version' "$SCRIPT"

if [[ "$(uname -s)" == Darwin ]]; then
    # Exercise the installed/non-installed detection on a real macOS runner.
    # It must succeed without sudo and must never reveal raw ioreg or log data.
    REPORT="$(bash "$SCRIPT")"
    for expected in 'MauLeaf diagnostic report' 'Model identifier:' \
        'System firmware:' 'Verified write profile:' 'Launchd service:' \
        'Original firmware snapshot:' 'No firmware writes'; do
        grep -Fq "$expected" <<< "$REPORT" || {
            echo "Diagnostic output missing: $expected" >&2
            exit 1
        }
    done
    if grep -Ei 'IOPlatformSerialNumber|IOPlatformUUID|Serial Number|UserName|Hardware UUID' <<< "$REPORT"; then
        echo "Diagnostic output may expose a sensitive identifier" >&2
        exit 1
    fi
fi

echo "MauLeaf read-only diagnostic checks passed"
