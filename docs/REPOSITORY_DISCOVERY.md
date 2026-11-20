# MauLeaf GitHub 搜索与仓库展示设置

> 此文件记录需要在仓库 **About → Edit** 中手动保存的元数据。README、截图和测试可通过 PR 更新；当前连接不支持更改 GitHub 仓库的 Description、Website 或 Topics。**文件存在不代表 About 设置已生效。**

## 建议的 GitHub Description

```text
Native macOS battery charge limiter for MacBook (Apple Silicon). Charging limits, one-time full charge, and a lightweight menu bar app. 原生 Mac 电池充电管理工具。
```

用英文功能关键词开头，随后保留中文用途；描述产品方向，不夸大实际支持范围。当前新的 AppleSMC 固件写入仅限一组经过验证的 M1 Pro / macOS 15 硬件配置，应在 README 顶部明显写明。

## 建议 GitHub Topics（10 个）

```text
macos
apple-silicon
macbook
battery-health
battery-charge-limit
charge-limit
menu-bar-app
swift
swiftui
smc
```

Topics 描述软件用途和技术实现，不代表对所有 Apple Silicon Mac 都提供充电写入支持。

## Website（可选）

```text
https://github.com/MauriceLiang/MauLeaf/releases/latest
```

## 保存操作

1. 打开 [MauLeaf 仓库首页](https://github.com/MauriceLiang/MauLeaf)，找到右侧 **About** 区域。
2. 点击齿轮图标 **Edit**，粘贴 Description。
3. 在 Topics 逐个录入上述 10 个关键词并保存。
4. 如需 Website，将其设置为最新正式版下载入口。
5. 刷新仓库首页，核对搜索摘要、Topics、首屏截图和 README 下载/兼容性链接。

## 后续推广原则

- 保持 Release、README、使用截图同步；不要将尚未硬件验证的功能写成已支持。
- 优先发布真实体验和复现材料（兼容性、诊断与解决步骤），不要购买 Star、批量刷赞或使用垃圾关键词。
- 这些设置提升仓库描述的可发现性与理解效率，但无法保证 GitHub 搜索排名或推荐数量。
