#!/bin/bash
set -euo pipefail

LABEL="com.local.chargecap.firmware-helper"
TARGET="/Library/PrivilegedHelperTools/$LABEL"
PLIST_TARGET="/Library/LaunchDaemons/$LABEL.plist"

if [[ "$EUID" -ne 0 ]]; then
  echo "请使用 sudo 运行此脚本。" >&2
  exit 1
fi

if [[ -f "$PLIST_TARGET" ]]; then
  PLIST_LABEL=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$PLIST_TARGET" 2>/dev/null || true)
  if [[ "$PLIST_LABEL" != "$LABEL" ]]; then
    echo "LaunchDaemon label 与预期不符，拒绝删除。" >&2
    exit 2
  fi
  /bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
fi

/bin/rm -f "$PLIST_TARGET" "$TARGET"
echo "只读固件 helper 已卸载；没有执行任何 SMC 写入。"
