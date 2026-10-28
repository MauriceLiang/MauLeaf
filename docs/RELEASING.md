# GitHub Actions 自动发布

推送 `main`、PR 或手动运行 Actions：仅测试。推送 `vX.Y.Z` 标签：先测试，再分别在 macos-15 与 macos-15-intel 上构建 ARM64 / Intel DMG，最后自动创建 Release。

- ARM64 正式版：主应用、卸载器、固定版本 batt v0.8.0。
- Intel 实验版：**仅电池信息只读预览**，不打包 batt，不提供系统服务卸载器，也不允许执行充电控制。Intel 充电功能未经验证。
- CI 专用打包脚本：`Scripts/ci/package-macos.sh`，不依赖已删除的 `build.command`。
- Release：两个 DMG、`SHA256SUMS.txt`、batt v0.8.0 对应 GPL-2.0 源码；双语说明取自 `docs/releases/vX.Y.Z.md`。
- DMG 采用 ad-hoc 签名，未经 notarization。

发布前将更新日志与对应版本双语说明合并至 `main`，确认测试通过；再检查标签不重复，执行 `git tag -a v0.7.5 -m "MauLeaf v0.7.5"`、`git push origin v0.7.5`（实际版本按需替换）。不要重写已发布标签。
