#!/bin/bash
set -euo pipefail

LABEL="com.local.chargecap.firmware-helper"
TARGET="/Library/PrivilegedHelperTools/$LABEL"
PLIST_TARGET="/Library/LaunchDaemons/$LABEL.plist"
SUPPORT_DIR="/Library/Application Support/MauLeaf"
JOB="$SUPPORT_DIR/one-time-charge.json"
SNAPSHOT="$SUPPORT_DIR/original-firmware-state.json"
RESTORE_REQUEST="$SUPPORT_DIR/restore-original-state.pending"
LEGACY_RESTORE="$SUPPORT_DIR/legacy-restore.json"
DEFERRED_UNINSTALL="$SUPPORT_DIR/deferred-uninstall.pending"
DEFERRED_SCRIPT="$SUPPORT_DIR/complete-deferred-uninstall.sh"
BACKGROUND_RECOVERY="$SUPPORT_DIR/background-recovery.pending"

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

# The normal (default) mode permits unplugged removal and preserves the
# recovery helper until safe restoration succeeds. A user who explicitly
# rejects any retained background component can choose unconditional removal.
# This discards the restore snapshot and may leave the firmware charge-limited.
if [[ "$#" -gt 0 ]]; then
  if [[ "$#" -ne 2 || "$1" != "--force-remove-without-restore" \
        || "$2" != "--i-accept-persistent-charge-limit-risk" ]]; then
    echo "未知参数。正常卸载不需要参数；强制彻底删除需同时传入两项明确的风险确认参数。" >&2
    exit 10
  fi
  echo "严重警告：正在按用户明确指令丢弃所有恢复记录并移除 MauLeaf 后台服务。"
  echo "如果固件限充仍激活，删除服务后可能无法自动恢复正常充电；必须自行承担重新安装并手动恢复的风险。"

  /bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
  if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
    echo "LaunchDaemon 仍在运行，为防止留下不可控后台进程，本次未执行清理。" >&2
    exit 11
  fi
  /bin/rm -f "$JOB" "$SNAPSHOT" "$RESTORE_REQUEST" "$BACKGROUND_RECOVERY" \
    "$LEGACY_RESTORE" "$DEFERRED_UNINSTALL" "$DEFERRED_SCRIPT" \
    "$PLIST_TARGET" "$TARGET"
  /bin/rmdir "$SUPPORT_DIR" >/dev/null 2>&1 || true
  echo "已按用户指令彻底移除 MauLeaf 的原生后台组件；不保证固件限充已恢复。"
  exit 0
fi

# A Preview 4 helper does not implement the standalone restore command.
# Refuse before bootout if the installed helper does not match this app's
# bundled helper, rather than running an older daemon indefinitely.
SOURCE_BINARY="$(cd "$(dirname "$0")" && pwd)/MauLeafFirmwareHelper"
if [[ ! -x "$SOURCE_BINARY" ]] || ! /usr/bin/codesign --verify --strict "$SOURCE_BINARY" >/dev/null 2>&1; then
  echo "未找到可验证的 Preview 5 原生 helper，保留已安装服务和固件配置。" >&2
  exit 8
fi
if ! /usr/bin/cmp -s "$TARGET" "$SOURCE_BINARY"; then
  echo "已安装的 helper 与当前 MauLeaf 不一致；请先启动当前版本并完成 helper 升级，退出应用后再卸载。" >&2
  exit 9
fi

echo "正在恢复 MauLeaf 启用前的原始固件配置……"
echo "仅当三个寄存器逐项读回验证成功后，才会删除原生服务和恢复快照。"

/bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
RESTORE_OUTPUT=""
if RESTORE_OUTPUT=$("$TARGET" --restore-original-state 2>&1); then
  printf '%s\n' "$RESTORE_OUTPUT"
else
  printf '%s\n' "$RESTORE_OUTPUT" >&2
  # The user is allowed to remove MauLeaf.app immediately, even without
  # AC power. Retain only the small root-owned helper, recovery data, and
  # independent finalizer until firmware recovery has been verified.
  if [[ -e "$RESTORE_REQUEST" || -e "$LEGACY_RESTORE" ]]; then
    if [[ ! -x "$DEFERRED_SCRIPT" ]]; then
      echo "缺少独立卸载收尾程序；请重新安装当前版本后重试。主应用可自行移除，但后台恢复数据仍将保留。" >&2
      /bin/launchctl bootstrap system "$PLIST_TARGET" >/dev/null 2>&1 || true
      exit 5
    fi
    /usr/bin/touch "$DEFERRED_UNINSTALL"
    /bin/chmod 600 "$DEFERRED_UNINSTALL"
    /usr/bin/touch "$BACKGROUND_RECOVERY"
    /bin/chmod 600 "$BACKGROUND_RECOVERY"
    if ! /bin/launchctl bootstrap system "$PLIST_TARGET" >/dev/null 2>&1; then
      if ! /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
        echo "恢复服务暂时无法启动，已保留快照和服务文件；可以移除主应用，但请检查系统后台服务。" >&2
        exit 5
      fi
    fi
    /bin/launchctl kickstart -k "system/$LABEL" >/dev/null 2>&1 || true
    echo "已排队恢复固件：即使未连接电源，也可以立即删除 MauLeaf.app。"
    echo "重新接电后后台服务会验证固件状态并自动清除自身。当前并未声称已恢复固件。"
    exit 0
  fi
  echo "恢复未通过验证，相关恢复数据与特权服务已保留；可以移除主应用，但可能需要手动恢复。" >&2
  /bin/launchctl bootstrap system "$PLIST_TARGET" >/dev/null 2>&1 || true
  exit 5
fi

if [[ -e "$SNAPSHOT" || -e "$RESTORE_REQUEST" || -e "$BACKGROUND_RECOVERY" || -e "$LEGACY_RESTORE" || -e "$DEFERRED_UNINSTALL" || -e "$JOB" ]]; then
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
/bin/rm -f "$DEFERRED_SCRIPT"
/bin/rmdir "$SUPPORT_DIR" >/dev/null 2>&1 || true

if [[ "$RESTORE_OUTPUT" == *"Legacy limit disabled."* ]]; then
  echo "警告：检测到 Preview 4 或更早版本遗留的限充。旧版本未保存历史阈值，因此本次仅停用了限充激活标志，无法还原此前的阈值数值。"
elif [[ "$RESTORE_OUTPUT" == *"No MauLeaf original-state snapshot exists"* ]]; then
  echo "注意：没有找到 MauLeaf 原始快照，且当前限充已经关闭；本次未修改任何寄存器，因此无法独立验证历史阈值是否与首次启用前一致。"
else
  echo "MauLeaf 原始固件配置已恢复并验证，原生服务和恢复快照已安全清理。"
fi
