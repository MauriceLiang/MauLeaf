#!/bin/bash
set -euo pipefail

LABEL="com.local.chargecap.firmware-helper"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$SOURCE_DIR/MauLeafFirmwareHelper"
PLIST_SOURCE="$SOURCE_DIR/$LABEL.plist"
DEFERRED_SCRIPT_SOURCE="$SOURCE_DIR/complete-deferred-uninstall.sh"
TARGET="/Library/PrivilegedHelperTools/$LABEL"
PLIST_TARGET="/Library/LaunchDaemons/$LABEL.plist"
JOB_DIR="/Library/Application Support/MauLeaf"

if [[ "$EUID" -ne 0 ]]; then
  echo "请使用管理员授权运行此脚本。" >&2
  exit 1
fi
if [[ ! -x "$BINARY" || ! -f "$PLIST_SOURCE" || ! -f "$DEFERRED_SCRIPT_SOURCE" ]]; then
  echo "未找到 MauLeaf 原生固件服务或 LaunchDaemon plist。" >&2
  exit 2
fi
/usr/bin/codesign --verify --strict "$BINARY"
IDENTIFIER=$(/usr/bin/codesign -dv --verbose=2 "$BINARY" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p')
if [[ "$IDENTIFIER" != "$LABEL" ]]; then
  echo "原生服务签名标识不正确：$IDENTIFIER" >&2
  exit 4
fi

if [[ -e "$TARGET" || -e "$PLIST_TARGET" ]]; then
  if [[ ! -f "$TARGET" || ! -f "$PLIST_TARGET" ]]; then
    echo "检测到不完整或来源不明的同名服务，拒绝覆盖。" >&2
    exit 3
  fi
  EXISTING_LABEL=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$PLIST_TARGET" 2>/dev/null || true)
  EXISTING_PROGRAM=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST_TARGET" 2>/dev/null || true)
  EXISTING_IDENTIFIER=$(/usr/bin/codesign -dv --verbose=2 "$TARGET" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p')
  if [[ "$EXISTING_LABEL" != "$LABEL" || "$EXISTING_PROGRAM" != "$TARGET" || "$EXISTING_IDENTIFIER" != "$LABEL" ]]; then
    echo "现有同名服务并非 MauLeaf 管理的原生服务，拒绝覆盖。" >&2
    exit 3
  fi
  /bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
fi

/bin/mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons "$JOB_DIR"
/usr/bin/install -o root -g wheel -m 755 "$BINARY" "$TARGET"
# Keep a small, root-owned standalone finalizer outside MauLeaf.app, so app
# removal while on battery does not discard firmware recovery capability.
/usr/bin/install -o root -g wheel -m 700 "$DEFERRED_SCRIPT_SOURCE" "$JOB_DIR/complete-deferred-uninstall.sh"
/usr/bin/install -o root -g wheel -m 644 "$PLIST_SOURCE" "$PLIST_TARGET"
/usr/sbin/chown root:wheel "$JOB_DIR"
/bin/chmod 755 "$JOB_DIR"
/usr/bin/plutil -lint "$PLIST_TARGET"
/bin/launchctl bootstrap system "$PLIST_TARGET"
/bin/launchctl print "system/$LABEL" >/dev/null

echo "MauLeaf 原生 AppleSMC 固件服务已启用。"
