#!/bin/bash
# MauLeaf native safe complete uninstall.
# The entire original SMC state must be restored and verified before ANY
# application, privileged helper, daemon, or recovery file is deleted.
# All checks work on AC and on validated battery-only M1 Pro hardware.
set -euo pipefail

LABEL="com.local.chargecap.firmware-helper"
APP="/Applications/MauLeaf.app"
SOURCE_DIR="$APP/Contents/Resources/MauLeafNativeControl"
SCRIPT="$SOURCE_DIR/uninstall-native-firmware-helper.sh"
SOURCE_BINARY="$SOURCE_DIR/MauLeafFirmwareHelper"
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
# Used interactively while the app is still running:
#   --keep-components   restore original state, stop daemon, keep installed files
#   --remove-components restore original state, stop and delete root components;
#                       Finder is responsible for trashing the app after quit
# No arguments remains the standalone complete uninstaller, which also
# deletes /Applications/MauLeaf.app, but MUST only run after app quit.
MODE="complete"
if [[ "$#" -eq 1 ]]; then
  case "$1" in
    --keep-components) MODE="keep" ;;
    --remove-components) MODE="remove" ;;
    *) echo "未知参数：无法绕过固件恢复校验。" >&2; exit 10 ;;
  esac
elif [[ "$#" -ne 0 ]]; then
  echo "卸载参数不正确；不允许绕过固件恢复校验。" >&2
  exit 10
fi

# Prevent following symlinked application/helper paths and prohibit use of a
# copied standalone script to recursively delete an unrelated app bundle.
if [[ -L "$APP" || -L "$TARGET" || -L "$PLIST_TARGET" || ! -d "$APP" \
      || ! -x "$TARGET" || ! -f "$PLIST_TARGET" || ! -x "$SOURCE_BINARY" ]]; then
  echo "MauLeaf 应用或原生服务缺失/包含符号链接。未删除任何文件。" >&2
  exit 2
fi
CALLED_SCRIPT="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"
if [[ "$CALLED_SCRIPT" != "$SCRIPT" ]]; then
  echo "请从 /Applications/MauLeaf.app 内运行原生卸载脚本；未删除任何文件。" >&2
  exit 2
