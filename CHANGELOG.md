# 更新记录

## 0.2.0 — SPM 发布补充

- 新增 SPM 远程二进制依赖，Objective-C / Swift 宿主均可接入。
- 发布专用 XCFramework ZIP 和 SHA-256，脚本自动生成 Package.swift。
- SDK API、包标识、离线资源格式及安装逻辑不变。

## 0.2.0

统一 SDK 标识为 `com.offline.tool`，更新 Demo 和测试标识。iOS 模块改为 OfflineTool，类名前缀改为 OFT。见 [迁移说明](docs/MIGRATION-0.2.0.md)。
