# GitHub Actions 自动发布

推送 `main`、PR 或手动运行 Actions：仅测试。推送 `vX.Y.Z` 标签：先测试，再分别在 macos-15 与 macos-15-intel 上构建 ARM64 / Intel DMG，最后自动创建 Release。

- ARM64 正式版：主应用、卸载器、固定版本 batt v0.8.0。
- Intel 实验版：**仅电池信息只读预览**，不打包 batt，不提供系统服务卸载器，也不允许执行充电控制。开发者**没有 Intel 实机，因此从未进行 Intel 实机安装或运行测试**，包括软件能否启动及稳定运行在内的实际使用情况未知。
- CI 专用打包脚本：`Scripts/ci/package-macos.sh`，CI 不依赖本地 `build.command`。
- Release：两个 DMG、`SHA256SUMS.txt`、batt v0.8.0 对应 GPL-2.0 源码；双语说明取自 `docs/releases/vX.Y.Z.md`。
- DMG 采用 ad-hoc 签名，未经 notarization。
- Intel 免责声明必须同时放在 README 中英文版、发布说明中英文版、DMG 内的 README；不能暗示 CI 编译成功就说明 Intel 可用。提供按现状（AS IS）、风险自担及法定权利保留说明。

发布前将更新日志与对应版本双语说明合并至 `main`，确认测试通过；再检查标签不重复，执行 `git tag -a v0.7.5 -m "MauLeaf v0.7.5"`、`git push origin v0.7.5`（实际版本按需替换）。不要重写已发布标签。


## 已有标签发布失败的恢复

如果 `v0.7.5` 一类已有版本标签的测试与安装包已成功构建，但 Release 阶段失败，请先修复并合并工作流，不要删除或强制重设标签。

1. GitHub → Actions → **Build & Release** → **Run workflow**。
2. 选择 `main`，在 `release_tag` 输入已存在的标签（例如 `v0.7.5`）。
3. 手动启动：使用最新工作流定义，从该标签检出源码进行测试、双架构打包和发布。
4. 发布前检查已有 Release；如果已经存在则拒绝覆盖。输入留空则只运行测试。
5. 原先 `tar -tzf ... | grep -q 'LICENSE$'` 在 `pipefail` 下可能因 `grep -q` 提前关闭管道导致 `tar: stdout: write error`；现先完整输出到临时文件再匹配。
