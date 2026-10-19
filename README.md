# iOS 离线包 SDK

当前源码提供 iOS 15+ 原生托管离线管理器和 WKURLSchemeHandler，公开入口可由 Objective-C / Swift 使用。SDK 管理首次准备、默认持久存储、条件驱动静默检查、单表生命周期、内存重试额度、冷启动启用和固定页面资源。App 提供配置 provider、隐私/前后台事实、业务 UI、导航和登录适配。

当前版本为 **0.3.1**，最低 iOS 15，通过 GitHub Releases 的 XCFramework 与 Swift Package Manager 分发。最短接入与平台边界见 [托管接入](docs/MANAGED-INTEGRATION.md)。发布包、SPM ZIP 和 Package.swift 必须对应同一版本与最终校验值；历史本地候选不属于正式发布。

## 三端命名对照

| 标识用途 | Android | 鸿蒙 | iOS |
| --- | --- | --- | --- |
| SDK 代码包名 / 导入名称 | `com.offline.tool` | `com.offline.tool`（OHPM 包名） | `OfflineTool`（Framework 模块名） |
| SDK Bundle Identifier | 不适用 | 不适用 | `com.offline.tool` |
| Demo 应用标识 | `com.offline.tool.sample` | `com.offline.tool.sample` | `com.offline.tool.managed.sample` |
| iOS 测试标识 | — | — | `com.offline.tool.tests` |

iOS 没有与 Java/Kotlin 包名完全相同的概念，Bundle Identifier 是库或应用的标识，代码仍通过 `#import <OfflineTool/OfflineTool.h>` 导入。SDK 错误域为 `com.offline.tool`，内部队列使用该前缀；这些标识不是网络地址。它们沿用独立 Android SDK 的命名，不包含原业务公司的域名，也不与个人 GitHub 账号绑定。

## 工程与运行

打开 `OfflineTool.xcodeproj`：

| Scheme | 用途 |
| --- | --- |
| `OfflineTool` | SDK Framework；Test 运行独立单元测试 |
| `OfflineToolDemo` | 独立 iOS 示例，不包含业务素材或真实账号 |

Demo 由应用入口持有同一个 `OFTManagedOfflineSDK`，启动页只显示 SDK 真实进度并消费本次结果。每个新页面在创建 WebView 前注册绑定，通过 `loadPage` 决定线上或离线；普通 reload 保持该页面版本。后续静默更新在离开启动页后仍由 SDK 驱动。

测试服务和启动参数见 [托管接入](docs/MANAGED-INTEGRATION.md)。合成 A/B ZIP、回源、实际 XHR POST/预检/自定义头、现有形状 iframe Bridge 使用独立回环服务。历史 `Demo/Resources/demo.zip` 与原低层 API 测试保留。

中文进度 UI 位于 `Demo/DemoStartupPreparationViewController.h/.m`，不编入 SDK。未知长度显示不确定进度，阶段比例最多 99%，ready 确认写入后才显示 100%；普通失败结束离线等待并保留线上路径，取消或条件不足允许重新进入。

真机运行独立 Demo 需要可用签名；当前模拟器结果不替代最低 iOS15 或业务 App 验收。

## 0.3.1 远程依赖

Objective-C 和 Swift 项目均可使用，不需要将业务代码改写成 Swift。

1. Xcode → File → Add Package Dependencies，输入 `https://github.com/mobilewhj/iosOfflineSdk`。
2. 选择 Exact Version `0.3.1`，将产品 `OfflineTool` 添加到业务 App Target。
3. 移除手动添加的旧 `OfflineTool.xcframework` / `SLCOfflineSDK.xcframework` 链接及嵌入项，避免重复引用。保留业务 App 自己的 Bundle ID。
4. Objective-C 使用 `#import <OfflineTool/OfflineTool.h>`；Swift 使用 `import OfflineTool`。无需为这个模块增加桥接头。
5. Xcode 自动下载并校验二进制。若工程有自定义 Framework 架构裁剪脚本，请跳过 `OfflineTool`；已有 Swift 标准库嵌入配置继续保留。

SPM 管理库的下载和依赖关系；最终以业务 App Target 编译、Archive 和运行结果确认嵌入是否正确。最低 iOS 15。历史 0.2.0 的低层接入与改名说明单独保留，不能用其结果代替 0.3.1 的集成验证。

下方手动 XCFramework 接入为可选方式，与 SPM 二选一。

## 旧低层 API（保留兼容）

Release 分发形式为 `OfflineTool.xcframework`，包含真机 arm64 和模拟器 arm64/x86_64。加入宿主 Target 的 Frameworks, Libraries, and Embedded Content，选择 **Embed & Sign**。仅引用二进制即可，不需要 SDK 源码或 Demo。下载渠道配置与业务请求不属于 SDK。

```objc
#import <OfflineTool/OfflineTool.h>

OFTPackageInstaller *installer = [[OFTPackageInstaller alloc] initWithRootDirectory:rootURL];
OFTPackageRecord *candidate = [[OFTPackageRecord alloc] initWithVersion:100000 sha256:trustedSHA256];
NSProgress *job = [installer installRecord:candidate fromURL:downloadURL
    progress:^(NSString *stage, int64_t done, int64_t total) {
        // 主线程；total == -1 表示未知长度，各阶段独立计量。
    } completion:^(OFTPackageRecord *record, NSURL *directory, NSError *error) {
        // 安装成功仅表示完整目录已发布。
        // 宿主可靠保存当前版本记录后，再让新页面绑定该目录。
    }];
// [job cancel];
```

