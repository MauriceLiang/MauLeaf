#!/bin/bash
set -euo pipefail

LABEL="com.local.chargecap.firmware-helper"
TARGET="/Library/PrivilegedHelperTools/$LABEL"
PLIST_TARGET="/Library/LaunchDaemons/$LABEL.plist"
SUPPORT_DIR="/Library/Application Support/MauLeaf"
JOB="$SUPPORT_DIR/one-time-charge.json"
SNAPSHOT="$SUPPORT_DIR/original-firmware-state.json"
RESTORE_REQUEST="$SUPPORT_DIR/restore-original-state.pending"

if [[ "$EUID" -ne 0 ]]; then
  echo "请使用 sudo 运行此脚本。" >&2
  exit 1
fi

if [[ ! -x "$TARGET" || ! -f "$PLIST_TARGET" ]]; then
  echo "MauLeaf 原生服务文件不完整或不存在；为避免误删，未执行清理。" >&2
  exit 2
fi

PLIST_LABEL=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$PLIST_TARGET" 2>/dev/null || true)
PLIST_PROGRAM=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST_TARGET" 2>/dev/null || true)
IDENTIFIER=$(/usr/bin/codesign -dv --verbose=2 "$TARGET" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p')
if [[ "$PLIST_LABEL" != "$LABEL" || "$PLIST_PROGRAM" != "$TARGET" || "$IDENTIFIER" != "$LABEL" ]]; then
  echo "原生服务元数据或签名标识与 MauLeaf 不符，拒绝删除。" >&2
  exit 3
fi

if /usr/bin/pgrep -x MauLeaf >/dev/null 2>&1; then
  echo "请先完全退出 MauLeaf，再重新运行卸载脚本。" >&2
  exit 4
fi

echo "正在恢复 MauLeaf 启用前的原始固件配置……"
echo "仅当三个寄存器逐项读回验证成功后，才会删除原生服务和恢复快照。"

/bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
RESTORE_OUTPUT=""
if RESTORE_OUTPUT=$("$TARGET" --restore-original-state 2>&1); then
  printf '%s\n' "$RESTORE_OUTPUT"
else
  printf '%s\n' "$RESTORE_OUTPUT" >&2
  if [[ -e "$RESTORE_REQUEST" ]]; then
    echo "当前无法完成恢复请求。已保留原始快照，并重新启动后台恢复服务；接入电源后会自动重试。" >&2
    /bin/launchctl bootstrap system "$PLIST_TARGET" >/dev/null 2>&1 || true
    /bin/launchctl kickstart -k "system/$LABEL" >/dev/null 2>&1 || true
  else
    echo "恢复未通过验证。原始快照、Helper 和 LaunchDaemon 均已保留；请排查原因后重新运行卸载脚本。" >&2
  fi
  exit 5
fi

if [[ -e "$SNAPSHOT" || -e "$RESTORE_REQUEST" || -e "$JOB" ]]; then
  echo "恢复命令已返回，但仍存在持久化恢复数据；为避免丢失恢复能力，拒绝删除服务。" >&2
  /bin/launchctl bootstrap system "$PLIST_TARGET" >/dev/null 2>&1 || true
  exit 6
fi

/bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
  echo "后台服务仍在运行，未删除服务文件。" >&2
  exit 7
fi

/bin/rm -f "$PLIST_TARGET" "$TARGET"
/bin/rmdir "$SUPPORT_DIR" >/dev/null 2>&1 || true

if [[ "$RESTORE_OUTPUT" == *"Legacy limit disabled."* ]]; then
  echo "警告：检测到 Preview 4 或更早版本遗留的限充。旧版本未保存历史阈值，因此本次仅停用了限充激活标志，无法还原此前的阈值数值。"
elif [[ "$RESTORE_OUTPUT" == *"No MauLeaf original-state snapshot exists"* ]]; then
  echo "注意：没有找到 MauLeaf 原始快照，且当前限充已经关闭；本次未修改任何寄存器，因此无法独立验证历史阈值是否与首次启用前一致。"
else
  echo "MauLeaf 原始固件配置已恢复并验证，原生服务和恢复快照已安全清理。"
fi
