# 验证范围

0.3.1 的最低部署设置为 iOS 15。原生单元测试、源码 Demo 构建、最终二进制消费者和接入方业务验收分别记录，不能相互替代。历史 0.2.0 的记录见 VALIDATION-0.2.0.md，不作为当前版本的验证成绩。

SDK 回归覆盖真实 SQLite 事务与损坏隔离、生命周期、首装/静默调度、取消重入、重试额度、安装统计边界、ZIP/文件失败和 WebKit 资源适配。具体场景与原生命令见 VALIDATION-LIFECYCLE.md。完整回归包含历史低层安装器的 120 秒总请求时限测试；托管下载使用宿主 NSURLSessionConfiguration 或平台默认时限，不继承该人工时限。

正式制品应重新构建 device/simulator 切片，核对版本、最低系统、UUID、ZIP checksum 和逐文件摘要。独立消费者只链接最终 XCFramework；远端 SPM 消费另核对 exact 版本与解析 commit。原生 macOS XCTest 不证明 iOS 最低系统运行；构建成功不等于已执行应用。

接入方仍需在自己的隔离环境验证首装隐私、真实配置和 ZIP/SHA 来源、高版本 ready 后真实冷进程启用、取消/重入、退出和账户切换、Bridge、断网本地资源字节及联网回源、资源缓存、Reporter HTTP/业务响应及后台收件。还需核对实际运行模块身份、iOS15 和完整业务页面；页面 Network Error、空白或其他业务异常必须保留为未定位，不能因 SDK 发布而排除 SDK。

自定义 scheme 改变网页 origin。Cookie、localStorage、身份注入、CORS、导航和宿主隐私撤回接线需要单独验收，不放宽网关或浏览器安全策略。物理设备、签名构建、模拟器与测试替身证据应分别保存，公开 SDK 不包含接入方业务证据或账号。
