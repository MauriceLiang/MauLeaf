# macOS 26/27：兼容性警告与紧急卸载 / Compatibility & emergency uninstall

[简体中文](#简体中文) | [English](#english)

## 简体中文

> [!CAUTION]
> **紧急兼容性公告（2026-11-10）：当前 MauLeaf 不支持 macOS 26 或 macOS 27。请勿安装或继续依赖其充电控制功能。**
>
> 当前版本捆绑 `batt v0.8.0`。macOS 27 上已观察到 `Error: charging control is not supported on this Mac`、无法正常退出、无法通过图形界面卸载组件。macOS 26 同样被列为不支持，但这不代表相同故障已在所有 macOS 26 设备上复现。

### 已升级用户：推荐卸载方法

连接电源；在「系统设置 → 通用 → 登录项与扩展」关闭 MauLeaf / ChargeCap 的自启动或后台活动。如可以正常退出，先退出。

1. **先阅读** [紧急卸载脚本](../Scripts/uninstall-macos26-27.sh)。
2. 在终端按顺序执行（下载的文件名是 **`mauleaf-uninstall.sh`**，来源文件是仓库的 **`Scripts/uninstall-macos26-27.sh`**）：

   ```bash
   curl -fL --output mauleaf-uninstall.sh \
     https://raw.githubusercontent.com/MauriceLiang/MauLeaf/main/Scripts/uninstall-macos26-27.sh
   less mauleaf-uninstall.sh
   bash mauleaf-uninstall.sh
   ```

3. 按提示输入 `UNINSTALL`，如需管理员权限则输入密码。**不要使用 `sudo bash mauleaf-uninstall.sh`**。
4. 重启 Mac，在「系统设置 → 电池」检查原生充电状态，并手动移除系统设置中剩余的 MauLeaf 登录项。

脚本先核验 `source=MauLeaf` 安装凭据及 `cc.chlc.batt` 服务是否确实指向 `/usr/local/bin/batt`，才操作系统控制组件。它首先尝试 `batt adapter enable` 恢复适配器供电；如果 `batt disable` **仅**返回已知的“不支持充电控制”错误，将继续尝试 `batt uninstall`。**只有官方卸载命令成功且服务已停止，才删除程序、服务配置和受管文件**。随后清理 MauLeaf/ChargeCap 用户任务、应用和偏好设置。

**保护措施**：若检测到其他来源安装的 batt、不能确认归属、供电恢复失败、或 `batt uninstall` 失败，脚本会停止系统组件的删除。它不会关闭 SIP、删除 macOS 自带电池服务或清空无关软件的文件；不能保证清除所有用户自定义安装路径。请勿绕过检查强制删除正在运行的控制器。

### 完整卸载脚本（可直接复制）

**唯一推荐下载的脚本：[`Scripts/uninstall-macos26-27.sh`](../Scripts/uninstall-macos26-27.sh)**。以下是该脚本在本次更新时的**完整内容**，没有省略。需要复制使用时，请将整个 Bash 代码块复制到本地纯文本文件 `mauleaf-uninstall.sh`，然后执行 `bash mauleaf-uninstall.sh`。不要只复制其中几条删除命令，更不要用 `sudo bash` 执行整个脚本。

> 脚本会修改已确认归属的系统服务和配置。运行前请阅读内容、保持 Mac 接电；如果检测到其他来源的 batt 或恢复失败，会停止删除系统级组件。

~~~bash
#!/bin/bash
# MauLeaf emergency uninstaller for macOS 26 / 27.
# Run as your normal macOS user: bash Scripts/uninstall-macos26-27.sh
set -euo pipefail

if [ "$(/usr/bin/uname -s)" != "Darwin" ]; then
  echo "This script runs only on macOS." >&2
  exit 1
fi
if [ "$(/usr/bin/id -u)" -eq 0 ]; then
  echo "Run as your normal user, not with sudo. The script requests sudo when needed." >&2
  exit 1
fi

MAJOR="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)"
if [ "$MAJOR" != "26" ] && [ "$MAJOR" != "27" ]; then
  echo "This emergency uninstaller is intended for macOS 26 and 27 only (detected: $MAJOR)." >&2
  exit 1
fi

TARGET="/usr/local/bin/batt"
DAEMON_PLIST="/Library/LaunchDaemons/cc.chlc.batt.plist"
RECEIPT="/Library/Application Support/ChargeCap/managed-install"
DAEMON_LABEL="cc.chlc.batt"
USER_UID="$(/usr/bin/id -u)"

echo "MauLeaf / ChargeCap emergency removal (macOS $MAJOR)"
echo "This removes verified MauLeaf-managed components, the app and its settings."
echo "It does NOT remove another vendor's batt, reset all login items, or modify SIP."
echo "Keep the Mac connected to power. Review this script before running it."
printf "Type UNINSTALL to continue: "
read -r CONFIRM < /dev/tty
if [ "$CONFIRM" != "UNINSTALL" ]; then
  echo "Cancelled."
  exit 0
fi

# Verify system component ownership BEFORE stopping or deleting anything.
RECEIPT_MATCH=0
if [ -f "$RECEIPT" ] && /usr/bin/grep -qx 'source=MauLeaf' "$RECEIPT"; then
  RECEIPT_MATCH=1
elif [ -e "$RECEIPT" ]; then
  echo "Installation receipt is unknown; refusing to modify batt. File: $RECEIPT" >&2
  exit 2
fi

DAEMON_MATCH=0
if [ -e "$DAEMON_PLIST" ]; then
  PLIST_LABEL="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$DAEMON_PLIST" 2>/dev/null || true)"
  PLIST_ARGS="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$DAEMON_PLIST" 2>/dev/null || true)"
  if [ "$PLIST_LABEL" != "$DAEMON_LABEL" ] || [[ "$PLIST_ARGS" != *"$TARGET"* ]]; then
    echo "Unexpected batt daemon configuration; refusing to modify it." >&2
    exit 3
  fi
  DAEMON_MATCH=1
