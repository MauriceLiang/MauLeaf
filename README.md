[简体中文](README.md) | [English](README.en.md)

> [!CAUTION]
> **当前原生预览版仅面向 Apple Silicon、macOS 15 和已验证的 MacBookPro18,1 / mBoot-20457.41.3 硬件配置。Intel 不再提供构建；macOS 26/27 和其他未经验证的环境不支持新建充电限制。已有原始快照的恢复操作会单独进行硬件身份校验。**

<p align="center">
  <img src="Assets/MauLeafIcon-1024.png" width="128" alt="MauLeaf 叶子图标">
</p>

<h1 align="center">MauLeaf</h1>

<p align="center">轻量、原生的 macOS 菜单栏充电控制工具</p>

<p align="center">
  <a href="https://github.com/MauriceLiang/MauLeaf/releases">下载 Preview</a> ·
  <a href="CHANGELOG.md">更新日志</a> ·
  <a href="https://github.com/MauriceLiang/MauLeaf/issues">反馈问题</a>
</p>

MauLeaf 只保留日常充电上限和「本次充满」两项功能。菜单栏固定显示绿色叶子。

本预览版使用 MauLeaf 自研 AppleSMC 控制器和随应用打包的原生特权服务，不包含 batt 二进制、第三方固件资源或第三方控制调用。

## 功能

| 功能 | 说明 |
| --- | --- |
| 主动启用限充 | 首次启动默认不写入限制；用户点击「启用限制充电」后才保存原始固件状态并启用 |
| 充电上限 | 50–95%，支持滑杆和 70/75/80/85/90/95% 快捷预设；未启用时只保存本地设置 |
| 关闭限充 | 恢复启用前保存的 bfF0、bfD0、bfE0 原始值，逐项读回验证后删除快照 |
| 本次充满 | 临时关闭当前限充；达到 100%、手动取消或 10 小时期限后恢复当前限充 |
| 电池状态 | 显示当前电量和供电状态 |
| 菜单栏 | 固定绿色叶子，不显示百分比，不提供样式切换 |

没有实时功率卡片、主动放电、持续充满、登录项设置或第三方控制组件安装页面。

## 原始固件状态与卸载安全

第一次启用限充时，root helper 会先读取三个寄存器，并将原始值、设备型号、系统固件和架构保存到：

    /Library/Application Support/MauLeaf/original-firmware-state.json

快照由 root 拥有，权限为 0600，独立于应用安装目录。修改充电上限不会覆盖这份原始快照。

- 点击「关闭限制充电」：先关闭限充，再恢复原始上限、恢复阈值和原始激活状态，逐项读回一致后才删除快照。
- **完全卸载**：先退出 MauLeaf，运行应用包内的卸载脚本。Helper 在有电源或经过真机验证的无电源状态下精确恢复原始 bfF0、bfD0、bfE0；再次验证为已关闭且无待恢复任务后，自动删除应用、Helper、LaunchDaemon、持久恢复文件与所有随应用提供的脚本。
- **无电源恢复与卸载**：仅在已通过真机验证的 MacBookPro18,1、mBoot-20457.41.3、macOS 15、arm64 上开启。离线恢复额外要求 IOKit 与 pmset 都确认使用电池、电量 ≥30%、没有正在充电、原始快照有效且原始 bfF0 为 0x00。所有条件满足时立即恢复；任何条件不明、写入失败或读回不符，都保留 App、Helper、快照，不会宣称卸载成功。
- 系统升级：恢复操作仅允许相同机型、相同系统固件和相同 Apple Silicon 架构；即使新系统版本不允许启用新限充，仍可尝试恢复已保存的原始状态。

**Preview 4 及更早版本没有保存首次启用前的原始阈值。** 升级后若检测到没有快照但限充仍处于启用状态，MauLeaf 会明确提示。停用旧版状态只能清除激活标志并保留当前阈值，无法重建未保存的历史值。若之后再次启用 Preview 5，当前保留的阈值会被作为新的快照基线；它代表当前可读取状态，不等于真正的 Preview 4 之前原始值。

## 硬件范围与安全边界

当前已验证的写入目标：

- 机型：MacBookPro18,1（Apple M1 Pro）
- 系统：macOS 15
- 固件：mBoot-20457.41.3
- 架构：arm64
- 控制寄存器：AppleSMC 的 bfF0、bfD0、bfE0

新建或修改充电限制前会检查机型、固件、系统版本、寄存器元数据、电源连接和用户确认；写入后逐项读回校验，失败时尝试恢复此前状态。未连接电源或硬件条件不匹配时，不会执行新的限充写入。

