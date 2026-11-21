## 简体中文

### MauLeaf {{VERSION}} — 原生控制预览版

本版本由 main 分支合并后自动构建，仅提供 Apple Silicon arm64 安装包，不再构建或发布 Intel 版本。

- **减少管理员密码输入：** 打开应用仅进行只读检查，不再自动安装或升级特权服务，也不会自动开启限充；首次点击顶部「限制充电」并确认后，才根据需要申请一次管理员授权安装/升级 Helper。
- **保留组件退出无需密码：** 先恢复并核对原始固件状态，保留 launchd MachService 注册；Helper 在无待恢复任务且连接空闲约 20 秒后自行退出，下次打开无需重新安装。选择「移除组件并退出」时，删除已安装的系统组件仍需管理员授权。
- 未安装 Helper 时可正常查看电池及设置上限、退出应用；系统中存在旧 Helper 或恢复记录但服务无法连接时，不会误报充电限制已经关闭。

- 顶部卡片的「限制充电」与「本次充满」状态胶囊现在可以直接点击启用或关闭；供电状态继续只读。移除卡片下方重复的「本次充满」开关。
- 「充电上限」展开后仅保留 50–95% 滑杆、快捷预设与必要的恢复说明，不再重复显示启用/关闭按钮。旧版限充警告、待恢复重试及首次固件写入确认继续通过顶部卡片处理；设置、退出及 Helper 安全恢复流程不变。

