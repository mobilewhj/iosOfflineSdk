# 宿主、H5 与网关的接入边界

## 职责

当前源码的托管入口见 [托管接入](MANAGED-INTEGRATION.md)：SDK 管理 ZIP、active/首次记录、版本选择、静默检查、资源缓存代际和不可变页面目录；宿主提供业务配置 provider、条件、UI 与导航。SDK 不读取用户信息、不注入 Cookie、不代理业务 API。旧低层安装 API 的签名和默认无回源行为保留。

托管入口由 SDK 决定安装和页面资格，关闭后新页面加载原 HTTP(S) 地址；旧页后续静态资源决定显式回原 HTTP(S) 源，保留已经成立的响应。每页绑定固定版本。宿主保留业务导航和原生能力授权；不能把任意相对业务 API 纳入静态回源。

H5 使用明确的环境 API HTTPS 基址，避免根据 `location.protocol` 或相对页面 origin 构造业务接口。静态资源可以使用相对路径；绝对 HTTPS 静态地址不会被自定义 handler 截获。需要联调异步 chunk、图片、字体、iframe、路由跳转及 CSP。

## 用户信息注入

自定义协议页面不能假定 `document.cookie` 与 HTTPS 页面行为相同。推荐宿主在 WKWebView 创建前注册 document-start、main-frame-only 的 `WKUserScript`，用 `NSJSONSerialization` 序列化允许给该页面的数据；H5 公共初始化入口优先读取约定的注入对象，原 Cookie 路径作为其他端兼容。

不要用字符串拼接把原始用户值写进 JavaScript；序列化后仍需处理脚本中的 U+2028/U+2029。注入代码必须检查页面的 scheme、host、port 和路径边界，导航策略也必须限制不可信页面复用同一个有权限的 WebView。`forMainFrameOnly` 本身不能限制随后主页面跳到外站。注入对象只传页面所需字段，不记录 Token，不在 SDK 保存用户数据。

注入内容是业务权限边界，不由通用 SDK 定义字段或加密方式。Demo 只有虚构的 displayName，示范注入位置和读取时序，不代表生产身份协议。用户切换、退出登录、网页缓存和已打开页面的数据刷新/失效由宿主统一处理。加密字符串进入 H5 后仍需被页面使用，不应把加密当作允许不可信页面访问的依据。

## 实际网关跨域

页面 `app-offline://example.com` 请求 `https://api.example.com` 时跨域，原生 JSBridge 存在不会自动绕过浏览器 CORS。

1. 在目标 iOS 系统和实际 H5 请求上记录 Origin、OPTIONS、Access-Control-Request-Headers；不能假定所有系统版本都序列化成相同 Origin，更不能为了兼容直接允许所有 `null` 来源。
2. 网关允许经过审核的来源；OPTIONS 不应因缺少业务 Token 而被登录拦截。允许实际方法及实际自定义头，并在真正 API 响应上也返回 CORS 头；包含错误响应。
3. 若按来源动态返回 `Access-Control-Allow-Origin`，同时使用 `Vary: Origin`。不要反射任意来源。只有实际使用浏览器 Cookie 凭据的接口才讨论 credentials 配置；Token 自定义头也可能触发预检。
4. CORS 头由 API/网关响应提供，不能通过给本地 HTML 响应加头修复远端跨域。SDK 不修改网关，不注入全局 fetch/axios 补丁。

若服务端不能满足跨域要求，需要另行评估受限的原生 API 通道及其认证、取消、错误语义，而不是在 SDK 中隐式代理任意 URL。本 SDK 当前不含这种代理。

## 最小验收

先在独立 Demo 验证包安装、本地 HTML/JS/CSS/fetch、handler 取消，再用实际 H5 联调身份读取、API OPTIONS 和登录。最后覆盖用户切换、页面导航、离线开关、缺资源、新旧版本同时打开及清理。SDK 可以独立分发，宿主业务可用性另行验收。
