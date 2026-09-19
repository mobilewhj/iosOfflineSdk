# SPM 接入（0.2.0）

Xcode → File → Add Package Dependencies → `https://github.com/mobilewhj/iosOfflineSdk` → Exact Version `0.2.0` → 将 `OfflineTool` 产品加入 App Target。

Objective-C：`#import <OfflineTool/OfflineTool.h>`。Swift：`import OfflineTool`。无需把业务改成 Swift，也不需要为这个模块新增桥接头。

先移除手动添加的同名 XCFramework 链接/嵌入项，避免重复。业务 Bundle ID 不变。如果有自定义架构裁剪脚本，跳过 OfflineTool。已使用旧 SLC API 的工程，按 MIGRATION-0.2.0.md 更新类名。

SPM ZIP 根目录直接含 OfflineTool.xcframework，Package.swift 使用 GitHub HTTPS 附件地址和精确 SHA-256。原手动安装 ZIP 保留，SDK 二进制没有改变。

按维护者要求，本次在同一 0.2.0 版本补齐 SPM，并更新 v0.2.0 标签指向。若此前解析或缓存过该标签且仍提示找不到 Package.swift，请在 Xcode 的 File → Packages 中 Reset Package Caches 后重新解析。之后的发布使用新的版本标签。

发布脚本自动生成专用 ZIP、校验文件及 Package.swift；先上传附件，再提交清单和版本标签。已对外提供 SPM 的二进制附件不能原地替换，否则校验会失败。