| API | 契约 |
| --- | --- |
| `installRecord:fromURL:progress:completion:` | 下载、校验、解压、发布；不保存业务记录 |
| `installRecord:localArchive:progress:completion:` | 复制并校验本地 ZIP；输入包应位于 SDK 工作根目录之外 |
| `clearOldVersionsKeeping:completion:` | 冷启动且无绑定页面时清理；缺失/空的保留入口拒绝清理 |
| `discardUnboundVersion:completion:` | 宿主确认未交付页面后，移除指定版本残留 |
| `OFTOfflineResourceResolver` | 原 HTTP(S) URL → 固定目录内的本地资源描述 |
| `OFTOfflineSchemeHandler` | 可选 WKWebView 自定义协议适配；不拦截 HTTP(S)，不回源或代理业务接口 |

根目录由宿主提供，建议位于 Application Support，安装器排除备份。正式目录为 `<root>/<version>/index.html`；接受 ZIP 根目录或 `dist/index.html`，发布时归一化。SDK 只校验版本 >= 10000；业务可执行更高下限。`PackageRecord` 只有 version/sha256。

同一 root 复用一个安装器，安装与清理串行。已有版本不覆盖；升级/降级/同版冲突判断及激活记录由宿主处理。每个页面固定绑定版本；旧目录只能在没有页面使用时清理。

下载支持 HTTP(S) 的完整 200 响应，拒绝跨协议重定向，120 秒总时限；生产 URL 应由可信 HTTPS 配置提供。ZIP 和单文件各限 64 MiB，总解压 256 MiB，最多 10000 条目；校验整包 SHA-256 和条目 CRC，拒绝越界路径、符号链接、路径别名、重复/冲突和不完整归档。SHA-256 必须来自可信配置；它本身不证明发布者身份。

## 旧低层 WKWebView 接入（默认无回源）

```objc
OFTOfflineSchemeHandler *handler = [[OFTOfflineSchemeHandler alloc]
    initWithDirectory:installedDirectory
    baseURL:[NSURL URLWithString:@"https://example.com/app/"]
    scheme:@"app-offline"];
WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
[configuration setURLSchemeHandler:handler forURLScheme:handler.scheme];
WKWebView *webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
NSURL *entry = [handler offlineURLForURL:[NSURL URLWithString:@"https://example.com/app/index.html#/home"]];
if (entry) [webView loadRequest:[NSURLRequest requestWithURL:entry]];
```

创建/使用 WebKit 对象遵循主线程规则。每个 WebView 使用自己的 handler，生命周期内不切换目录。仅允许匹配的 host、port、路径前缀、GET 和无 Range 的静态文件；query/hash 原样保留但不参与文件定位。找不到资源则失败，不进行隐式网络回源；响应不添加 CORS 通配头。后台读取文件，响应回主线程，WebKit 取消后停止回调。

自定义协议会改变网页 origin。API HTTPS 地址、身份注入、Cookie/存储迁移、CORS 和导航白名单由宿主与 H5 共同处理。**发布此 SDK 不等于任意已有 H5 可以零修改离线运行。** 详见 [接入边界](docs/INTEGRATION.md)。

## 本地构建与正式制品

需要完整 Xcode。以下命令不会发布到远端：

```sh
# 若系统默认仍指向 Command Line Tools，先按实际安装位置设置：
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project OfflineTool.xcodeproj -scheme OfflineTool \
  -sdk macosx -destination 'platform=macOS' -derivedDataPath build/tests \
  CODE_SIGNING_ALLOWED=NO test
xcodebuild -project OfflineTool.xcodeproj -scheme OfflineToolDemo \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/demo \
  CODE_SIGNING_ALLOWED=NO build
bash scripts/build_release.sh
```

`build_release.sh` 从当前 VERSION 归档 device/simulator、创建 XCFramework、生成手动安装 ZIP 和根目录直接含 XCFramework 的 SPM ZIP，再由 `generate_package.py` 对确切 SPM ZIP 计算 checksum 并更新 Package.swift。已有工作目录或制品时脚本拒绝覆盖；需要重试时使用新的 `OFT_RELEASE_WORK_DIRECTORY` / `OFT_RELEASE_OUTPUT_ROOT`。Release 编译映射源路径并检查最终框架内没有本机私有绝对路径或候选元数据。新发布使用新版本/tag，不移动旧 tag 或替换旧附件。详见 [SPM 接入与发布](docs/SPM.md)。

`generate_consumer.py --framework <最终XCFramework> --output <新目录>` 创建只链接指定二进制的独立 Objective-C 消费工程。`create_local_candidate.py --evidence <私有验证目录>` 仍可生成不可覆盖的 `dist/OfflineTool-managed-<identity>`；候选营销版本为 0.0.0，包含 OFTLocalCandidateIdentity，不能作为正式 0.3.1 制品发布。私有验证、构建输出及本地签名文件不属于公开提交清单。

`generate_project.py` 确定性生成工程；修改工程配置时同步脚本。`generate_demo.py` 和 `generate_fixtures.py` 分别生成合成示例包和异常测试样本。SDK 内含固定版本 ZIPFoundation 0.9.20，无需联网解析依赖。

当前验证范围见 [验证记录](docs/VALIDATION.md)。最低系统真机、业务 H5 和实际网关联调不由模拟器测试替代。

## License

Apache-2.0。ZIPFoundation 与 Demo 中的 WebViewJavascriptBridge 使用 MIT 许可，详见 `LICENSE`、`THIRD_PARTY_NOTICES.md`、`Vendor/ZIPFoundation/LICENSE` 和 `Demo/Bridge/LICENSE.txt`。

[0.2.0 migration / 改名接入说明](docs/MIGRATION-0.2.0.md)