fi
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)
PLIST_LABEL=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$PLIST_TARGET" 2>/dev/null || true)
PLIST_PROGRAM=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST_TARGET" 2>/dev/null || true)
IDENTIFIER=$(/usr/bin/codesign -dv --verbose=2 "$TARGET" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p')
if [[ "$BUNDLE_ID" != "com.local.chargecap" || "$PLIST_LABEL" != "$LABEL" \
      || "$PLIST_PROGRAM" != "$TARGET" || "$IDENTIFIER" != "$LABEL" ]]; then
  echo "MauLeaf 应用/Helper 身份不匹配，拒绝删除。" >&2
  exit 3
fi
if ! /usr/bin/codesign --verify --strict "$SOURCE_BINARY" >/dev/null 2>&1 \
    || ! /usr/bin/cmp -s "$TARGET" "$SOURCE_BINARY"; then
  echo "已安装的 Helper 与当前应用不匹配。请先重新启动当前版本完成升级，未卸载。" >&2
  exit 9
fi
if [[ "$MODE" == "complete" ]] && /usr/bin/pgrep -x MauLeaf >/dev/null 2>&1; then
  echo "完整卸载前请先退出 MauLeaf；应用内退出时请选择保留或移除组件。" >&2
  exit 4
fi

echo "正在恢复启用 MauLeaf 前的原始固件配置并验证所有寄存器……"
echo "支持接电及已验证设备的电池供电恢复；恢复失败时不会移除任何组件。"

# Stop the normal controller before starting a one-shot, root-owned helper.
# The persisted snapshot remains intact if restore cannot complete.
if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
  /bin/launchctl bootout "system/$LABEL" || {
    echo "无法停止原生服务；保留应用和恢复组件。" >&2
    exit 5
  }
fi

if ! RESTORE_OUTPUT=$("$TARGET" --restore-original-state 2>&1); then
  printf '%s\n' "$RESTORE_OUTPUT" >&2
  echo "固件恢复未验证成功；MauLeaf、Helper、快照和脚本全部保留。"
  echo "请检查电池供电状态/电量，或接上电源后重试。" >&2
  /bin/launchctl bootstrap system "$PLIST_TARGET" >/dev/null 2>&1 || true
  exit 5
fi
printf '%s\n' "$RESTORE_OUTPUT"

# An old Preview 4 installation without an original snapshot can only turn
# off bfF0. Never claim that unknown historical thresholds were restored.
# However, after verifying the hardware limit is OFF, we must still let the
# owner completely uninstall rather than trapping them with leftover helpers.
if [[ "$RESTORE_OUTPUT" == *"Legacy limit disabled."* ]]; then
  echo "警告：旧版未保存原始阈值。已解除固件限充，但无法重建历史 bfD0/bfE0；后续只会在复查安全后清理。"
fi

# Never accept only the helper's success exit code: independently reopen
# AppleSMC, verify bfF0 is inactive and all durable restore tasks are gone.
if ! "$TARGET" --verify-clean-and-inactive; then
  echo "恢复后二次校验失败；保留所有组件供恢复使用。" >&2
  /bin/launchctl bootstrap system "$PLIST_TARGET" >/dev/null 2>&1 || true
  exit 6
fi

if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
  echo "后台服务仍在运行；未执行删除。" >&2
  exit 7
fi

# Preserve the installed components for the next explicit launch while
# guaranteeing the privileged helper daemon is no longer running.
# On next launch, MauLeaf automatically re-installs/re-bootstraps the helper,
# with administrator authorization if macOS requires it.
if [[ "$MODE" == "keep" ]]; then
  if [[ -e "$SNAPSHOT" || -e "$JOB" || -e "$RESTORE_REQUEST" \
        || -e "$LEGACY_RESTORE" || -e "$BACKGROUND_RECOVERY" \
        || -e "$DEFERRED_UNINSTALL" ]]; then
    echo "存在未完成的恢复或延期卸载任务，不能安全停止所有后台组件。保留恢复服务。" >&2
    /bin/launchctl bootstrap system "$PLIST_TARGET" >/dev/null 2>&1 || true
    exit 6
  fi
  echo "原始固件状态恢复并二次验证成功；后台 Helper 已停止。安装文件已保留供下次启动使用。"
  exit 0
fi

# At this point only the verified safe state remains. Delete all known
# MauLeaf-owned privileged artifacts, including older deferred-finalizer
# scripts and markers. No forced removal mode is supported.
if [[ -e "$SNAPSHOT" || -e "$JOB" || -e "$RESTORE_REQUEST" || -e "$LEGACY_RESTORE" ]]; then
  echo "仍存在持久化的原始快照或恢复任务；未执行删除。" >&2
  exit 6
fi
/bin/rm -f "$BACKGROUND_RECOVERY" "$DEFERRED_UNINSTALL" "$DEFERRED_SCRIPT"
/bin/rm -f "$PLIST_TARGET" "$TARGET"
/bin/rm -f "/var/log/mauleaf-firmware-helper.log"
# Preserve unexpected files for inspection rather than recursively deleting
# unknown data. If this directory is not empty, report incomplete cleanup.
/bin/rmdir "$SUPPORT_DIR" >/dev/null 2>&1 || true

# The in-app "remove components and quit" path must NEVER remove the
# running application bundle. The user then drags MauLeaf.app to Trash.
# The standalone default command removes the app after it has quit.
if [[ "$MODE" == "complete" ]]; then
  if [[ -L "$APP" || "$BUNDLE_ID" != "com.local.chargecap" ]]; then
    echo "应用路径在卸载过程中变更；请手动检查残余文件。" >&2
    exit 8
  fi
  /bin/rm -rf "$APP"
fi

if [[ ( "$MODE" == "complete" && -e "$APP" ) || -e "$TARGET" || -e "$PLIST_TARGET" \
      || -e "$DEFERRED_SCRIPT" || -e "$SNAPSHOT" || -e "$RESTORE_REQUEST" \
      || -e "$SUPPORT_DIR" || -e "/var/log/mauleaf-firmware-helper.log" ]]; then
  echo "恢复已成功，但部分文件未能移除。请检查权限及残留路径。" >&2
  exit 8
fi
if [[ "$MODE" == "remove" ]]; then
  echo "固件已恢复并验证；Helper、LaunchDaemon 与系统脚本已删除。请退出应用并将 MauLeaf.app 移到废纸篓。"
elif [[ "$RESTORE_OUTPUT" == *"Legacy limit disabled."* ]]; then
  echo "MauLeaf 已完全卸载：旧版固件限充已关闭、原有阈值未知；Helper、LaunchDaemon 与脚本均已删除。"
elif [[ "$RESTORE_OUTPUT" == *"No MauLeaf original-state snapshot exists"* ]]; then
  echo "MauLeaf 已完全卸载：当前固件限充已关闭；由于没有原始快照，无法独立确认历史阈值。应用、Helper、LaunchDaemon 与脚本均已删除。"
else
  echo "MauLeaf 已完全卸载：原始固件配置恢复验证成功，应用、Helper、LaunchDaemon 与所有附带脚本均已删除。"
fi
