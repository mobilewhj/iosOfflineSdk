# ZIPFoundation 源码来源

- 上游：https://github.com/weichsel/ZIPFoundation
- 固定版本：`0.9.20`
- 下载：https://codeload.github.com/weichsel/ZIPFoundation/tar.gz/refs/tags/0.9.20
- tar.gz SHA-256：`3ddad93f81480d141f15d9b8bdc276a21c5242446c179672c2e787799a423b5e`
- 许可证：同目录 `LICENSE`，MIT。

`Sources/` 保留该版本 `Sources/ZIPFoundation/` 内容，不修改上游源文件。它与 SDK 的 Swift 解压适配层在同一 Framework target 编译，避免业务工程额外引入依赖管理工具；`PrivacyInfo.xcprivacy` 随 framework 复制。SDK 承诺的对外接口是 `SLCOfflineSDK.h` 中的 Objective-C API；上游 Swift 类型不是业务接入契约。

外层 `SLCArchiveReader.swift` 执行路径、条目数量、实际输出大小、CRC、取消及入口检查；不能用上游的整包解压便利方法替换这些检查。
