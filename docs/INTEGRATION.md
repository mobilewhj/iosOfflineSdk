# 宿主、H5 与网关的接入边界

## 职责

当前源码的托管入口见 [托管接入](MANAGED-INTEGRATION.md)：SDK 管理 ZIP、active/首次记录、版本选择、静默检查、资源缓存代际和不可变页面目录；宿主提供业务配置 provider、条件、UI 与导航。SDK 不读取用户信息、不注入 Cookie、不代理业务 API。旧低层安装 API 的签名保留；自定义协议加载 API 已移除。

托管入口由 SDK 决定安装和页面资格，关闭后新页面加载原 HTTP(S) 地址；已加载 file 页面保留版本目录读取权限；关闭开关不能撤回 WebKit 已获读取范围，需要宿主关闭的旧页面由宿主管理。每页绑定固定版本。宿主保留业务导航和原生能力授权；不能把任意相对业务 API 纳入静态回源。

H5 使用明确的环境 API HTTPS 基址，避免根据 `location.protocol` 或相对页面 origin 构造业务接口。静态资源可以使用相对路径；绝对 HTTPS 静态地址由 WebKit 在线请求，包内资源应使用相对路径。需要联调异步 chunk、图片、字体、iframe、路由跳转及 CSP。

## 用户信息注入

file 页面不能假定 `document.cookie` 与 HTTPS 页面行为相同。推荐宿主在 WKWebView 创建前注册 document-start、main-frame-only 的 `WKUserScript`，用 `NSJSONSerialization` 序列化允许给该页面的数据；H5 公共初始化入口优先读取约定的注入对象，原 Cookie 路径作为其他端兼容。

不要用字符串拼接把原始用户值写进 JavaScript；序列化后仍需处理脚本中的 U+2028/U+2029。注入代码必须检查精确绑定的 file 主文档路径、query、主框架以及原始 HTTP(S) 身份边界，导航策略也必须限制不可信页面复用同一个有权限的 WebView。`forMainFrameOnly` 本身不能限制随后主页面跳到外站。注入对象只传页面所需字段，不记录 Token，不在 SDK 保存用户数据。

注入内容是业务权限边界，不由通用 SDK 定义字段或加密方式。Demo 只有虚构的 displayName，示范注入位置和读取时序，不代表生产身份协议。用户切换、退出登录、网页缓存和已打开页面的数据刷新/失效由宿主统一处理。加密字符串进入 H5 后仍需被页面使用，不应把加密当作允许不可信页面访问的依据。

## 文件页面网络与网关

SDK 的 file 绑定必需开启 `allowUniversalAccessFromFileURLs`，保留 H5 原有 HTTP/HTTPS 请求。它是私有 WebKit 设置；SDK 不把它隐藏成请求协议改造，也不承诺提审兼容。SDK 没有业务网络代理或全局 fetch/axios 补丁。

1. 在目标 iOS 系统和实际 H5 请求上记录 Origin、方法、头名称和响应，验证干净会话中没有 OPTIONS；不从 `location.origin` 推断线上请求头，更不能直接允许所有 `null` 来源。
2. 若网关只接受 GET、POST、HEAD，应使用拒绝 OPTIONS 的测试服务验证实际请求。网关及实际经过的服务需正确处理抓到的 file 来源和业务鉴权；来源白名单必须覆盖实际路由，不能只修一个业务服务。
3. 若按来源动态返回 `Access-Control-Allow-Origin`，同时使用 `Vary: Origin`。不要反射任意来源。只有实际使用浏览器 Cookie 凭据的接口才讨论 credentials 配置；Token 自定义头也可能触发预检。
4. CORS 头由 API/网关响应提供，不能通过给本地 HTML 响应加头修复服务端拒绝。文件网络设置不会移除服务器的来源校验、鉴权、TLS 或业务错误。

业务方法、URL 参数、JSON 正文及自定义头不改写。浏览器自动生成的 Origin、Referer、Cookie 和同源存储不承诺与 HTTP(S) 页面完全一致，宿主/H5 身份接线及后端处理仍需分别验证。

## 最小验收

先在独立 Demo 验证包安装、本地 HTML/JS/CSS/fetch、页面选择取消；让观察服务拒绝 OPTIONS，核对实际 HTTP/HTTPS 请求正文、鉴权头和响应状态，再用实际 H5 联调身份读取、业务与登录。最后覆盖用户切换、页面导航、离线开关、缺资源、新旧版本同时打开及清理。SDK 可以独立分发，宿主业务可用性另行验收。
