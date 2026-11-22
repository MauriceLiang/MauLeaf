# MauLeaf：拔电后 macOS 系统仍报告连接电源（5–6 秒）— 排查方案

## 已确认事实

用户观察到拔掉充电器后，**macOS 系统电池菜单**本身仍显示连接电源约 5–6 秒，之后才切换到电池；不仅是 MauLeaf 的 UI 显示滞后。MauLeaf Preview 3 的 IOKit 事件刷新只在 macOS 发布电源状态变化时执行，不能改变系统上游的 SMC、AppleSmartBattery 或 powerd 行为。

MauLeaf 当前只会在用户启用/调整固件限充、开始/取消本次充满以及恢复原始固件状态时写入 `bfF0/bfD0/bfE0`。常规电源观察以及 XPC `readState()` 不执行固件写入。**但不能因此排除仍处于激活状态的固件限充影响系统供电行为**。

Apple 开源的 `IOPowerSources.h` 文档提到：拔电后**剩余时间估算**可能需要数秒重新计算。此信息不等于证实 macOS 的“是否连接电源”本身固定延迟 5–6 秒。切勿直接将此行为定性为正常或者归因于 MauLeaf。

## 新增实机 A/B 结果（2026-11-22）

用户已进行初步对照：**同一台 MacBook 上，仅运行 MauLeaf 而未启用限充时，拔掉电源后 macOS 自带电池菜单立即切换到电池；启用限充后，系统菜单本身延迟约 5–6 秒才切换。** 该结论缩小了问题范围：无需继续优先修复 SwiftUI 的刷新计时器，应该调查 `bfF0` 激活后的 AppleSMC 电源报告与 AppleSmartBattery / powerd 状态转换。

这不等于已经证明 `bfF0` 直接导致延迟。还需要记录 `ExternalConnected` 与 `pmset` 各自何时变化，并确认测试时的电量和上限关系。已知同类固件限充在电量高于上限时可能切断外部取电、主动使用电池；该行为可能与系统电源状态变化有关，但不是已验证的因果解释。

**潜在写入安全影响：** 现有 Helper 授权新限充写入时使用 `AppleSmartBattery.ExternalConnected` 判断是否接电。如果这个字段也在物理拔电后保持 true 数秒，拔电期间的写入前置条件有可能短暂误判。实机证据出现前，不自动修改其他 SMC 键；应优先确定源头，然后设计额外的独立供电信号或稳定性校验。绝不能把 `pmset` 当作已验证独立来源，它可能共享同一底层状态。

**下一轮只需补充两项关键信息：**
1. 限充开启时，拔电后的 `ExternalConnected` 是否也滞后约 5–6 秒，还是只有 `pmset` / 系统菜单滞后；
2. 发生延迟时，当前电量相对于设置上限是**高于、等于、还是低于**；在同等 SOC、同一电源条件下复测，以排除不同限充阶段的影响。

## 实机诊断记录：已启用限充，电量高于上限（23:39:46–23:40:07）

用户确认物理拔掉充电器的时间为**运行脚本约第 10 秒**，即 23:39:56 左右，**不是第 10 条采样**。

- 样本 001–025：`pmset=AC`、`AppleSmartBattery.ExternalConnected=Yes`、`IsCharging=No`。
- 样本 019（23:39:56）至样本 025（23:40:00）：两种系统来源仍报告外部电源连接。
- 样本 026（23:40:00）首次同时变成 `pmset=battery` 和 `ExternalConnected=No`，其后一直维持到样本 038，用户用 Ctrl-C 停止采样。
- 所有样本的 `Amperage=unknown`，因此这次采样**没有证实电池实际放电电流**；也不应据此推导功率路径。
- 根据人工报告拔电时刻估计：物理断电后约 4 秒才观测到 macOS 两个来源更新。观察误差受人工操作、顺序采样与秒级输出影响；此前约 5–6 秒的主观观察大体一致。
- 仅能证明**高于上限、限充开启时**存在系统底层供电状态滞后。用户报告限充关闭时立即更新，但尚未提供相应的同步采样日志；低于上限的场景未测试。
- `pmset` 与 `ExternalConnected` 同一周期变化，支持系统源状态同步滞后，而非仅 MauLeaf UI 缓存。两者可能共享电源管理上游，不能仅凭同时变化断言 AppleSMC 就是根因。
- **安全提醒：** 如果 Helper 授权写入所依赖的 `ExternalConnected` 同样在物理拔电后保持 true 数秒，那么立刻拔电并操作限充可能让软件短时误判“仍在 AC”。在定位之前不应在刚拔电时请求新的 SMC 写入。

下一步优先在**充电电量低于所设上限**时复现（避免强迫放电），确认延迟是否只与超限固件策略有关；对照仍然使用同一根线、接口、适配器，不要通过关闭硬件校验来排查。

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
