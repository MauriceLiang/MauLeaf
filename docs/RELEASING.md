# GitHub Actions 自动发布

推送 `main`、PR 或手动运行 Actions：仅测试。推送 `vX.Y.Z` 标签：创建正式 Release；推送 `vX.Y.Z-preview.N` 标签：创建 GitHub Pre-release。两者均先测试，再分别在 macos-15 与 macos-15-intel 上构建 ARM64 / Intel DMG。

- Apple Silicon（arm64）：主应用和随包构建的 MauLeaf 原生 AppleSMC 特权服务；不包含第三方充电控制程序或固件资源。
- Intel（x86_64）：只读实验版，不包含原生特权服务，不提供充电控制。开发者没有 Intel 实机，未进行 Intel 实机安装或运行测试。
- CI 打包脚本：`Scripts/ci/package-macos.sh`。
- Release 附件：ARM64 DMG、Intel 实验版 DMG、`SHA256SUMS.txt`。不再打包第三方控制程序源码归档。
- Preview DMG 文件名保留完整 preview 后缀；应用 Bundle 版本仍使用三段数字版本。
- DMG 采用 ad-hoc 签名，未经 Apple notarization。

发布前将更新日志与对应版本双语说明合并至 `main`，确认测试通过；检查标签不存在。正式版使用 `vX.Y.Z`，预览版使用 `vX.Y.Z-preview.N`，例如 `v0.8.0-preview.1`。不要重写已发布标签。

## 一键创建并发布 Preview

1. GitHub → Actions → **Build & Release** → **Run workflow**。
2. Branch 选择 `main`。
3. `preview_tag` 输入 `v0.8.0-preview.1`；`release_tag` 留空。
4. 工作流先执行测试，再构建双架构 DMG；构建成功后创建 tag 并发布 GitHub Pre-release。
5. 工作流拒绝覆盖已存在的 tag 或 Release。

## 已有标签发布失败的恢复

如果已有标签的测试和构建成功，但 Release 阶段失败：

1. Actions → Build & Release → Run workflow。
2. 选择 `main`，在 `release_tag` 输入已经存在的标签。
3. 留空 `preview_tag`。工作流会检出该标签并重新构建、发布；若 Release 已存在则拒绝覆盖。