fi

MANAGED=0
if [ "$RECEIPT_MATCH" -eq 1 ] || [ "$DAEMON_MATCH" -eq 1 ]; then
  MANAGED=1
  for other in /opt/homebrew/bin/batt /opt/homebrew/sbin/batt /usr/local/sbin/batt; do
    if [ -x "$other" ]; then
      echo "Another batt installation exists ($other); refusing to touch the system service." >&2
      exit 4
    fi
  done
  if [ ! -x "$TARGET" ]; then
    echo "Managed batt executable is missing; cannot safely restore power control." >&2
    exit 5
  fi
  if [ ! -f "$DAEMON_PLIST" ] && /bin/launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
    echo "A batt service is running without its expected plist; refusing to remove it." >&2
    exit 6
  fi
fi

# Do not erase an unknown application that happens to have the same name.
check_app() {
  local app="$1"
  if [ ! -e "$app" ]; then return 0; fi
  local bundle_id
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
  if [ "$bundle_id" != "com.local.chargecap" ]; then
    echo "Unexpected bundle identifier at $app ($bundle_id); no files removed." >&2
    exit 7
  fi
}
check_app "/Applications/MauLeaf.app"
check_app "/Applications/ChargeCap.app"

echo "Stopping the two named applications (if running)..."
/usr/bin/pkill -x MauLeaf >/dev/null 2>&1 || true
/usr/bin/pkill -x ChargeCap >/dev/null 2>&1 || true
if /usr/bin/pgrep -x MauLeaf >/dev/null 2>&1 || /usr/bin/pgrep -x ChargeCap >/dev/null 2>&1; then
  echo "The app is still running. Disable its login item and retry." >&2
  exit 8
fi

if [ "$MANAGED" -eq 1 ]; then
  echo "Requesting administrator access for the VERIFIED MauLeaf-managed batt..."
  /usr/bin/sudo -v

  echo "Restoring adapter power..."
  if ! /usr/bin/sudo "$TARGET" adapter enable; then
    echo "Adapter recovery failed. Do NOT remove the service; check power state manually." >&2
    exit 9
  fi

  echo "Attempting to remove charge limits..."
  if DISABLE_OUTPUT="$(/usr/bin/sudo "$TARGET" disable 2>&1)"; then
    printf '%s\n' "$DISABLE_OUTPUT"
  elif [[ "$DISABLE_OUTPUT" == *"charging control is not supported on this Mac"* ]]; then
    echo "Warning: batt disable is unsupported on this macOS version."
    echo "Proceeding with batt's official uninstall/reset operation."
  else
    printf '%s\n' "$DISABLE_OUTPUT" >&2
    echo "Unexpected reset error. System component left in place." >&2
    exit 10
  fi

  echo "Uninstalling batt using its own uninstall command..."
  /usr/bin/sudo "$TARGET" uninstall

  # Only remove files after the official command succeeded and launchd stopped.
  if /bin/launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
    /usr/bin/sudo /bin/launchctl bootout "system/$DAEMON_LABEL"
  fi
  if /bin/launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
    echo "Daemon is still running; leaving its files untouched." >&2
    exit 11
  fi

  /usr/bin/sudo /bin/rm -f "$DAEMON_PLIST" "$TARGET" /etc/batt.json /tmp/batt.log "$RECEIPT"
  /usr/bin/sudo /bin/rmdir "/Library/Application Support/ChargeCap" >/dev/null 2>&1 || true
else
  echo "No verified MauLeaf-managed batt was found; existing batt files are preserved."
  if [ -e "$TARGET" ] || /bin/launchctl print "system/$DAEMON_LABEL" >/dev/null 2>&1; then
    echo "Attention: an unverified batt installation exists and was NOT removed."
  fi
fi

# Remove only MauLeaf/ChargeCap-owned per-user tasks and preferences.
for label in dev.mauriceliang.chargecap.once dev.mauriceliang.chargecap.discharge; do
  /bin/launchctl bootout "gui/$USER_UID/$label" >/dev/null 2>&1 || true
  /bin/rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
