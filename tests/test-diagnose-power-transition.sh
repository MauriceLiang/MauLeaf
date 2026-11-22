#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/Scripts/diagnose-power-transition.sh"

bash -n "$SCRIPT"
bash "$SCRIPT" --help | grep -Fq 'system power-transition probe'
for bad in "0" "9" "46" "999" "abc" "--invalid"; do
  if bash "$SCRIPT" "$bad" >/dev/null 2>&1; then
    echo "Invalid probe duration accepted: $bad" >&2
    exit 1
  fi
done
# Probe is strictly read only: no sudo, private SMC transport, process
# management, system power setting modification, or network connection.
if grep -Eq '^[[:space:]]*(sudo|osascript|rm|mv|kill|killall|launchctl|curl|wget|networksetup|scutil|defaults|nvram|reboot|shutdown)([[:space:]]|$)' "$SCRIPT"; then
  echo "Power transition probe contains a forbidden action" >&2
  exit 1
fi
! grep -Eq 'SMCWrite|IOConnectCallStructMethod|bfF0|bfD0|bfE0|raw\.githubusercontent' "$SCRIPT"
grep -Fq '/usr/bin/pmset -g batt' "$SCRIPT"
grep -Fq '/usr/sbin/ioreg -r -c AppleSmartBattery' "$SCRIPT"
grep -Fq 'ExternalConnected' "$SCRIPT"
grep -Fq 'IsCharging' "$SCRIPT"
grep -Fq 'Amperage' "$SCRIPT"
grep -Fq 'No SMC writes' "$SCRIPT"
echo "Power transition diagnostic: read-only checks passed"
