# iOS 离线包 SDK

独立 iOS 离线 ZIP 安装与 WKWebView 本地资源 SDK，Objective-C API，可供 Objective-C / Swift 宿主调用。最低部署 iOS 12.0。与 Android / 鸿蒙保持核心职责一致：下载、校验、安装、清理和固定版本资源映射；业务配置、版本选择、当前记录持久化、登录和启动 UI 由宿主负责。

## 三端命名对照

| 标识用途 | Android | 鸿蒙 | iOS |
| --- | --- | --- | --- |
| SDK 代码包名 / 导入名称 | `com.offline.tool` | `com.offline.tool`（OHPM 包名） | `OfflineTool`（Framework 模块名） |
| SDK Bundle Identifier | 不适用 | 不适用 | `com.offline.tool` |
| Demo 应用标识 | `com.offline.tool.sample` | `com.offline.tool.sample` | `com.offline.tool.sample` |
| iOS 测试标识 | — | — | `com.offline.tool.tests` |

iOS 没有与 Java/Kotlin 包名完全相同的概念，Bundle Identifier 是库或应用的标识，代码仍通过 `#import <OfflineTool/OfflineTool.h>` 导入。SDK 错误域为 `com.offline.tool`，内部队列使用该前缀；这些标识不是网络地址。它们沿用独立 Android SDK 的命名，不包含原业务公司的域名，也不与个人 GitHub 账号绑定。

## 工程与运行

打开 `OfflineTool.xcodeproj`：

| Scheme | 用途 |
| --- | --- |
| `OfflineTool` | SDK Framework；Test 运行独立单元测试 |
| `OfflineToolDemo` | 独立 iOS 示例，不包含业务素材或真实账号 |

Demo 选择 iPhone 模拟器运行，点击安装按钮即可完成：内置合成 ZIP → SHA-256 校验/安装 → 自定义协议加载 HTML、CSS、JS → 读取原生虚构数据 → fetch 本地 JSON。整个过程不请求外网。`--smoke-test` 启动参数自动执行，结果保存在 Demo Documents 的 `smoke-result.json`。

### 启动进度与文本

Demo 底部提供与业务工程已对齐的中文状态和进度样式：橙色渐变、3 pt 进度条、准备/初始化阶段的 1.2 秒扫光、解压百分比及失败重试。UI 示例放在 `Demo/DemoStartupPreparationViewController.h/.m`，不编入 SDK Framework；宿主可以参考或复制，不依赖业务图片。

- **安装内置测试包**：执行真实 SDK 安装并展示实际回调，成功后显示网页和“启动配置准备完成”。本地包不经过网络下载，复制阶段显示准备文本；小包处理很快，不人为延长安装时间。
- **预览启动效果**：只演示 UI，依次展示“正在准备启动配置…”、“正在下载资源包…”、“正在解压资源包…”、“正在完成初始化…”、“启动配置准备完成”，随后展示失败重试。预览百分比不会用于真实安装，重试在预览内重新播放。
- 真正使用 `installRecord:fromURL:` 下载时，宿主将 `download` 映射为“正在下载资源包…”并使用 SDK 字节数计算百分比；摘要校验保留上阶段提示，解压最多显示 99%，宿主初始化完成后才显示完成。

可在 Xcode 的 Scheme → Run → Arguments 添加 `--preview-startup animation` 自动播放；`download`、`extract`、`finishing`、`complete`、`failed`、`no-network` 可固定查看某个状态。开始真实安装或重新预览会取消旧预览的后续 UI 更新。

真机运行 Demo 需要在 Xcode 配置自己的签名团队。业务 App 的第三方 SDK 是否支持模拟器，不影响这个独立 Demo。

## 使用 SDK

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

## WKWebView 接入

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

## 构建、测试和发布

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
./scripts/build_release.sh
```

发布脚本读取 `VERSION`，归档 Release 真机和模拟器，启用 `BUILD_LIBRARY_FOR_DISTRIBUTION`，生成 `dist/OfflineTool-<version>.zip` 和 SHA-256 文件。ZIP 附带许可证与第三方声明；现阶段可作为 GitHub Release 附件分发，无需先搭建包服务器。源码仓库不提交 build/dist；初次上传 GitHub、创建 release 和配置远程依赖应单独执行。

`generate_project.py` 确定性生成工程；修改工程配置时同步脚本。`generate_demo.py` 和 `generate_fixtures.py` 分别生成合成示例包和异常测试样本。SDK 内含固定版本 ZIPFoundation 0.9.20，无需联网解析依赖。

当前验证范围见 [验证记录](docs/VALIDATION.md)。最低系统真机、业务 H5 和实际网关联调不由模拟器测试替代。

## License

Apache-2.0，第三方 ZIPFoundation 为 MIT，详见 `LICENSE`、`THIRD_PARTY_NOTICES.md` 和 `Vendor/ZIPFoundation/LICENSE`。

[0.2.0 migration / 改名接入说明](docs/MIGRATION-0.2.0.md)
