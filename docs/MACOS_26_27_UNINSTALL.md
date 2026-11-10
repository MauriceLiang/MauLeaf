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
2. 在终端按顺序执行（此 PR 合并至主分支后）：

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

Connect your Mac to power. Disable MauLeaf/ChargeCap in **System Settings → General → Login Items & Extensions** and quit the app if possible.

1. **Read** the [emergency uninstaller](../Scripts/uninstall-macos26-27.sh) before running it.
2. In Terminal, run (after this PR has been merged to main):

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
