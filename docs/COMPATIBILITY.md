# MauLeaf 兼容性 / Compatibility

[返回中文 README](../README.md) · [English README](../README.en.md) · [反馈问题 / Report an issue](https://github.com/MauriceLiang/MauLeaf/issues/new?template=bug_report.md)

## 目前可执行新限充的已验证环境

| 检查项 / Check | 必须满足 / Required |
| --- | --- |
| 机型 / Model | **MacBookPro18,1** (Apple M1 Pro) |
| macOS | **macOS 15.x** |
| 固件 / Firmware | **mBoot-20457.41.3** |
| 架构 / Architecture | **arm64** |
| 电源 / Power | 必须连接 AC 才能执行新的限充写入 / AC power required for new limit writes |
| 用户授权 / Consent | 首次主动启用，明确授权特权 Helper；不在启动时自动启用 / Explicit opt-in; no write on launch |

**未列出的机型、系统和固件，并不等同于已经证实不兼容；目前只是未经完整验证，因此默认不允许新的固件写入。** macOS 26/27 和 Intel 版本不受此原生控制路径支持。部分设备可能能够查看电量，但不保证限充可用。

**Unlisted systems are not necessarily proven incompatible; they have not been validated for safe firmware writes.** macOS 26/27 and Intel cannot activate a new native firmware limit using the current supported profile. Battery viewing may work on additional configurations.

## 重要限制 / Important limitations

- **不是跨所有 Apple Silicon Mac 的通用控制器。** 当前明确验证范围只有上表中的一组硬件配置。
- **寄存器验证不等于真实充电曲线验证。** 真实停止充电与恢复充电的电量百分比仍需要目标机器长周期测试。
- **系统升级有风险。** 不要因为正在运行 macOS 26/27 就尝试绕过限制以写入固件；已有快照的恢复使用独立身份校验，不能通过删除快照来“修复”异常。
- **下载包使用 ad-hoc 签名，未完成 Apple Developer ID 签名和公证。** 可能需要在「系统设置 → 隐私与安全性」处理打开提示。
- **No administrator prompt on launch.** The first explicit enable may install the privileged Helper after confirmation. Do not manually remove root-owned recovery files or bypass SMC safeguards.

## 无法使用？/ Not working?

从仓库的最新 main 下载并运行**只读、不需要 sudo** 的诊断脚本：

```bash
curl -fL https://raw.githubusercontent.com/MauriceLiang/MauLeaf/main/Scripts/diagnose-mauleaf.sh -o MauLeaf-diagnose.sh
bash ./MauLeaf-diagnose.sh
```

请审阅输出后将报告附在 [Issue 模板](https://github.com/MauriceLiang/MauLeaf/issues/new?template=bug_report.md)。该脚本不修改硬件、系统服务或自动上传数据。

Download and run the **read-only, no-sudo** diagnostic above, review its output, and attach it to the linked GitHub Issue template.
