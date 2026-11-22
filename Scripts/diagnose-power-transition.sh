#!/usr/bin/env bash
# MauLeaf power-transition timing probe — READ ONLY.
# Samples the system-level pmset source and AppleSmartBattery registry flags.
# No sudo, SMC access, launchctl modifications, or external network access.
set -euo pipefail
export LC_ALL=C

usage() {
  cat <<'HELP'
MauLeaf system power-transition probe (read only)

Usage:
  bash Scripts/diagnose-power-transition.sh [duration_seconds]
  bash Scripts/diagnose-power-transition.sh --help

Duration: 10–45 seconds (default 25).
Connect the charger before starting; unplug around sample 10.
Run separately with firmware limit enabled, disabled/restored, and after
safely quitting MauLeaf. Compare how quickly both system fields change.

Only power-source fields, signed battery current, local clock time, and
sample numbers are printed. No serials, identifiers or SMC registers.
No sudo, firmware writes, system setting changes or uploads.
HELP
}

if [[ ${1:-} == "--help" && $# -eq 1 ]]; then usage; exit 0; fi
if [[ $# -gt 1 || ! "${1:-25}" =~ ^[0-9]{1,2}$ ]]; then usage >&2; exit 2; fi
duration=${1:-25}
if (( duration < 10 || duration > 45 )); then usage >&2; exit 2; fi
if (( EUID == 0 )); then
  echo "Do not run this diagnostic as root or with sudo." >&2
  exit 2
fi
if [[ "$(/usr/bin/uname -s)" != "Darwin" ]]; then
  echo "This diagnostic runs on macOS only." >&2
  exit 2
fi

printf 'MauLeaf power-source transition — read only, %ds\n' "$duration"
printf '%s\n' 'Keep charger connected initially. Unplug around sample 10 (about 5 seconds).'
printf '%s\n' 'Compare three separate runs: limit ON; limit OFF after verified restore; app fully quit.'
printf '%s\n' 'Sample | Local time | pmset source | AppleSmartBattery ExternalConnected | IsCharging | Amperage(mA)'

samples=$((duration * 2))
for ((sample = 1; sample <= samples; sample++)); do
  # pmset reports the source according to system power management.
  pmset_output="$(/usr/bin/pmset -g batt 2>/dev/null || true)"
  pmset_source="unknown"
  case "$pmset_output" in
    *"Now drawing from 'Battery Power'"*) pmset_source="battery" ;;
    *"Now drawing from 'AC Power'"*) pmset_source="AC" ;;
  esac

  # The direct IORegistry field is distinct from the user-facing pmset
  # report. Do NOT print the entire tree: it may include device identifiers.
  registry="$(/usr/sbin/ioreg -r -c AppleSmartBattery -l -w0 2>/dev/null || true)"
  fields="$(printf '%s\n' "$registry" | /usr/bin/awk -F ' = ' '
    /"ExternalConnected" = / { external=$NF }
    /"IsCharging" = / { charging=$NF }
    /"Amperage" = / { current=$NF }
    END {
      if (external == "") external="unknown";
      if (charging == "") charging="unknown";
      if (current == "") current="unknown";
      printf("%s|%s|%s",external,charging,current)
    }
  ')"
  IFS='|' read -r external charging amperage <<< "$fields"

  # Whitelist only primitive state values. Never display raw registry data.
  case "$external" in Yes|No|true|false|1|0|unknown) ;; *) external="unknown" ;; esac
  case "$charging" in Yes|No|true|false|1|0|unknown) ;; *) charging="unknown" ;; esac
  if [[ ! "$amperage" =~ ^-?[0-9]{1,7}$ ]]; then amperage="unknown"; fi

  printf '%03d | %s | %s | %s | %s | %s\n' \
    "$sample" "$(/bin/date '+%H:%M:%S')" "$pmset_source" "$external" "$charging" "$amperage"
  if (( sample < samples )); then /bin/sleep 0.5; fi
done
printf '%s\n' 'Completed. No SMC writes, privileged actions or network requests were performed.'
