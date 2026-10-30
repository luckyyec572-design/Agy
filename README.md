# AGY for iPhone

独立的 SwiftUI 原生 Antigravity CLI 客户端，沿用 [Pi iPhone](https://github.com/ddyec/Pi-iPhone) 的消息展示与界面基础。iOS 17+、仅 iPhone，SVG 原生预览使用固定 SwiftDraw 0.29.0。Bundle ID：`com.ddyec.agy-iphone`，可与 Pi 同时安装。当前源码版本 1.2.0 / build 4。

App 图标、登录页、欢迎页和消息标识使用 [Google 官方 Antigravity Press Assets](https://antigravity.google/press) 全彩原图；来源与打包说明见 `Brand/README.md`。

聊天、模型选择、历史、工具详情与设置均为原生界面，不加载桌面网页。输入框跟随键盘与安全区，支持深浅色、动态字体、复制、分享、Markdown、代码和表格。

## 本次本地交付

本次按要求只修改本地文件并交付源码 ZIP：**未推送、未触发 Actions、未生成本版 IPA**。包内工作流已改为仅手动触发，避免导入源码后自动消耗额度。Mac 本地构建：

```sh
bash scripts/check-local.sh
bash scripts/package.sh
```

Linux 本地只验证后端、Swift 语法和隔离 CLI 能力；Xcode 类型检查、iPhone 归档及真机交互仍需在 Mac/手机完成。

## 新配置逻辑

- 先选模型名称，再选该模型实际支持的思考强度，后端分别传 `--model` 与 `--effort`。
- Restriction Mode：每次工具操作都有原生允许/拒绝卡片；失联、超时和停止时拒绝，不缓存始终允许。
- Turbo Mode：通过 CLI 的单次设置自动执行。明确的 ask/deny 规则依然有效。
- “先做计划／直接实施”是另一项执行方式，独立于审批策略。
- PI 新版的三种输出展示、代码换行、完整表格、Unicode 文件链接、原生下载/保存/分享、图片和 SVG 预览、按本地日期分组历史、会话缓存与草稿已适配。
- PI 和 AGY 共用新的手势感知滚动跟随器；手动查看历史时不再由刷新、懒加载标记或键盘事件重新启用跟随。

逐项差异和未移植项见 [PI_COMPARISON.md](PI_COMPARISON.md)。

## 新账号与配套后端

**新 App 必须配套本包后端。现有线上网关未重启、未切换到本版，旧登录未注销。** 新账号采用独立 CLI HOME，账号凭据和会话数据库分开，不覆盖共享 AGY 或 PI 的登录。具体操作见 [ACCOUNT_LOGIN.md](ACCOUNT_LOGIN.md)。

```sh
python3 scripts/account.py create new-account
python3 scripts/account.py login new-account
python3 scripts/account.py check new-account
```

准备好新账号后按说明切换后端；`https://agy.yectech.uk` 和原网关密钥可继续使用。Google OAuth、Cloudflare Token、连接密钥均不在源码包内。

模型、审批和文件协议见 [Server/API.md](Server/API.md)。最少需要支持 `--settings` 的 AGY CLI 1.4.10+。网关只监听本机，由现有命名隧道提供 HTTPS。

## 保留功能与边界

原生聊天、图片/文件上传、流式同步、历史重命名/删除、模型与工作目录选择、工具详情、停止、断线恢复、请求去重、账户真实额度都保留。输入框左侧“+”选择照片/文件，单个 25 MiB、最多 8 个、合计 50 MiB；照片方向修正后缩至 2048 像素 JPEG，文档保留字节。

AGY 使用自己的文件/图片工具读取上传文件；不把图片静默丢成纯文本。服务端文件下载限定到当前会话工作目录及自身产物目录，外部下载不带网关认证。手机退出或断网不重发原 prompt；服务器重启标记中断，不自动重新执行。

官方 Remote Control 会话导入、PI 的压缩/树分支 RPC、技能/插件管理、APNs 和任意扩展 TUI 没有对应移植，不显示虚假的可用状态。普通源文件浏览/管理不是本次产物下载接口的功能。

Google 标识的原始来源见 [Brand/README.md](Brand/README.md)。这是独立客户端，不是 Google 官方 iOS App。

验证证据与未验证范围见 [VALIDATION.md](VALIDATION.md)。
