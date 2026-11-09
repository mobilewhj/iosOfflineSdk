# loadFileURL 离线页面

0.3.1 的 2026-11-09 测试刷新统一使用 `loadFileURL`。从旧 scheme API 更新时，先调整绑定调用并重新解析依赖，见 [SPM 更新](SPM.md)。

```objc
WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
NSError *error = nil;
OFTPageBinding *binding = [sdk pageBindingForConfiguration:configuration error:&error];
if (!binding) { /* 向调用方交付配置错误 */ return; }
WKWebView *webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
[sdk loadPage:originalURL inWebView:webView binding:binding
    completion:^(OFTPageLoadResult *result, NSError *failure) {
        // offline=YES 时 loadedURL 为精确 file 入口，query/hash 保留。
    }];
```

## 加载与请求合同

- SDK 管理安装、SHA 校验、持久状态、active 选择和更新。文件读取权限只授予所选版本目录。
- 在创建 WKWebView 前调用绑定工厂，必需设置并确认 `allowUniversalAccessFromFileURLs=YES`；不可用或被忽略时绑定失败。`loadPage` 再次检查实际 WK 配置，拒绝错误创建顺序。该私有 WebKit 设置不提供关闭选项，分发审核兼容需调用方自行评估。
- 同域同静态路径的 HTTP/HTTPS 入口在有效端口相同或各为默认端口时可共用本地包。无合格包、关闭离线或入口不存在时加载原 HTTP(S) URL。
- 已打开页面的 reload/历史返回保留原版本；缺少 JS/CSS 不逐资源回源。关闭开关影响新页，不撤销已获得的目录权限。
- API 使用明确的 HTTP(S) 基址，静态资源使用相对路径。H5 直接发出 XHR/fetch，SDK 不改方法、正文、自定义头或参数，不增加业务代理，也不伪造 Origin。
- Origin、Referer、Cookie 和存储由 WebKit 文档环境决定；宿主按精确主文档限制身份和导航权限。账号、Bridge 和业务字段由宿主定义，SDK 不存储这些身份数据。
- 对仅允许 GET/POST/HEAD 的网关，应验证实际系统上的零预检；服务器仍需正确处理来源与认证，文件网络设置不绕过服务端规则。

## 合成验证工具

`python3 scripts/generate_file_probe.py` 生成合成 ZIP；`python3 scripts/generate_project.py` 更新工程。给 Demo 传 `--file-url-probe`，启动本机观察服务：

```sh
python3 scripts/file_probe_server.py --events /tmp/offline-probe-events.jsonl
```

默认只访问回环服务。可用 `--server-base` 指定 HTTP 观察服务，`--https-server-base` 指定 HTTPS 服务；服务侧用 `--cert`、`--key`、`--https-port` 配置 TLS。测试证书只在隔离测试设备建立信任，不跳过证书验证。

额外端点须显式传 `--include-targets` 及 `--business-url` / `--monitor-url`；工具没有内置宿主服务地址。所有演示头为 `X-Probe-*`、身份值为合成数据。观察服务拒绝 OPTIONS，检查 GET/POST/HEAD、JSON 原始字节、自定义头及 412 状态透传。

Demo 经真实 managed 安装、校验与 active 选择后运行 file 页面，结果保存为 `Documents/origin-probe-report.json`。这些合成检查不能代替真实宿主、账号、最低系统和物理设备验收。
