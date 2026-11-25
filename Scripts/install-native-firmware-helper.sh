#!/bin/bash
# Canonical service-only uninstall/reinstall for every Helper version mismatch.
# Firmware snapshots and recovery jobs are persistent state and are NEVER removed.
set -euo pipefail

LABEL="com.local.chargecap.firmware-helper"
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$SOURCE_DIR/MauLeafFirmwareHelper"
PLIST_SOURCE="$SOURCE_DIR/$LABEL.plist"
DEFERRED_SCRIPT_SOURCE="$SOURCE_DIR/complete-deferred-uninstall.sh"
TARGET="/Library/PrivilegedHelperTools/$LABEL"
PLIST_TARGET="/Library/LaunchDaemons/$LABEL.plist"
JOB_DIR="/Library/Application Support/MauLeaf"
FINALIZER="$JOB_DIR/complete-deferred-uninstall.sh"

if [[ "$EUID" -ne 0 ]]; then
  echo "请使用管理员授权运行此脚本。" >&2
  exit 1
fi
if [[ ! -x "$BINARY" || ! -f "$PLIST_SOURCE" || ! -f "$DEFERRED_SCRIPT_SOURCE" ]]; then
  echo "未找到 MauLeaf 原生固件服务或 LaunchDaemon plist。" >&2
  exit 2
fi
/usr/bin/codesign --verify --strict "$BINARY"
source_identifier=$(/usr/bin/codesign -dv --verbose=2 "$BINARY" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p')
if [[ "$source_identifier" != "$LABEL" ]]; then
  echo "原生服务签名标识不正确：$source_identifier" >&2
  exit 4
fi
plist_label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$PLIST_SOURCE" 2>/dev/null || true)
plist_program=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST_SOURCE" 2>/dev/null || true)
if [[ "$plist_label" != "$LABEL" || "$plist_program" != "$TARGET" ]]; then
  echo "应用包中的 LaunchDaemon 身份不正确，拒绝安装。" >&2
  exit 4
fi

had_previous=false
if [[ -e "$TARGET" || -e "$PLIST_TARGET" || -L "$TARGET" || -L "$PLIST_TARGET" ]]; then
  if [[ -L "$TARGET" || -L "$PLIST_TARGET" || ! -f "$TARGET" || ! -f "$PLIST_TARGET" ]]; then
    echo "检测到不完整或来源不明的同名服务，拒绝覆盖。" >&2
    exit 3
  fi
  existing_label=$(/usr/libexec/PlistBuddy -c 'Print :Label' "$PLIST_TARGET" 2>/dev/null || true)
  existing_program=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$PLIST_TARGET" 2>/dev/null || true)
  existing_identifier=$(/usr/bin/codesign -dv --verbose=2 "$TARGET" 2>&1 | /usr/bin/sed -n 's/^Identifier=//p')
  if [[ "$existing_label" != "$LABEL" || "$existing_program" != "$TARGET" || "$existing_identifier" != "$LABEL" ]] ||
     [[ "$(/usr/bin/stat -f '%u' "$TARGET")" != "0" || "$(/usr/bin/stat -f '%u' "$PLIST_TARGET")" != "0" ]] ||
     ! /usr/bin/codesign --verify --strict "$TARGET"; then
    echo "现有同名服务不是受信任的 MauLeaf root Helper，拒绝覆盖。" >&2
    exit 3
  fi
  had_previous=true
fi

/bin/mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons "$JOB_DIR"
/usr/sbin/chown root:wheel "$JOB_DIR"
/bin/chmod 755 "$JOB_DIR"
staging=$(/usr/bin/mktemp -d "$JOB_DIR/.helper-install.XXXXXXXX")
/bin/chmod 700 "$staging"
was_running=false
replaced=false
rollback() {
  local rc=$?
  trap - EXIT
  if [[ "$rc" -ne 0 && "$replaced" == true ]]; then
    echo "新 Helper 安装未完成，回滚已安装的二进制文件；恢复快照始终保留。" >&2
    if [[ "$had_previous" == true ]]; then
      /usr/bin/install -o root -g wheel -m 755 "$staging/old-helper" "$TARGET" || true
      /usr/bin/install -o root -g wheel -m 644 "$staging/old-plist" "$PLIST_TARGET" || true
      if [[ -f "$staging/old-finalizer" ]]; then
        /usr/bin/install -o root -g wheel -m 700 "$staging/old-finalizer" "$FINALIZER" || true
      else
        /bin/rm -f "$FINALIZER"
      fi
      if [[ "$was_running" == true ]]; then
        /bin/launchctl bootstrap system "$PLIST_TARGET" >/dev/null 2>&1 || true
      fi
    else
      /bin/rm -f "$TARGET" "$PLIST_TARGET"
    fi
  elif [[ "$rc" -ne 0 && "$had_previous" == true && "$was_running" == true ]]; then
    /bin/launchctl bootstrap system "$PLIST_TARGET" >/dev/null 2>&1 || true
  fi
  /bin/rm -rf "$staging"
  exit "$rc"
}
trap rollback EXIT

# Stage and verify all new files before interrupting an existing Helper.
/usr/bin/install -o root -g wheel -m 755 "$BINARY" "$staging/new-helper"
/usr/bin/install -o root -g wheel -m 644 "$PLIST_SOURCE" "$staging/new-plist"
/usr/bin/install -o root -g wheel -m 700 "$DEFERRED_SCRIPT_SOURCE" "$staging/new-finalizer"
/usr/bin/codesign --verify --strict "$staging/new-helper"
/usr/bin/plutil -lint "$staging/new-plist"
if [[ "$had_previous" == true ]]; then
  /bin/cp -p "$TARGET" "$staging/old-helper"
  /bin/cp -p "$PLIST_TARGET" "$staging/old-plist"
  if [[ -f "$FINALIZER" && ! -L "$FINALIZER" ]]; then
    /bin/cp -p "$FINALIZER" "$staging/old-finalizer"
  fi
  if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
    was_running=true
    /bin/launchctl bootout "system/$LABEL"
    # bootout can return before launchd has finished removing the old job.
    # Wait boundedly before deleting files and bootstrapping the replacement.
    for attempt in {1..20}; do
      if ! /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
        break
      fi
      /bin/sleep 0.25
    done
    if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
      echo "旧版 Helper 尚未完全停止，拒绝并行安装新服务。" >&2
      exit 5
    fi
  fi
fi

# Service-only uninstall: remove the old executable, LaunchDaemon and
# finalizer after taking a rollback copy. Do NOT remove JOB_DIR or any
# snapshot, restore marker, one-time-charge record or deferred-uninstall job.
replaced=true
/bin/rm -f "$TARGET" "$PLIST_TARGET" "$FINALIZER"
if [[ -e "$TARGET" || -e "$PLIST_TARGET" || -e "$FINALIZER" ]]; then
  echo "旧版 Helper 组件未能完整卸载；保留恢复数据并回滚。" >&2
  exit 5
fi

# Install the exact Helper and scripts bundled with the current app.
/bin/mv -f "$staging/new-helper" "$TARGET"
/bin/mv -f "$staging/new-plist" "$PLIST_TARGET"
/bin/mv -f "$staging/new-finalizer" "$FINALIZER"
/bin/launchctl bootstrap system "$PLIST_TARGET"
for attempt in {1..20}; do
  if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
    break
  fi
  /bin/sleep 0.25
done
if ! /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
  echo "新版 Helper 未能注册到 launchd，正在回滚。" >&2
  exit 6
fi

echo "MauLeaf 原生 Helper 已卸载旧版并重新安装当前应用内置版本；原始固件快照及恢复任务未更改。"
