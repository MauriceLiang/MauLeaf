# GitHub Actions 自动构建与发布

## 自动发布（默认流程）

所有开发先在功能分支完成，并通过 Pull Request 合并到 `main`。合并产生的 `push main` 会自动执行：

1. macOS 15 运行完整测试套件；测试失败时不创建标签、不构建、不发布。
2. 读取仓库根目录的 `VERSION`，并查询已有的 `v<VERSION>-preview.N` 标签，自动递增预览序号。
3. 创建指向本次 main 合并提交的预览标签。
4. 分别在 Apple Silicon（`macos-15`）和 Intel（`macos-15-intel`）runner 构建 DMG。
5. 校验双语发布说明、两个架构的 DMG，生成 `SHA256SUMS.txt`。
6. 创建 GitHub Pre-release 并上传两个 DMG 与校验和。

例如当前 `VERSION` 为 `0.8.0`，仓库已有 `v0.8.0-preview.1` 和 `v0.8.0-preview.2`，下一次 main 合并成功后自动发布 `v0.8.0-preview.3`。

**后续日常开发不需要手动创建 tag，也不需要手动启动发布 Action。** 只要 PR 合并到 main，测试通过后就会自动打包发布。若仅希望运行测试，可在 PR 阶段检查结果；PR 不会生成 Release。

## 版本号

- `VERSION`：当前开发版本的三段版本号，例如 `0.8.0`。
- Preview 标签：`v<VERSION>-preview.N`，N 根据远端已有标签自动递增。
- 正式版标签：`vX.Y.Z`，推送标签后自动测试、构建并发布正式 Release。
- 应用的 `CFBundleShortVersionString` 使用三段版本号；预览序号保留在 DMG 文件名和 Release 标签中。

准备进入下一个三段版本时，先在功能 PR 中更新 `VERSION` 和对应发布说明模板，再合并到 main。

## 手动恢复与特殊发布

进入 GitHub → Actions → **Build & Release** → **Run workflow**：

- `release_tag`：重新从已存在的标签构建并发布。适用于标签已存在但 Release 尚未创建的恢复场景；如果 Release 已存在，工作流会拒绝覆盖。
- `preview_tag`：从 main 创建一个全新的预览标签并发布。只能使用不存在的 `vX.Y.Z-preview.N` 标签。
- 两个输入不能同时填写；正常开发合并不需要手动填写。

## 发布产物

- Apple Silicon：`MauLeaf-<版本>-macos-arm64.dmg`，包含原生 AppleSMC helper。
- Intel：`MauLeaf-<版本>-macos-x86_64-EXPERIMENTAL.dmg`，只读实验版，不包含原生控制 helper。
- `SHA256SUMS.txt`：两个 DMG 的 SHA-256 校验和。

发布流程不再打包 batt 二进制、第三方固件资源或第三方控制源码归档。
