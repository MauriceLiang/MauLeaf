[简体中文](README.md) | [English](README.en.md)

> [!CAUTION]
> **重要兼容性公告（2026-11-10）：MauLeaf 当前版本不支持 macOS 26 或 macOS 27，请勿在这些系统安装或继续使用。**
>
> 捆绑的 **batt v0.8.0** 在 macOS 27 上已出现充电控制不受支持、应用无法正常退出以及图形卸载失败的问题。**已经升级的用户，请优先查看 [macOS 26/27 安全卸载指南](docs/MACOS_26_27_UNINSTALL.md#简体中文) 和 [紧急卸载脚本](Scripts/uninstall-macos26-27.sh)。** macOS 26 同样列为当前版本不支持，并不代表每台设备都已复现同样故障。

<p align="center">
  <img src="Assets/MauLeafIcon-1024.png" width="128" alt="MauLeaf 叶子图标">
</p>

<h1 align="center">MauLeaf</h1>

<p align="center">轻量的 macOS 菜单栏充电管理工具</p>

<p align="center">
  <a href="https://github.com/MauriceLiang/MauLeaf/releases/latest">下载最新版本</a> ·
  <a href="CHANGELOG.md">更新日志</a> ·
  <a href="https://github.com/MauriceLiang/MauLeaf/issues">反馈问题</a>
</p>

MauLeaf 是一个专注于 Mac 充电上限的轻量菜单栏工具：设置日常充电上限，出门前可临时充满一次；菜单栏默认显示绿色叶子。

应用使用 SwiftUI + AppKit 构建。当前 v0.8.0-preview.1 仍暂时使用固定版本的 [batt](https://github.com/charlie0129/batt) 执行实际充电控制；自研 AppleSMC 固件后端目前只完成只读探测、策略与事务代码，尚未通过目标设备的真实激活和充电效果验证，因此没有接管实际控制。MauLeaf 原名 ChargeCap，从 v0.7.0 起统一使用新名称。

## 能做什么

| 功能 | 使用体验 |
| --- | --- |
| 控制充电上限 | 在 50–95% 之间调整；支持快捷预设，滑块停止拖动后自动应用。 |
| 本次充满 | 临时解除充电上限，达到 100% 后自动恢复原上限；支持手动取消。 |
| 当前电量 | 显示电池百分比和当前供电状态。 |
| 绿色菜单栏叶子 | 默认固定绿色，不显示电量数字，不提供额外样式设置。 |
| 简洁界面 | 移除实时功率、主动放电、持续充满、登录项设置等非核心入口。 |
| 图形化安装与卸载 | 首次使用按提示安装控制组件；提供独立卸载器。 |

> [!IMPORTANT]
> **这是功能精简预览版，不代表原生 SMC 后端已经接管充电。** 目前 AppleSMC 写入和真实限充效果仍待目标 M1 Pro 实机验证。为保证当前充电功能可用，本预览版暂时保留 batt v0.8.0 作为实际控制后端。完成实机验证前，不要将本版本视为无 batt 依赖的最终版。

## 系统要求

- Apple Silicon（arm64）预览版：原有目标系统为 macOS 13–15；**当前版本不支持 macOS 26、27，请勿安装或继续使用。**
- Intel（x86_64）实验预览版：仅能查看电池信息，充电控制、batt 安装和卸载已禁用；**Intel 充电硬件未经兼容性验证**。
- 首次安装系统控制组件需要管理员授权；日常操作通过已安装的服务执行。
- Apple Silicon 充电控制能力以 batt 在设备上的实际报告为准；Intel 实验预览版不具备充电控制能力。

### Intel 实验预览版免责声明

**本项目维护者目前没有可用于测试的 Intel Mac 设备，因此未在任何 Intel 实机上安装、启动或测试 MauLeaf。** 虽然 GitHub Actions 会尝试编译 Intel（x86_64）安装包，但编译通过或自动化检查通过都不代表软件能够在 Intel Mac 上正常运行。包括启动、界面表现、电池信息准确性、安装与卸载、系统兼容性及稳定性在内的实际使用情况均属未知。

该安装包仅为**未经实机验证的实验性预览版本**，并非正式支持的 Intel 产品。为降低风险，实验版不内置 batt、不提供充电控制或系统服务安装、卸载功能。建议不要在依赖稳定电池管理的生产或重要设备上使用。选择下载、安装和使用实验版的用户应自行判断其适用性、备份重要数据，并承担测试未知功能和兼容性可能带来的风险。

软件按现状提供，不作关于 Intel 兼容性、适销性、特定用途适用性或无故障运行的保证；法律允许的范围内，开发者不承担因使用实验版造成的损失责任。本说明不排除或限制适用法律不得排除的权利和责任，亦不取代项目的开源许可证。

## 安装

**停止在 macOS 26/27 上安装本版本。** 已升级用户请使用 [独立安全卸载指南](docs/MACOS_26_27_UNINSTALL.md#简体中文)，不要依赖可能已经失效的应用内卸载按钮。

1. 从 [GitHub Releases](https://github.com/MauriceLiang/MauLeaf/releases/latest) 下载 `MauLeaf-<版本>-macos-arm64.dmg`（正式版）或 `MauLeaf-<版本>-macos-x86_64-EXPERIMENTAL.dmg`（Intel 只读实验版）。
2. 打开 DMG，将 `MauLeaf.app` 拖入 `Applications` 后启动。**仅 Apple Silicon 正式版**包含 `Uninstall MauLeaf.app`；Intel 实验版不包含卸载器。
3. Apple Silicon 正式版可按提示安装内置 batt。Intel 实验预览版不内置 batt，也不允许安装、卸载或执行充电控制操作。
4. 仅 Apple Silicon 正式版可选择充电模式和目标上限；Intel 实验预览版仅可查看电池信息，无法修改充电设置。
5. 默认使用中文；点击面板底部的「English」切换为英文，再点击「中文」切回。语言选择会保留到下次启动。

当前安装包使用本地 ad-hoc 签名，尚未进行 Apple notarization，macOS 可能阻止首次打开。确认下载来源后，可在系统设置「隐私与安全性」中按系统提示允许打开。

已有 Homebrew 或其他来源的 batt 时，MauLeaf 不会直接覆盖它；服务不可用或权限不足时会显示错误，请先处理原有安装。

### 从 ChargeCap 升级

先正常退出旧版 ChargeCap，再用 MauLeaf 替换原应用。已有设置、管理凭据与正常工作的 batt 服务继续复用，无需重新安装组件。确认新应用运行正常后，可移除旧 `ChargeCap.app`；请勿同时运行两个版本。

部分内部标识与数据目录保留旧名称以兼容升级，详见 [兼容约定](docs/CHARGING.md#从-chargecap-升级的兼容约定)。

## 日常使用

- **日常限充**：拖动滑块或点击 70%、75%、80%、85%、90%、95% 预设。滑块停止调整后自动应用，操作完成后会读取控制组件状态进行核对。
- **本次充满**：点击「充满至 100%」。应用会暂时解除当前上限，在达到 100% 后恢复原上限；充满过程中可点击「取消本次充满并恢复上限」提前结束。
- **菜单栏**：默认只显示绿色叶子。点击叶子打开控制面板；收起面板不会停止正在进行的单次充满任务。

当前电量和供电状态仅用于辅助判断，不再展示实时充放电功率。持续允许充满、主动放电和菜单栏图标样式选择已从界面移除。

**退出应用**会停止单次充满任务并按当前版本的退出流程释放充电控制；重新打开后会恢复已保存的充电上限。不要把收起面板当作退出应用。

## 卸载

**macOS 26/27 用户：请下载并执行 [`Scripts/uninstall-macos26-27.sh`](Scripts/uninstall-macos26-27.sh)，不要使用可能失效的图形卸载器。** 也可直接复制 [卸载指南内的完整脚本源码](docs/MACOS_26_27_UNINSTALL.md#完整卸载脚本可直接复制)。

```bash
curl -fL --output mauleaf-uninstall.sh \
  https://raw.githubusercontent.com/MauriceLiang/MauLeaf/main/Scripts/uninstall-macos26-27.sh
bash mauleaf-uninstall.sh
```

运行前请审阅脚本并保持 Mac 接通电源；**不要**使用 `sudo bash` 执行整个脚本。需要时会单独请求管理员授权。

> [!WARNING]
> **macOS 26/27 用户：不要依赖图形卸载器。请阅读 [兼容性与紧急卸载指南](docs/MACOS_26_27_UNINSTALL.md#简体中文)，审阅后运行 [Scripts/uninstall-macos26-27.sh](Scripts/uninstall-macos26-27.sh)。** 此脚本会检查组件归属，优先恢复适配器供电，再卸载 MauLeaf 管理的系统服务。

正常退出 MauLeaf，再运行安装包内的 `Uninstall MauLeaf.app`。旧版本曾注册的登录项如仍存在，可在 macOS「系统设置 → 通用 → 登录项」中单独关闭。卸载器会先尝试恢复默认充电控制，再清理由本应用管理的组件、任务、设置及 `/Applications` 内的新旧主应用，完成后可删除卸载器。外部来源的 batt 不会被删除。

仅想移除控制组件时，也可使用主面板内的「卸载组件」，保留 MauLeaf 应用。

## 运行边界

- 强制结束进程、崩溃或断电可能绕过正常退出清理，持久的限充设置可能保留。可重新启动应用后正常退出以解除控制。
- 「仅充满一次」使用固定版本 batt 的限时解除配合约 20 秒后台检查实现；睡眠期间不能保证到达 100% 时立刻恢复，另有 10 小时限时恢复兜底。
- 主动降电量依赖系统与控制服务运行。合盖停供可能使外接屏模式进入睡眠；睡眠或服务停止时，定时恢复不保证实时执行。
- 自动化检查覆盖逻辑与离屏布局；真实硬件充放电、正常退出、插拔电源、睡眠和长期能耗仍需进一步验收。完整说明见 [技术参考](docs/CHARGING.md)。

## 本地开发

从源码运行回归测试：

```bash
git clone https://github.com/MauriceLiang/MauLeaf.git
cd MauLeaf
bash tests/run.sh
```

正式安装包由 [GitHub Actions](https://github.com/MauriceLiang/MauLeaf/actions) 在推送 `vX.Y.Z` 标签后自动构建发布。CI 脚本位于 `Scripts/ci/package-macos.sh`，版本号来自标签，不使用已删除的 `build.command`。详情见 [发布指南](docs/RELEASING.md)。

测试使用模拟控制组件，不执行真实硬件控制命令；涵盖模式切换、上限恢复、保护与退出流程、自适应采样及提示不挤动布局等行为。

| 目录 | 内容 |
| --- | --- |
| `Sources/` | 主应用、充电逻辑与独立后台检查器 |
| `Assets/` | 应用图标与菜单栏资源 |
| `tests/` | 逻辑、模拟后端与离屏布局回归 |
| `Vendor/` | 固定组件版本与第三方许可证 |
| `docs/` | 运行说明、图标说明与发布记录 |

文档：[充电行为](docs/CHARGING.md) · [构建与发布](docs/RELEASING.md) · [图标说明](docs/ICON_GUIDE.md)。欢迎通过 Issue 提供 macOS 版本、芯片型号、应用版本、复现步骤和错误详情；提交前请移除个人信息。

## 许可证与致谢

MauLeaf 采用 [Apache License 2.0](LICENSE)。项目保留原始 ChargeCap 的 [MIT 声明](LICENSES/ChargeCap-Original-MIT.txt)。

感谢 [charlie0129/batt](https://github.com/charlie0129/batt) 提供底层控制能力。内置组件固定为 `v0.8.0`，作为独立 CLI 调用，遵循其 [GPL-2.0 许可证](Vendor/BATT-LICENSE.txt)；对应版本源码归档随 Release 提供。项目许可证不改变该组件的许可证。
