# Chunland iOS

Chunland 代购平台的 iOS 客户端（Swift 6 / SwiftUI，最低 iOS 18）。本仓库是自动同步的开源快照。

> **这是一个客户端。** 仓库不含后端 —— 运行需要你自备一个兼容的服务端（参见下文 API 约定）。直接编译可得到完整 UI，但浏览/登录/下单等需连上后端才工作。

## 架构

- `ChunlandCore/` —— 本地 SwiftPM 包：纯业务逻辑（Models / Network / Services / Stores / AI 编排），无 UI、可独立测试。
- `Chunland/` —— App target：仅 SwiftUI Views + 资源。
- `project.yml` —— [XcodeGen](https://github.com/yonyz/XcodeGen) 配置源（`.xcodeproj` 不入库，本地生成）。

## 构建

```bash
brew install xcodegen
cp Config.xcconfig.example Config.xcconfig   # 填入你自己的 bundle id / team / 后端主机
xcodegen generate
open Chunland.xcodeproj
```

`Config.xcconfig` 已 gitignore —— 填你自己的值，请勿提交。各字段说明见 `Config.xcconfig.example`。

## AI 助手

对接任意 OpenAI 兼容服务 —— 在应用内配置页填入 endpoint 与 key 即可使用。
key 只存本机 Keychain，请求直连你配置的服务，不经过其它服务器。

## 未包含的功能

部分功能依赖第三方 SDK 或自建服务，不在本仓库中；相关入口会自动隐藏，不影响其余部分构建与运行。

## API 约定

客户端期望一个 REST 后端，响应信封：

```json
{ "code": 0, "message": "ok", "data": { ... } }
```

`code === 0` 为成功。请求体 snake_case、响应解码 `convertFromSnakeCase`。后端主机由 `Config.xcconfig` 的 `PROD_API_HOST` 配置（Release）/ 开发期可在 app 内开发者入口改地址（Debug）。

自建后端时需要注意几点 —— 客户端把这些判断完全交给了服务端：

- **订单的可执行动作由后端下发**：客户端不内置状态机，操作按钮的可用性完全取自 `order.availableActions`。后端不返回该字段，订单详情页就没有任何可点的操作。
- **金额由后端计算**：客户端不复算费率，下单前调 `POST orders/quote` 取金额分解（含配送/服务费与起送校验）。
- **401 仅用于 token 失效**：客户端收到 401 会自动刷新 token、失败则登出。业务性失败（验证码错误、密码错误等）请用信封里的非零 `code` 返回，否则用户会被无故登出。

## License

见 [LICENSE](./LICENSE)。
