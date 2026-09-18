# 验证记录

当前代码最低部署设置 iOS 12.0，使用本机 Xcode 26.6 / iOS 26.5 Simulator 验证。实际最低系统真机未验收。

- 独立 macOS XCTest：19 项通过，包含 HTTP 完整响应、未知长度、中断、异常 ZIP、版本保护、目录清理和 6 项 WebKit handler 测试。
- Handler 测试包含保留协议拒绝、URL 范围、query/hash、内容与 MIME、缺失/外域/POST/Range 拒绝、读取过程中取消和响应回调内取消。
- 独立 iOS Demo Simulator 构建通过，不依赖业务工程、账号或远程配置。
- 独立 Demo 在 iPhone 17 Pro / iOS 26.5 上运行成功：本地 HTML/JS/CSS/JSON 加载、原生示例数据注入均通过，报告 ready=true、injected=true，origin 为 offline-demo://demo.example。
- Release 真机及模拟器归档通过，XCFramework 包含 ios-arm64 和 ios-arm64_x86_64-simulator，并附有 Swift module interfaces、隐私清单及 ZIPFoundation 许可。
- 业务工程的 UI Demo 已只引用该 XCFramework 构建通过；业务配置测试仍在宿主，1 项通过。

这些验证不能代替实际业务 H5 的身份、CORS、登录和支付联调。

发布产物复核：将独立 Demo 内的 Framework 换为最终 Release XCFramework 的模拟器切片，再次安装运行，报告 ready=true、injected=true。本次验证实际执行了 Release 二进制，不仅是源码 Demo 编译。业务主 App 无签名真机目标构建通过，产物中存在 SDK arm64 二进制，主可执行文件包含对应 @rpath 加载项；旧架构裁剪脚本已跳过该 XCFramework。

2026-09-18：独立 Demo 补齐启动进度 UI，中文状态、渐变进度条、扫光动画和失败重试沿用此前业务 UI 的样式。Simulator 构建通过，实际查看下载 65% 与安装完成 100% 显示；点击“预览启动效果”进入准备阶段，预览结束展示失败提示，点击“重试”重新进入准备阶段。真实内置包安装再次通过，报告 ready=true、injected=true。UI 代码仅属于 Demo，不改变 SDK 二进制与业务工程引用的 0.1.0 发布包。
