[简体中文](README.md) | [English](README.en.md)

> [!CAUTION]
> **当前预览版仅针对 Apple Silicon、macOS 15 和已验证的目标硬件配置。macOS 26/27、Intel 以及其他未经验证的机型均不支持充电控制。**

<p align="center">
  <img src="Assets/MauLeafIcon-1024.png" width="128" alt="MauLeaf 叶子图标">
</p>

<h1 align="center">MauLeaf</h1>

<p align="center">轻量、原生的 macOS 菜单栏充电控制工具</p>

<p align="center">
  <a href="https://github.com/MauriceLiang/MauLeaf/releases/latest">下载 Preview</a> ·
  <a href="CHANGELOG.md">更新日志</a> ·
  <a href="https://github.com/MauriceLiang/MauLeaf/issues">反馈问题</a>
</p>

MauLeaf 只保留两项充电操作：设置日常充电上限，以及仅本次充满至 100%。菜单栏固定显示绿色叶子。

**本预览版已经移除第三方充电控制后端。** 不包含 batt 可执行文件、第三方固件资源或 batt 调用代码。充电设置由 MauLeaf 自研 AppleSMC 控制器直接处理，并通过随应用打包的原生特权服务执行受保护的固件写入。

## 功能

| 功能 | 说明 |
| --- | --- |
| 充电上限 | 50–95%，支持滑杆和 70/75/80/85/90/95% 快捷预设 |
| 本次充满 | 临时关闭固件限充；达到 100%、手动取消或 10 小时期限后恢复原上限 |
| 电池状态 | 显示当前电量和供电状态 |
| 菜单栏 | 固定绿色叶子，不显示百分比，不提供样式切换 |

没有实时功率卡片、主动放电、持续充满、登录项设置或第三方控制组件安装页面。

## 硬件范围与安全边界

当前首要目标为：

- 机型：MacBookPro18,1（Apple M1 Pro）
- 系统：macOS 15
- 固件：mBoot-20457.41.3
- 控制寄存器：AppleSMC 的 `bfF0`、`bfD0`、`bfE0`

写入前会检查目标机型、固件版本、系统版本、寄存器元数据、电源连接和用户确认；写入后逐项读回校验，失败时尝试恢复此前状态。**未连接电源或硬件条件不匹配时，不会执行写入。**

> [!IMPORTANT]
> 原生控制已经接入应用，但目标 M1 Pro 上的实际充电停止点和恢复点仍需接电实测。寄存器写入并读回成功，不等于已经证明电池会在设定百分比停止充电。请把本版本视为硬件验证预览版，不要依赖它承担未经验证的关键电池管理任务。

首次启动时，应用会自动请求一次管理员授权，以安装 MauLeaf 自己的 AppleSMC 特权服务。此服务由本仓库源码构建，不是 batt，也不提供通用 SMC 写入接口。界面不再显示旧版「安装控制组件」卡片。

## 安装

1. 从 [GitHub Releases](https://github.com/MauriceLiang/MauLeaf/releases) 下载 Apple Silicon 的 `MauLeaf-<版本>-macos-arm64.dmg)。
2. 将 `MauLeaf.app` 拖入「应用程序」并启动。
3. 首次启动时，按 macOS 提示授权安装 MauLeaf 原生固件服务。
4. 确认状态显示原生固件限充可用后，连接电源再修改上限。

Intel 安装包仅为未经实机验证的只读实验版，不包含原生特权服务，也不提供充电控制。macOS 26/27 不在当前支持范围内。

### 从旧版升级

如果以前的 MauLeaf 版本安装过第三方充电控制服务，请先按旧版本提供的卸载流程清理旧服务，再安装此预览版。新版本不会调用、检测、覆盖或自动卸载其他来源的控制程序。

## 日常使用

- **充电上限**：连接电源后拖动滑杆，或点击快捷预设。首次写入会出现一次原生固件写入确认。
- **本次充满**：点击「充满至 100%」。原生后台服务会监控电量，并在 100% 或 10 小时期限后恢复原上限。若任务完成时未连接电源，会保留恢复任务，等重新接电后恢复。
- **退出应用**：已设置的固件限充会继续由系统固件执行；本次充满恢复任务由 MauLeaf 特权服务独立负责。

## 卸载原生服务

先确认没有正在等待恢复的「本次充满」任务，再执行应用内脚本：

```bash
sudo "/Applications/MauLeaf.app/Contents/Resources/MauLeafNativeControl/uninstall-native-firmware-helper.sh"
```

脚本只会卸载 MauLeaf 自己的 LaunchDaemon 和 helper，不会改写当前固件限充值。完成后可将 `MauLeaf.app` 移入废纸篓。

## 本地开发与测试

```bash
git clone https://github.com/MauriceLiang/MauLeaf.git
cd MauLeaf
bash tests/run.sh
```

自动化测试使用内存中的模拟 SMC transport，不会对真实硬件写入。Release 由 GitHub Actions 构建，Preview 标签格式为 `vX.Y.Z-preview.N`。

## 项目结构

| 目录 | 内容 |
| --- | --- |
| `Sources/` | SwiftUI 菜单栏应用、AppleSMC 事务控制器、XPC 特权服务 |
| `Support/` | 原生 LaunchDaemon 配置 |
| `Scripts/` | 原生服务安装、卸载和 CI 打包脚本 |
| `Tools/` | 只读硬件探测及独立验证工具 |
| `tests/` | 固件事务、服务、恢复任务和界面回归测试 |
| `docs/` | 硬件边界、充电行为与发布说明 |

## 许可证

MauLeaf 使用 [Apache License 2.0](LICENSE)，并保留原 ChargeCap 的 [MIT 声明](LICENSES/ChargeCap-Original-MIT.txt)。当前预览版不再捆绑第三方充电控制程序或其固件资源。
