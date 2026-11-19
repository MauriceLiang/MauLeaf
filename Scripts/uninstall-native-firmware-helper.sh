#!/bin/bash
set -euo pipefail

LABEL="com.local.chargecap.firmware-helper"
TARGET="/Library/PrivilegedHelperTools/$LABEL"
PLIST_TARGET="/Library/LaunchDaemons/$LABEL.plist"
JOB="/Library/Application Support/MauLeaf/one-time-charge.json"

if [[ "$EUID" -ne 0 ]]; then
  echo "请使用 sudo 运行此脚本。" >&2
  exit 1
fi
if [[ -e "$JOB" ]]; then
  echo "检测到本次充满任务仍在等待完成或恢复。请先接入电源并在 MauLeaf 中取消任务，确认恢复后再卸载服务。" >&2
  exit 3
fi
if [[ -f "$PLIST_TARGET" ]]; then
  PLIST_LABEL=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$PLIST_TARGET" 2>/dev/null || true)
  PLIST_PROGRAM=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST_TARGET" 2>/dev/null || true)
  if [[ "$PLIST_LABEL" != "$LABEL" || "$PLIST_PROGRAM" != "$TARGET" ]]; then
    echo "LaunchDaemon 元数据与预期不符，拒绝删除。" >&2
    exit 2
  fi
  /bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
fi
/bin/rm -f "$PLIST_TARGET" "$TARGET"
echo "MauLeaf 原生固件服务已卸载；不会修改当前固件充电设置。"
