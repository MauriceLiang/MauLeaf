# 本地构建与 GitHub Release

1. 在 `build.command` 中递增 `APP_VERSION`、`APP_BUILD`，同步更新 `CHANGELOG.md` 和 `docs/releases/v<版本>.md`。
2. 在 Apple Silicon Mac 上执行 `./tests/run.sh` 和 `./build.command`。发布使用本地生成的 `build/MauLeaf-<版本>.dmg`。
3. 检查应用版本、图标和许可证，执行 `codesign --verify --deep --strict` 及 `hdiutil verify`，生成 `SHA256SUMS.txt`。
4. 提交、推送源代码，再创建并推送对应版本标签。保留已有远端历史，不强制覆盖标签或分支。
5. 使用 GitHub CLI 发布 Release，更新说明使用对应 Markdown 文件；上传本地 DMG、校验文件和固定版本 batt 源码归档。不要只上传二进制而省略更新说明。
6. 发布后检查标签提交、Release 正文、资产大小与 SHA-256，确保上传资产与本地构建文件一致。

`build/` 和本地缓存的 `Vendor/batt` 不提交进 Git；安装包通过 GitHub Releases 分发。自动生成的源码归档由版本标签提供。
