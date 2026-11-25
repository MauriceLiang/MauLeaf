#!/bin/bash
# Install the bundled Helper; use the shared safe uninstaller for replacement.
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

# All replacements use exactly the normal component uninstaller.
# Validate the bundled payload first; never delete an old controller until
# its stable recovery CLI has restored and independently verified the state.
if [[ -e "$TARGET" || -e "$PLIST_TARGET" || -L "$TARGET" || -L "$PLIST_TARGET" ]]; then
  /bin/bash "$SOURCE_DIR/uninstall-native-firmware-helper.sh" --remove-components
fi
if [[ -e "$TARGET" || -e "$PLIST_TARGET" || -L "$TARGET" || -L "$PLIST_TARGET" ]]; then
  echo "旧版 Helper 尚未安全卸载，拒绝安装。" >&2
  exit 3
fi
for name in original-firmware-state.json one-time-charge.json restore-original-state.pending legacy-restore.json background-recovery.pending deferred-uninstall.pending; do
  if [[ -e "$JOB_DIR/$name" || -L "$JOB_DIR/$name" ]]; then
    echo "仍存在恢复记录，拒绝安装；请保留恢复数据。" >&2
    exit 3
  fi
done
/bin/mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons "$JOB_DIR"
/usr/sbin/chown root:wheel "$JOB_DIR"
/bin/chmod 755 "$JOB_DIR"
staging=$(/usr/bin/mktemp -d "$JOB_DIR/.helper-install.XXXXXXXX")
/bin/chmod 700 "$staging"
installed=false
rollback() {
  local rc=$?
  trap - EXIT
  if [[ "$rc" -ne 0 && "$installed" == true ]]; then
    /bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
    /bin/rm -f "$TARGET" "$PLIST_TARGET" "$FINALIZER"
  fi
  /bin/rm -rf "$staging"
  exit "$rc"
}
trap rollback EXIT
/usr/bin/install -o root -g wheel -m 755 "$BINARY" "$staging/new-helper"
/usr/bin/install -o root -g wheel -m 644 "$PLIST_SOURCE" "$staging/new-plist"
/usr/bin/install -o root -g wheel -m 700 "$DEFERRED_SCRIPT_SOURCE" "$staging/new-finalizer"
/usr/bin/codesign --verify --strict "$staging/new-helper"
/usr/bin/plutil -lint "$staging/new-plist"
installed=true
/bin/mv "$staging/new-helper" "$TARGET"
/bin/mv "$staging/new-plist" "$PLIST_TARGET"
/bin/mv "$staging/new-finalizer" "$FINALIZER"
/bin/launchctl bootstrap system "$PLIST_TARGET"
/bin/launchctl print "system/$LABEL" >/dev/null
echo "MauLeaf 原生 Helper 已安装并验证。"
