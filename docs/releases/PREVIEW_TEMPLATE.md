## 简体中文

### MauLeaf {{VERSION}} — 原生控制预览版

本版本由 main 分支合并后自动构建，仅提供 Apple Silicon arm64 安装包，不再构建或发布 Intel 版本。

- 首次启动默认不启用充电限制；用户点击「启用限制充电」后才写入原生固件。
- 正常退出 MauLeaf：插电立即恢复；在经过真机验证的 M1 Pro/macOS 15/固件配置上，不插电也能恢复全部原始寄存器。若离线恢复条件不满足，保留持久恢复请求和 Helper 并允许退出，但不声称已安全卸载；极端异常时用户也可选择「仍然退出」，而不能把此操作当作卸载。
- 未启用时，调整滑杆或预设只保存本地设置，不会写入 AppleSMC。
- 首次启用前，helper 保存 bfF0、bfD0、bfE0 原始值及硬件身份到 root-owned 快照；后续修改上限不会覆盖原始快照。
- 「关闭限制充电」会恢复原始激活字节、上限和恢复阈值，逐项读回验证后才删除快照。
- 安全完整卸载：无论接电或满足验证条件的电池供电，脚本必须先恢复启用前的全部三个寄存器、确认限充关闭且没有待恢复任务，之后才删除 MauLeaf.app、Helper、LaunchDaemon、快照及所有安装/卸载/收尾脚本；任何验证失败都保留文件并返回错误。
- 「本次充满」仍只临时关闭当前 MauLeaf 限充，结束后恢复当前上限；用户关闭限充时则恢复首次启用前的原始状态。
- 删除危险的无恢复强制卸载模式；离线恢复严格限定 MacBookPro18,1 / mBoot-20457.41.3 / macOS 15 / arm64，要求 IOKit 与 pmset 双重确认电池供电、电量至少 30%、原始快照有效且原始激活字节为 0。

- 菜单栏固定绿色叶子。
- 移除 Intel 构建矩阵、Intel 实验安装包及相关发布流程。
- Preview 4 及更早版本没有原始快照；旧状态迁移时只能停用激活标志，无法恢复历史阈值，界面和卸载脚本都会明确提示。

**硬件验证边界：** 已在目标 M1 Pro 真机验证断电关闭 bfF0、恢复 bfD0/bfE0，重新接电能够正常充电；正式卸载事务仍须在新预览版上完成端到端测试。新建或修改限充仍仅放行已验证的 MacBookPro18,1、mBoot-20457.41.3、macOS 15、arm64 配置，并要求接通电源和用户明确确认。已保存快照的恢复操作使用独立授权，只允许相同机型、系统固件和 arm64 架构；系统升级后仍可尝试恢复原始状态。寄存器逐项读回成功不等于真实充电停止点已经验证。目标 M1 Pro 仍需在接电状态下实测上限停止和下限恢复行为。此版本仍是硬件验证预览版，自动化测试使用 fake SMC transport，不会写入真实硬件。

## English

### MauLeaf {{VERSION}} — Native-control preview

This release is built automatically after changes are merged into main. It ships Apple Silicon arm64 only; Intel builds and release artifacts are discontinued.

- Charging limits are off by default on first launch. The user must click “Enable charging limit” before firmware is changed.
- Normal app quit restores immediately on AC or under the verified M1 Pro battery-only conditions. When battery restoration is blocked, the helper retains a durable recovery request; Quit anyway does not mean a verified full uninstall.
- While disabled, slider and preset changes are saved locally and do not write to AppleSMC.
- Before the first activation, the helper saves the original bfF0, bfD0, and bfE0 values plus hardware identity in a root-owned snapshot. Later limit changes never overwrite it.
- “Disable charging limit” restores the original activation byte, upper threshold, and resume threshold, and deletes the snapshot only after read-back verification.
- Complete uninstall is a single fail-closed transaction: restore all original firmware registers, independently verify normal SMC state, then remove the application, Helper, LaunchDaemon, snapshots, and installed scripts. A failed restore retains the app and recovery components.
- The dangerous force-remove-without-restore option is removed. Unplugged complete restore is restricted to exact verified M1 Pro hardware, macOS 15 and matching firmware, with dual battery-source checks, >=30% charge and an inactive original snapshot.
- “One-time full charge” still temporarily disables the current MauLeaf limit and restores that limit afterward. Disabling MauLeaf restores the original pre-activation firmware state.
- The menu bar always displays the green leaf.
- Remove the Intel build matrix, Intel experimental package, and related release steps.
- Preview 4 and earlier releases have no original-state snapshot. Legacy migration can only deactivate the activation flag; historical thresholds cannot be reconstructed, and the app and uninstaller report this explicitly.

**Hardware-validation boundary:** The target M1 Pro has physically validated unplugged bfF0 deactivation, original upper/lower restoration and resumed charging after AC reconnect. The newly integrated full uninstallation transaction still requires a separate on-device end-to-end validation. New limit writes remain restricted to the validated MacBookPro18,1, mBoot-20457.41.3, macOS 15, arm64 profile, with AC power and explicit user confirmation. Restoration of a saved snapshot uses separate authorization and requires the same model, system firmware, and arm64 architecture; it may still be attempted after an OS upgrade. Successful register read-back does not prove that charging physically stops at the selected threshold. The target M1 Pro still requires AC-powered observation of both stop and resume behavior. This remains an experimental hardware-validation preview. Automated tests use a fake SMC transport and never write to physical hardware.
