# 更新记录

## 0.3.1

- 新增 iOS15+ 托管离线生命周期、SQLite事务状态与固定进程/页面版本。
- SDK统一首次准备、静默调度、取消和重试；配置、业务门和身份适配继续由宿主提供。
- ready确认后发准备成功，保留真实处理失败分类；修复查询损坏隔离和必要ZIP输出关闭错误。
- 提供中性Demo/测试资源，正式XCFramework保留第三方许可并使用中性构建路径。
- 历史低层API保留兼容；最低运行系统调整为iOS15。

## 0.2.0 — SPM 发布补充

- 新增 SPM 远程二进制依赖，Objective-C / Swift 宿主均可接入。
- 发布专用 XCFramework ZIP 和 SHA-256，脚本自动生成 Package.swift。
- SDK API、包标识、离线资源格式及安装逻辑不变。

## 0.2.0

统一 SDK 标识为 `com.offline.tool`，更新 Demo 和测试标识。iOS 模块改为 OfflineTool，类名前缀改为 OFT。见 [迁移说明](docs/MIGRATION-0.2.0.md)。