- **状态反馈改造：** 取消原本遮挡「设置」的底部悬浮 Toast。启用/调整/恢复充电上限、开启/取消本次充满及修复 Helper 时，直接在对应的顶部卡片状态按钮内显示轻量进度；成功后立即展示真实状态。失败信息嵌入电量卡片下方，支持关闭、查看详情及符合条件时重试；退出检查等非常规任务也使用嵌入式进度，不遮挡其他菜单。
- **Preview 2 顶部卡片排版：** 供电状态改为右对齐的只读文字，不再显示为按钮胶囊；限充与本次充满保留点击功能，胶囊统一 29pt 高度、宽度随状态变化，全部禁止换行。简化英文为 Power / Charge limit / Full charge、Plugged in / Charging / On battery、On · 80% / Off / Active；中文保持直观。鼠标悬停及 VoiceOver 仍可读取完整供电状态和「本次充满只临时充至 100%」的说明，硬件与恢复逻辑不变。
- **Preview 3 极简模式：** 顶部默认隐藏大电量数字，只保留「供电状态」「限制充电」「本次充满」三行；在「设置 → 显示当前电量」可随时启用，并保存偏好供下次启动使用。启用时以 42pt 数字、24pt 百分号紧凑展示，避免空白和多余高度。充电时仅供电图标与状态文字高亮为绿色，接电未充电及电池供电保持中性色；电量数字不随充电变绿，只有电池供电且低电量时使用警示色。原生固件控制、授权及恢复机制保持不变。
- **Preview 4 更紧凑的顶部卡片与统一设置：** 默认三行状态卡片的行间距调整为 3pt，每行最小高度 32pt、上下内边距 13pt；与下方菜单的间距由 12pt 缩至 8pt，不缩小文字与 29pt 操作按钮。设置中的「显示当前电量」与「界面语言」均改为宽度相同的原生分段选择器，分别为「关闭 / 开启」与「中文 / EN」，选中状态始终清楚可见。电量与语言设置继续持久保存，切换无须重新启动；固件写入、恢复、权限和任务反馈逻辑不变。
- **Preview 9 双向叶子形变：** 修复上一版仅淡入、关闭瞬间消失的问题。展开以菜单栏绿色叶子图标的真实屏幕中心为起点，临时圆角材质浮层从约 24pt 扩展到完整单卡片；关闭时先淡出控制内容，再沿同一几何路径将卡片缩回图标。文字与按钮始终保持原始尺寸，不参与压缩变形。动画完成即销毁临时浮层，正常情况下只有唯一控制卡片；保留系统「减少动态效果」、权限弹窗保护、失焦关闭、安全退出及 Preview 7 的卡片内部展开逻辑。
- **Preview 8 菜单栏入场动效：** 点击菜单栏绿色叶子打开主控制卡片时，卡片从菜单栏下方锚点轻微向下展开，并在约 220ms 内柔和淡入，消除直接闪现的突兀感。顶部指示角保持稳定，控制内容和字号不缩放；系统开启「减少动态效果」时直接显示。快速关闭、重新打开时避免旧动画残留，保留 Preview 7 的设置与充电上限内部展开动效、单卡片材质及固件安全恢复流程。
- **Preview 7 平滑展开动效：** 点击「充电上限」或「设置」时，使用统一约 240ms 的缓动动画同步处理内容淡入/轻微位移、箭头旋转以及整个浮动卡片的高度变化；NSPanel 顶部持续锚定菜单栏，下边缘平滑展开与收起，不再瞬间跳变。首开不播放错误的高度修正动画，避免 SwiftUI 布局回调重复触发同一目标动画；系统开启减少动态效果时遵循无动画偏好。授权、固件控制与恢复安全机制不变。
- **Preview 6 单卡片浮层：** 移除原有 AppKit 标题栏与外层边框，使用可获取键盘焦点的透明 NSPanel，弹窗本身就是唯一一张带圆角、顶部小指示角和系统材质的浮动卡片。将供电状态、限制充电、本次充满、充电上限、设置、退出全部放到同一表面，仅用轻量分割线区分状态与配置；图标和标题统一起点，保留供电文字与胶囊内部文字的右端对齐。充电上限、设置在单卡片内展开，任务失败提示继续随布局展开，不叠加遮挡。保留系统阴影、两种语言、可选电量显示、授权确认及固件恢复逻辑。
- **Preview 5 供电文字精确对齐：** 将只读「供电状态」右侧文本的末端内缩 12pt，使其与下方限充、本次充满胶囊内部文字的右边缘对齐，而不是与胶囊外沿对齐。中文和英文统一，保持现有卡片尺寸、绿色充电状态、按钮点击面积、操作反馈和固件安全逻辑不变。
- 首次启动默认不启用充电限制；用户点击顶部卡片「限制充电」右侧状态按钮并确认后才写入原生固件。
- 正常退出可选择「保留组件并退出」「移除组件并退出」「取消」。恢复并验证固件后，保留模式维持 launchd 注册、无需管理员密码（后台 Helper 空闲时自行退出），移除模式删除系统级脚本/服务，App 由用户在 Finder 删除。恢复或清理失败会取消正常退出；紧急「仍然退出」不代表成功恢复。
- 未启用时，调整滑杆或预设只保存本地设置，不会写入 AppleSMC。
- 首次启用前，helper 保存 bfF0、bfD0、bfE0 原始值及硬件身份到 root-owned 快照；后续修改上限不会覆盖原始快照。
- 「关闭限制充电」会恢复原始激活字节、上限和恢复阈值，逐项读回验证后才删除快照。
- 保留备用终端完整卸载命令，可在 App 正常关闭后独立删除 App 与系统组件。应用内「移除组件并退出」只删除系统 Helper、LaunchDaemon、恢复记录、脚本及日志；不会在运行过程中删除应用包。
- 「本次充满」仍只临时关闭当前 MauLeaf 限充，结束后恢复当前上限；用户关闭限充时则恢复首次启用前的原始状态。
- 删除危险的无恢复强制卸载模式；离线恢复严格限定 MacBookPro18,1 / mBoot-20457.41.3 / macOS 15 / arm64，要求 IOKit 与 pmset 双重确认电池供电、电量至少 30%、原始快照有效且原始激活字节为 0。

- 菜单栏固定绿色叶子。
- 移除 Intel 构建矩阵、Intel 实验安装包及相关发布流程。
- Preview 4 及更早版本没有原始快照；旧状态迁移时只能停用激活标志，无法恢复历史阈值，界面和卸载脚本都会明确提示。

