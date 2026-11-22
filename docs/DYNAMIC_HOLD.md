# MauLeaf 动态保电（实验性固件策略）

## 定义

「动态保电」取代 Preview 1–3 的「超限优先适配器」只读监测开关。它会在用户明确启用后，在**已验证的 MacBookPro18,1 / macOS 15 / mBoot-20457.41.3** 上，通过已有特权 Helper 调整 `bfF0/bfD0/bfE0` 的固件保持区间，不写入新类型的 SMC 寄存器。**此功能不保证实际电源来自适配器，也不保证停止电池放电**。成功写入/读回只说明固件寄存器达到请求值，必须以真实电流、功率和系统状态验证效果。

## 双值模型

- `userTarget`：用户原始目标，仍存储在 `UserDefaults.chargeLimit` 中，界面始终显示该数值（50–95%）。
- `effectiveUpper`：实际写入固件的临时上限。只在动态保电有效、外接电源稳定且电量高于目标时，可以大于 `userTarget`（允许最高 100%）。
- `effectiveLower`：始终使用 `max(5, userTarget - 2)`，而不是临时上限减 2。避免当电量下降时因为临时保持区间触发频繁再充电。

例如目标 80%、实际原始电量 95.4%，动态临时区间是 **78%–96%**；当物理断电经系统确认后，下次重新接电电量为 88.2%，新保持上限捕获为 **89%**，不能沿用旧的 96%。电量等于或低于 80% 时自动恢复 **78%–80%** 区间。

原始容量来自 `AppleSmartBattery.AppleRawCurrentCapacity / AppleRawMaxCapacity`，并向上取整得到临时上限。缺失、非法或超过 100% 的原始数据**拒绝自动写入**，不得从舍入的 UI 百分比合成。单次已捕获的有效临时上限在连接期间保持不变，不跟随细小电量下降不断修改。

## 电源事件、后台与安全

1. 默认关闭；与旧 `preferAdapterAboveLimit` 偏好完全独立，升级不会因曾开启旧只读监测而自动写入固件。
2. 首次启用限充仍遵循原先明确的固件写入确认和 macOS 管理员授权流程。动态保电不绕过固件设备/系统/固件 allowlist，也不跳过 Helper 内部 AC 校验。
3. 断电时**绝不进行动态写入**。本机曾实测 `AppleSmartBattery.ExternalConnected` 在物理拔电后延迟约 4–6 秒，因此重新插电后必须连续检测并等待不少于 8 秒再自动调整；该延时是降低竞态风险的临时保护，不是物理充电器存在的独立硬件证明。数据不可信时跳过。
4. 应用每 20 秒低频状态轮询以及 IOKit 电源事件均可触发去抖动协调；未变化时不重写寄存器，写入失败有 60 秒冷却，避免反复高频控制。
5. 用户目标与实际固件区间不同是预期现象。应用重启时可从已托管 Helper 的实际固件状态恢复临时区间；发生真正断电并再次接电后，重新捕获临时保持上限。
6. 「本次充满」优先于动态保电，使用**当前有效固件区间**创建原有 10 小时持久恢复任务。**任务开始后「动态保电」分段开关置灰、禁止点击，也拒绝程序内部对其状态的改动**；已启用的策略临时暂停，已关闭的保持关闭，不修改用户保存的选择。Helper 返回本次充满已完成且限充区间成功恢复之后，开关才解除禁用；之前开启的动态保电重新计算当前原始电量并恢复执行，之前关闭的仍保持关闭。手动取消并成功恢复限充后走同样逻辑；取消后若还在等待接电恢复，继续锁定开关，**绝不与进行中的本次充满任务并发写固件**。
7. 关闭限充或退出应用时依然优先执行已有的**精确原始固件快照恢复/安全卸载链路**，动态策略不得替代快照。对于未知/未验证的旧 Helper，禁止静默写入或清理。
8. 本次将 Helper 的协议版本由 v5 升为 **v6**、构建版本由 `1.0.0` 升为 `1.1.0`，因为新版本接受 96–100% 的临时上限。启动时现有版本检查会要求用户授权升级。UI-only 更新不应继续增加 Helper 版本。
9. 不自动强制放电；不写 `CHIE/CH0I/CH0J`、不重启 `powerd`、不假装此功能已经实现 AC bypass。

### 已知限制

- 动态协调由正在运行的 MauLeaf 应用管理。**完全退出后不会继续动态调整**，且会优先恢复原始固件状态；Helper 保留原有安全恢复任务而非新的动态守护任务。
- 过高的临时上限（尤其 100%）可能因固件策略导致充电或电源状态不同；目前没有用户设备上的动态保电写入实机验收数据。
- `ExternalConnected` 和 `pmset` 可能共享相同的上游状态，本预览只做稳定期抑制，尚未实现独立的 `AC-W` 物理供电验证。实际固件写入前仍必须经过现有 Helper allowlist 和授权检测。
- 若实际持续放电、仍有 5–6 秒断电识别延迟或出现异常充电，应关闭动态保电，必要时通过「关闭限充」恢复原始配置，再保留诊断记录反馈。
- 不能把“固件上限临时上调”宣传成永久严格遵守 80% 上限；界面必须明确展示“用户目标”和“临时固件上限”。

## English summary

Dynamic Hold is opt-in and experimental. It stores the original user target separately from the temporarily elevated firmware ceiling, captures fractional battery SoC from raw capacity using ceil, and recaptures after a confirmed unplug/replug. It never writes during unplug, uses an 8-second AC stability delay for automatic updates, and never claims that firmware readback proves adapter-powered operation. One-time full charge and exact original-state restoration retain priority. The privileged Helper moves to protocol v6 / build 1.1.0 for the 96–100% firmware ceiling range; existing Helpers require a user-authorized compatible upgrade. Real power-flow and disconnect-latency behavior still require target-device tests.
