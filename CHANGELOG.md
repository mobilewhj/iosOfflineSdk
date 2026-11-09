# 更新记录

## 0.3.1

### 2026-11-09 测试阶段同版本刷新

- 按维护者要求保留版本号，刷新 v0.3.1 源码、二进制和 SPM checksum。
- 离线页面统一 loadFileURL，绑定接口改为 pageBindingForConfiguration:error:，移除自定义协议与逐资源回源。
- 文件网络访问设置在创建 WKWebView 前必需开启并确认，实际加载再次核对配置；Framework 声明 OFTFileUniversalAccessRequired。
- 对齐 Android 的有效端口、既有 active 最低版本资格、未知扩展名及下载 URL fragment 边界；下载校验、安装、更新、取消及 H5 业务请求职责保持。
- 保留原版本目录读取和旧页面生命周期。旧 0.3.1 调用方须适配新页面接口并重新解析依赖，详见 docs/SPM.md。

### 首次发布

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
