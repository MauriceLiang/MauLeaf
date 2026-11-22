# MauLeaf：拔电后 macOS 系统仍报告连接电源（5–6 秒）— 排查方案

## 已确认事实

用户观察到拔掉充电器后，**macOS 系统电池菜单**本身仍显示连接电源约 5–6 秒，之后才切换到电池；不仅是 MauLeaf 的 UI 显示滞后。MauLeaf Preview 3 的 IOKit 事件刷新只在 macOS 发布电源状态变化时执行，不能改变系统上游的 SMC、AppleSmartBattery 或 powerd 行为。

MauLeaf 当前只会在用户启用/调整固件限充、开始/取消本次充满以及恢复原始固件状态时写入 `bfF0/bfD0/bfE0`。常规电源观察以及 XPC `readState()` 不执行固件写入。**但不能因此排除仍处于激活状态的固件限充影响系统供电行为**。

Apple 开源的 `IOPowerSources.h` 文档提到：拔电后**剩余时间估算**可能需要数秒重新计算。此信息不等于证实 macOS 的“是否连接电源”本身固定延迟 5–6 秒。切勿直接将此行为定性为正常或者归因于 MauLeaf。

## 无写入诊断流程

脚本 `Scripts/diagnose-power-transition.sh` 不需要 sudo、不读取任何 SMC 寄存器、不改变电源/LaunchDaemon/应用配置、不收集序列号或个人信息。每约 0.5 秒分别读取：

- `pmset -g batt` 的“当前供电源”（macOS 系统电源管理报告）。
- `AppleSmartBattery.ExternalConnected`（IORegistry 底层外接电源状态）。
- `AppleSmartBattery.IsCharging` 与 `Amperage`（仅辅助区分充电和放电；不能单独证明供电路径）。

运行：

```bash
bash Scripts/diagnose-power-transition.sh 25
```

在每次运行前先接入充电器，并在大约**第 10 个采样点（约 5 秒）**拔掉；保持无其他充电来源（例如有供电功能的 USB-C 显示器/扩展坞），并使用同一个充电接口和适配器。每种场景尽量测试两次：

1. **限充已启用，MauLeaf 正在运行**：记录当前约 5–6 秒的异常。
2. **在 MauLeaf 界面关闭限制充电、验证原始固件恢复成功，但仍保持 App 运行**：重复相同过程。
3. **使用 MauLeaf 的正常退出流程（先恢复，再按需保留或安全移除 Helper）后**：重复。不能强制杀死 Helper 或手动删除恢复文件。
4. 如果第二或第三步仍延迟，可选择**正常重启 Mac**，不启用 MauLeaf 限充再测，以排除现有固件状态持久化和系统缓存。发生恢复失败时停止测试，保留 Helper 和原始快照。

## 结果解释

| 观察 | 首要调查方向 |
|---|---|
| `ExternalConnected` 与 `pmset` 都延迟改变，且只在限充开启时出现 | 固件限充策略或其与 AppleSmartBattery / powerd 的交互 |
| `ExternalConnected` 立即改变，但 `pmset` 延迟数秒 | powerd 的系统状态同步、其他充电源或软件管理层 |
| 两者立即改变，但系统电池菜单仍旧 | 系统菜单 UI/缓存（非上游实际状态） |
| 关闭限充、正常退出、重启后均有相同延迟 | 更可能为 macOS 电源管理、充电器/供电设备或硬件行为 |
| 拔掉某个充电器后仍有 USB-C 显示器/扩展坞供电 | 不是真正的外部供电全部断开；需要排除第二供电源 |

上述均为**定位依据，而非定论**。物理拔电时刻是人工操作的近似时间；脚本对两个来源顺序采样，误差可达一个采样周期加上命令执行时间。记录状态切换的相对时间，不把系统时钟秒级输出当作精密硬件测量。

## 安全边界

- 不写入/清除任何 SMC 键，不重置电池固件，不重启 powerd。
- 不使用 `sudo`；不手动 `launchctl bootout` 或删除 `/Library/Application Support/MauLeaf`。
- 如果在尝试关闭限充时出现“无法确认已恢复”的报错，立即停止，**不要强制卸载或拖走 App**；保留快照并反馈日志。
- 先得到相同电源硬件条件下的三组对比数据，再决定是否更改 MauLeaf 固件限充逻辑。

## English summary

The reported symptom affects macOS' **own battery menu**, not just MauLeaf UI. Use the read-only probe to compare system `pmset` and the raw `AppleSmartBattery.ExternalConnected` state while unplugging around sample 10. Repeat with MauLeaf's firmware limit enabled, safely disabled/restored, and after a verified normal quit. Do not force-remove root Helper or firmware restore records. Preview 3's UI notification code cannot accelerate macOS' underlying power-state propagation.