**硬件验证边界：** 已在目标 M1 Pro 真机验证断电关闭 bfF0、恢复 bfD0/bfE0，重新接电能够正常充电；正式卸载事务仍须在新预览版上完成端到端测试。新建或修改限充仍仅放行已验证的 MacBookPro18,1、mBoot-20457.41.3、macOS 15、arm64 配置，并要求接通电源和用户明确确认。已保存快照的恢复操作使用独立授权，只允许相同机型、系统固件和 arm64 架构；系统升级后仍可尝试恢复原始状态。寄存器逐项读回成功不等于真实充电停止点已经验证。目标 M1 Pro 仍需在接电状态下实测上限停止和下限恢复行为。此版本仍是硬件验证预览版，自动化测试使用 fake SMC transport，不会写入真实硬件。

## English

### MauLeaf {{VERSION}} — Native-control preview

This release is built automatically after changes are merged into main. It ships Apple Silicon arm64 only; Intel builds and release artifacts are discontinued.

- **Fewer administrator prompts:** Launching MauLeaf is read-only and never auto-installs/upgrades its privileged helper or enables a charge limit. The first explicit top-card limit activation requests macOS authorization only when installation or upgrade is needed.
- **Password-free Keep-and-Quit:** Restore and verify original firmware, retain the registered on-demand MachService, and allow the Helper to self-exit after approximately 20 idle seconds. The next launch reuses the existing registration. Removing installed privileged components still requires authorization.
- A fresh installation can read battery state, edit a local limit and quit without a Helper. Unreachable installed Helpers or retained recovery artifacts are never misreported as safely disabled.

- The top-card charging-limit and one-time-full status pills now directly enable/disable their respective controls; power status stays read-only. The duplicate lower one-time-full switch has been removed.
- Expanding Charging Limit displays only the slider, presets and relevant recovery guidance—no second enable/disable button. Existing first-write confirmation, legacy-limit handling, pending-restore retry, Settings and safe Quit/Helper lifecycle are preserved.