> [!IMPORTANT]
> 目标 M1 Pro 的实际充电停止点和恢复点仍需接电实测。寄存器写入并读回成功，不等于已经证明电池会在设定百分比停止充电。请把本版本视为硬件验证预览版，不要依赖它承担未经验证的关键电池管理任务。

首次启动时，应用会自动请求一次管理员授权，以安装 MauLeaf 自己的 AppleSMC 特权服务。服务由本仓库源码构建，不提供通用 SMC 写入接口。

## 安装

1. 从 [GitHub Releases](https://github.com/MauriceLiang/MauLeaf/releases) 下载 MauLeaf-<版本>-macos-arm64.dmg。
2. 将 MauLeaf.app 拖入「应用程序」并启动。
3. 首次启动时，按 macOS 提示授权安装 MauLeaf 原生固件服务。
4. 选择充电上限，连接电源后点击「启用限制充电」。

仅提供 Apple Silicon arm64 安装包。Intel 不再构建或发布。

## 日常使用

- **未启用时**：调整滑杆或快捷预设只会保存本地上限，不会写入固件。
- **启用限制充电**：点击醒目的「启用限制充电」按钮。首次硬件写入需要明确确认，helper 会先保存原始快照。
- **修改上限**：限充启用后，滑杆和预设会立即应用新上限，但不会覆盖原始快照。
- **关闭限制充电**：点击「关闭限制充电」，恢复启用前的三个寄存器值。
- **本次充满**：仅在 MauLeaf 限充已启用时可用。充满任务结束后恢复当前 MauLeaf 上限；之后仍可手动关闭限充并恢复最初快照。
- **正常退出应用**：有电源时正常恢复；目标 M1 Pro 在满足断电安全条件时，也会立即恢复并逐项验证。如果断电环境不满足条件，则保留持久恢复请求和 Helper，之后在条件允许时重试。异常情况下仍提供「仍然退出」，但不能把未恢复状态当作安全卸载。强制结束进程、崩溃或直接删除文件无法保证即时恢复。

## 完全卸载（接电、断电均适用）

务必先启动最新预览版一次，确认已安装与该版本匹配的 Helper，然后**从菜单栏正常退出 MauLeaf**。在终端执行以下唯一的完整卸载命令：

```bash
sudo "/Applications/MauLeaf.app/Contents/Resources/MauLeafNativeControl/uninstall-native-firmware-helper.sh"
```

该脚本不要求连接电源，**由同一条命令完成**：停用控制服务、读取并按原始快照恢复 bfF0/bfD0/bfE0、逐项复核、独立复核无残留固件限充与持久恢复任务，最后才删除 `/Applications/MauLeaf.app`、原生特权 Helper、LaunchDaemon、恢复记录及应用包和系统目录中的安装/卸载/恢复脚本。不需要再将 App 手动拖入废纸篓。

断电恢复限于上文已验证的硬件、macOS 15 与安全供电条件。**电量低于 30%、外部供电识别冲突、原始快照损坏、固件校验失败或其他异常时，脚本非零退出并保留 App、Helper 与恢复数据，方便重新接电或修复后重试。** 不提供任何跳过固件恢复、直接删除特权服务的强制卸载选项。

如运行旧版 Preview 4 或更早版本时曾启用限充，却没有保存原始快照，则从未存储的历史阈值无法重建。这种情况不能声称精确恢复启用 MauLeaf 前的状态，建议保留恢复环境并核实固件状态后处理。普通用户把 App 直接拖入废纸篓、或强制删除 Helper，不会自动运行恢复脚本，**不能保证安全恢复**。

## 本地开发与测试

    git clone https://github.com/MauriceLiang/MauLeaf.git
    cd MauLeaf
    bash tests/run.sh

自动化测试使用内存中的模拟 SMC transport，不会对真实硬件写入。Release 由 GitHub Actions 构建，Preview 标签格式为 vX.Y.Z-preview.N。

## 项目结构

| 目录 | 内容 |
| --- | --- |
| Sources/ | SwiftUI 菜单栏应用、AppleSMC 事务控制器、XPC 特权服务 |
| Support/ | 原生 LaunchDaemon 配置 |
| Scripts/ | 原生服务安装、卸载和 CI 打包脚本 |
| Tools/ | 只读硬件探测及独立验证工具 |
| tests/ | 固件事务、快照恢复、服务和界面回归测试 |
| docs/ | 硬件边界、充电行为与发布说明 |

## 许可证

MauLeaf 使用 [Apache License 2.0](LICENSE)，并保留原 ChargeCap 的 [MIT 声明](LICENSES/ChargeCap-Original-MIT.txt)。当前预览版不捆绑第三方充电控制程序或其固件资源。
