#!/bin/bash
set -euo pipefail

LABEL="com.local.chargecap.firmware-helper"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$SOURCE_DIR/MauLeafFirmwareHelper"
PLIST_SOURCE="$SOURCE_DIR/com.local.chargecap.firmware-helper.plist"
TARGET="/Library/PrivilegedHelperTools/$LABEL"
PLIST_TARGET="/Library/LaunchDaemons/$LABEL.plist"

if [[ "$EUID" -ne 0 ]]; then
  echo "请使用 sudo 运行此脚本。" >&2
  exit 1
fi
if [[ ! -x "$BINARY" || ! -f "$PLIST_SOURCE" ]]; then
  echo "未找到 helper 可执行文件或 LaunchDaemon plist。" >&2
  exit 2
fi
/usr/bin/codesign --verify --strict "$BINARY"
IDENTIFIER=$(/usr/bin/codesign -dv --verbose=2 "$BINARY" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p')
if [[ "$IDENTIFIER" != "$LABEL" ]]; then
  echo "helper code-signing identifier 不正确：$IDENTIFIER" >&2
  exit 4
fi
if [[ -e "$TARGET" || -e "$PLIST_TARGET" ]]; then
  echo "检测到已有 MauLeaf 固件 helper，拒绝覆盖安装。请先执行卸载脚本。" >&2
  exit 3
fi

/usr/bin/install -o root -g wheel -m 755 "$BINARY" "$TARGET"
/usr/bin/install -o root -g wheel -m 644 "$PLIST_SOURCE" "$PLIST_TARGET"
/usr/bin/plutil -lint "$PLIST_TARGET"
/bin/launchctl bootstrap system "$PLIST_TARGET"
/bin/launchctl print "system/$LABEL" >/dev/null

echo "只读固件 helper 已安装。当前版本仅提供状态读取和控制计划，不提供 SMC 写入接口。"