- **Inline operation feedback:** Remove the bottom toast that previously covered Settings. Limit enable/apply/restore, one-time-full start/cancel and helper repair show localized progress within their own status pills; successful actions immediately display the real state. Errors appear below the battery card with dismiss/details/retry controls, and exceptional tasks such as quitting use nonoverlapping inline progress.
- **Preview 2 bilingual card layout:** Render power as right-aligned read-only text instead of a button-like capsule. Charge limit and Full charge remain clickable, with 29pt-tall, content-sized, single-line status pills. Shorten English titles/statuses to Power / Charge limit / Full charge, Plugged in / Charging / On battery and On · 80% / Off / Active. Full power diagnostics and the one-time-to-100% behavior are still available via hover/VoiceOver. Firmware control and restoration safety logic are unchanged.
- **Preview 3 compact by default:** The large battery percentage is hidden by default, leaving only Power, Charge limit and Full charge in the overview. Settings → Show battery level toggles a persisted preference. When enabled, it uses compact 42pt digits with a 24pt percent sign and reclaims all extra space when turned off. The power icon and status text turn green only when actively charging; plugged-in idle and battery power stay neutral. Battery digits remain neutral while charging and only warn for low charge while on battery. All native firmware, authorization and restoration safety behavior is unchanged.
- **Preview 4 denser card and consistent settings:** The three-row overview now uses 3pt spacing, 32pt minimum row height and 13pt vertical padding; the gap to the menu below shrinks from 12pt to 8pt without reducing text size or 29pt action pills. The battery-display and interface-language settings now use equally wide native segmented controls (Hide / Show and 中文 / EN), with the selected value always visible. Both preferences remain persistent and apply immediately. Firmware writes, recovery, authorization and task feedback are unchanged.
- **Preview 9 bidirectional leaf-to-card morph:** Replace the previous shallow fade-only entrance and instant dismissal. Opening begins at the actual menu-bar leaf's screen center: a temporary rounded native-material proxy grows from ~24pt to the full single-card bounds. Closing first fades the controls and contracts the same surface back into the leaf along the reverse geometric path. Text and buttons are never squashed or scaled, the proxy is disposed after transition, and a single interactive card remains. Respect Reduce Motion, permission dialogs, outside-click dismissal, safe quit and Preview 7's in-card disclosures.
- **Preview 8 menu-bar entrance:** Clicking the green menu-bar leaf now reveals the floating card downward from its fixed menu-bar anchor with a gentle ~220ms fade, instead of showing it abruptly. The pointer and content remain steady without scaling text; macOS Reduce Motion bypasses the entrance. Rapid dismiss/reopen invalidates stale completion callbacks. Preview 7 in-card disclosures, the single-card material, and native firmware recovery safeguards remain unchanged.
- **Preview 7 smooth disclosure:** Expanding Charging limit or Settings now coordinates a ~240ms ease-in-out fade/offset, chevron rotation and AppKit floating-panel height animation. The top edge stays anchored to the menu bar while the bottom edge smoothly opens/closes rather than snapping. Initial presentation does not animate a fallback-size correction, duplicate geometry callbacks do not restart a completed target, and Reduce Motion preferences are respected. Authorization and native firmware recovery safety logic are unchanged.
- **Preview 6 single floating card:** Remove AppKit titlebar and outer panel border by using a transparent, key-capable NSPanel. The popover itself is the only rounded material card, with a small top pointer and system shadow. Power, Charge limit, Full charge, Charging limit, Settings and Quit live on one surface, distinguished only by subtle internal separators. Icons and labels share a consistent start and read-only power text stays aligned with pill content. Expanding settings/limit controls and inline errors grow the same card, never a nested tile or overlapping toast. Keep both locales, optional battery display, native authorization and firmware restoration safeguards.
- **Preview 5 precise power status alignment:** Inset the trailing edge of the read-only Power status text by 12pt to line up with the text inside the Charge limit and Full charge capsules instead of the capsule borders. Both locales retain existing card dimensions, green charging state, hit targets, inline feedback and native firmware safety behavior.
- Charging limits are off by default on first launch. The user must click the top-card charging-limit status pill and confirm before firmware is changed.
- On normal Quit, users choose Keep components and quit, Remove components and quit, or Cancel. Both paths restore original firmware on AC or validated battery power. Keep retains launchd registration and waits for the Helper to self-exit after idle, without a password prompt; Remove deletes system-level Helper, LaunchDaemon, scripts, recovery state and logs after administrator authorization. The user then moves the App to Trash.
- While disabled, slider and preset changes are saved locally and do not write to AppleSMC.
- Before the first activation, the helper saves the original bfF0, bfD0, and bfE0 values plus hardware identity in a root-owned snapshot. Later limit changes never overwrite it.
- “Disable charging limit” restores the original activation byte, upper threshold, and resume threshold, and deletes the snapshot only after read-back verification.
- A failed firmware restore or helper cleanup cancels normal quit; the emergency Quit anyway option explicitly warns that full recovery/removal is unverified. A standalone command-line complete uninstaller is retained as a backup.
- The dangerous force-remove-without-restore option is removed. Unplugged complete restore is restricted to exact verified M1 Pro hardware, macOS 15 and matching firmware, with dual battery-source checks, >=30% charge and an inactive original snapshot.
- “One-time full charge” still temporarily disables the current MauLeaf limit and restores that limit afterward. Disabling MauLeaf restores the original pre-activation firmware state.
- The menu bar always displays the green leaf.
- Remove the Intel build matrix, Intel experimental package, and related release steps.
- Preview 4 and earlier releases have no original-state snapshot. Legacy migration can only deactivate the activation flag; historical thresholds cannot be reconstructed, and the app and uninstaller report this explicitly.

**Hardware-validation boundary:** The target M1 Pro has physically validated unplugged bfF0 deactivation, original upper/lower restoration and resumed charging after AC reconnect. The newly integrated full uninstallation transaction still requires a separate on-device end-to-end validation. New limit writes remain restricted to the validated MacBookPro18,1, mBoot-20457.41.3, macOS 15, arm64 profile, with AC power and explicit user confirmation. Restoration of a saved snapshot uses separate authorization and requires the same model, system firmware, and arm64 architecture; it may still be attempted after an OS upgrade. Successful register read-back does not prove that charging physically stops at the selected threshold. The target M1 Pro still requires AC-powered observation of both stop and resume behavior. This remains an experimental hardware-validation preview. Automated tests use a fake SMC transport and never write to physical hardware.