/bin/rm -rf "$HOME/Library/Application Support/ChargeCap" \
  "$HOME/Library/Application Support/MauLeaf" \
  "$HOME/Library/Caches/ChargeCap" "$HOME/Library/Caches/MauLeaf" \
  "$HOME/Library/Caches/com.local.chargecap" \
  "$HOME/Library/Saved Application State/com.local.chargecap.savedState" \
  "$HOME/Library/Saved Application State/MauLeaf.savedState"
/bin/rm -f "$HOME/Library/Preferences/com.local.chargecap.plist" \
  "$HOME/Library/Preferences/ChargeCap.plist" \
  "$HOME/Library/Preferences/MauLeaf.plist" \
  "$HOME/Library/Preferences/dev.mauriceliang.MauLeafLayoutTests.plist"

for app in "/Applications/MauLeaf.app" "/Applications/ChargeCap.app"; do
  if [ -e "$app" ]; then
    /usr/bin/sudo /bin/rm -rf "$app"
  fi
done

echo ""
echo "Removal completed. Restart the Mac and check System Settings > Battery."
echo "Also check System Settings > General > Login Items & Extensions and"
echo "remove/disable any remaining MauLeaf or ChargeCap login entry manually."
echo "If charging remains abnormal, do not force-delete other power services."
echo "Only paths checked above were handled; files in other locations are untouched."
~~~

### 手动排障命令

如脚本中止，先检查：

```bash
pgrep -afil 'MauLeaf|ChargeCap|batt'
sudo launchctl print system/cc.chlc.batt
ls -l /usr/local/bin/batt /Library/LaunchDaemons/cc.chlc.batt.plist
sudo cat "/Library/Application Support/ChargeCap/managed-install"
```

**仅当确认 batt 属于 MauLeaf 管理，且不存在其他安装时**，可按顺序手动尝试：

```bash
sudo /usr/local/bin/batt adapter enable
sudo /usr/local/bin/batt disable
sudo /usr/local/bin/batt uninstall
sudo launchctl print system/cc.chlc.batt
```

在 macOS 27 中 `batt disable` 可能报告不支持；**不能将这一错误当成卸载成功**。必须看到 `batt uninstall` 成功且最终服务不存在。若失败，请停止删除并在 Issue 中提交脱敏信息。切勿使用 `sudo rm -f /etc/batt*` 或删除 Apple 的 Batteries 系统组件。

| macOS | 当前 MauLeaf 发布版 |
| --- | --- |
| 13–15 | 原有目标系统，实际支持取决于设备 |
| **26** | **不支持，不建议安装** |
| **27** | **不支持，已出现退出和组件卸载故障** |

该警告适用于 **MauLeaf 当前发布版和捆绑的 batt v0.8.0**，并非声称所有新版 batt 或其他工具均不兼容。

## English

> [!CAUTION]
> **Compatibility warning (2026-11-10): Current MauLeaf releases do NOT support macOS 26 or macOS 27. Do not install or rely on them for charging control.**
>
> The bundled `batt v0.8.0` failed with `Error: charging control is not supported on this Mac` on macOS 27, leaving the UI unable to quit or uninstall the backend. macOS 26 is likewise designated unsupported; identical symptoms have not been verified on every macOS 26 device.

### Removal after an OS upgrade

**Download this exact script:** [`Scripts/uninstall-macos26-27.sh`](../Scripts/uninstall-macos26-27.sh). The [full copyable Bash source is included above](#完整卸载脚本可直接复制); no commands are omitted.

Connect your Mac to power. Disable MauLeaf/ChargeCap in **System Settings → General → Login Items & Extensions** and quit the app if possible.

1. **Read** the [emergency uninstaller](../Scripts/uninstall-macos26-27.sh) before running it.
2. In Terminal, run (the downloaded file is named **`mauleaf-uninstall.sh`**; the repository source is **`Scripts/uninstall-macos26-27.sh`**):

   ```bash
   curl -fL --output mauleaf-uninstall.sh \
     https://raw.githubusercontent.com/MauriceLiang/MauLeaf/main/Scripts/uninstall-macos26-27.sh
   less mauleaf-uninstall.sh
   bash mauleaf-uninstall.sh
   ```

3. Type `UNINSTALL` and authorize privileged operations if prompted. **Do not run the whole script with sudo**.
4. Restart the Mac, check **System Settings → Battery**, and manually remove any remaining MauLeaf login item.

The script checks the MauLeaf install receipt and expected service ownership before touching batt. It restores adapter power first, tolerates **only** the known unsupported-control failure from `batt disable`, and requires `batt uninstall` to succeed and the daemon to stop before removing managed files. It then removes the app, related user LaunchAgents, and settings.

**Safety:** It stops if an external batt install is present, provenance is unclear, power restoration fails, or the official uninstall fails. It does not disable SIP, remove Apple battery components, or sweep unrelated user files. If it refuses to proceed, capture sanitized diagnostics and open an Issue; do not manually force-delete a running service.

| macOS | Current MauLeaf release |
| --- | --- |
| 13–15 | Original target range; hardware behavior still varies |
| **26** | **Unsupported** |
| **27** | **Unsupported; quit/uninstall failures observed** |

This warning applies to the current MauLeaf release with bundled batt v0.8.0, not necessarily newer versions of batt or other charging utilities.
