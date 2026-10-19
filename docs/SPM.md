# SPM 接入与发布（0.3.1）

Xcode → File → Add Package Dependencies → `https://github.com/mobilewhj/iosOfflineSdk` → Exact Version `0.3.1` → 将 `OfflineTool` 产品加入 App Target。最低运行系统为 iOS 15。

Objective-C：`#import <OfflineTool/OfflineTool.h>`。Swift：`import OfflineTool`。无需把宿主业务改成 Swift，也不需要为这个模块新增桥接头。

先移除手动添加的同名 XCFramework 链接/嵌入项，避免重复。宿主 Bundle ID 不变。如果有自定义架构裁剪脚本，跳过 OfflineTool。历史 SLC API 改名参见 MIGRATION-0.2.0.md；0.3.1 的托管生命周期参见 MANAGED-INTEGRATION.md。

SPM ZIP 根目录直接含 OfflineTool.xcframework，Package.swift 使用 GitHub HTTPS 附件地址和该 ZIP 的精确 SHA-256。手动安装 ZIP 另外包含公开文档和许可。两种方式二选一；最终检查宿主 Target 的解析版本、链接及嵌入二进制。

## 维护者构建顺序

1. 更新 VERSION 与必要公开文档，运行 generate_project.py。Release 使用中性源路径映射，所有正式切片必须为同一版本和 iOS15 最低系统。
2. 保存完整公开输入与实际编译输入的逐文件 SHA，再运行 build_release.sh。脚本从源码重新归档真机 arm64 和模拟器 arm64/x86_64，不复用本地候选。
3. 脚本创建 `dist/OfflineTool-0.3.1.xcframework.zip` 后，generate_package.py 使用 `swift package compute-checksum` 生成 Package.swift 与 ZIP.sha256。checksum 必须来自最终 ZIP；计算后的 ZIP 不得再修改。Package.swift 不参与框架编译，其校验值更新应单独记录。
4. 检查最终公开源码、第三方许可、归档条目、版本/最低系统、所有切片 UUID、私有路径及本地候选标记，运行原生回归和独立二进制消费者。显式核对提交清单，排除私有 verification、缓存、签名及旧制品。
5. 确认目标版本/tag/Release 未占用后，提交完整公开实现与最终 Package.swift，并将新 tag 绑定该提交；向对应新 Release 上传确切 ZIP 和校验文件。不得移动已发布 tag 或替换已发布附件。
6. 发布后匿名下载实际附件与 tag 源码，比对 checksum、逐文件身份和 tag/commit。使用独立解析目录从远端 Exact Version 解析并构建，再核对宿主最终嵌入身份；本地源码或缓存命中不能代替这一步。

已有工作或输出时脚本拒绝覆盖。保留失败证据，使用新的 `OFT_RELEASE_WORK_DIRECTORY` 和 `OFT_RELEASE_OUTPUT_ROOT` 后重试；generate_package.py 的 `--archive` 可显式指定新 ZIP。正式发布之外的本地候选工具保留 0.0.0 与独立 identity，不能重命名后上传为正式版本。

历史 0.2.0 曾补齐 SPM 并调整该版本 tag 的指向；该历史说明不构成今后移动 tag 或覆盖附件的规则。旧缓存或不可枚举的远端历史不由本次构建自动清理。
