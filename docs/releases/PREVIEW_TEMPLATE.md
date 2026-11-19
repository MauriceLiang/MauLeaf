## 简体中文

### MauLeaf {{VERSION}} — 原生控制预览版

本版本由 main 分支合并后自动构建，包含 MauLeaf 当前原生充电控制实现。

- 主界面保留当前电量、50–95% 充电上限和「本次充满」。
- Apple Silicon 版本使用 MauLeaf 自研 AppleSMC 控制器和随应用打包的原生特权服务，不包含 batt 二进制、第三方固件资源或第三方控制调用。
- 「本次充满」由原生后台服务管理恢复任务；达到 100%、用户取消或 10 小时期限后恢复原上限。
- 菜单栏固定绿色叶子。
- 修复系统固件版本识别：递归读取 IODeviceTree 子节点并正确解析固件属性。
- 升级应用时自动检测并更新旧版 MauLeaf 原生后台服务。
- Intel 版本为未经实机验证的只读实验版，不包含原生特权服务，不提供充电控制。

**硬件验证边界：** 原生写入仅放行已验证的 MacBookPro18,1、mBoot-20457.41.3、macOS 15、arm64 配置，并要求接通电源和用户明确确认。寄存器逐项读回成功不等于真实充电停止点已经验证。目标 M1 Pro 仍需在接电状态下实测上限停止和下限恢复行为。自动化测试使用 fake SMC transport，不会写入真实硬件。

## English

### MauLeaf {{VERSION}} — Native-control preview

This preview is built automatically after changes are merged into the main branch.

- The main panel keeps battery status, a 50–95% charging limit, and one-time full charge.
- Apple Silicon builds use MauLeaf's own AppleSMC controller and bundled privileged native service. No batt executable, third-party firmware assets, or third-party control invocations are included.
- The native background service manages one-time restoration at 100%, on cancellation, or after the 10-hour deadline.
- The menu bar always displays the green leaf.
- Fix system firmware detection by recursively reading nested IODeviceTree properties.
- Detect and automatically upgrade an older installed MauLeaf native helper when the app is updated.
- The Intel build is an untested read-only experiment. It contains no privileged native service and provides no charging controls.

**Hardware-validation boundary:** Native writes are restricted to the validated MacBookPro18,1, mBoot-20457.41.3, macOS 15, arm64 profile, with AC power and explicit user confirmation. Successful register read-back does not prove that charging physically stops at the selected threshold. The target M1 Pro still requires AC-powered observation of both stop and resume behavior. Automated tests use a fake SMC transport and never write to physical hardware.
