# AGY 1.2.0 与 PI iPhone 对照

对照的是服务器本地最新 Pi iPhone `7bd64df`（2.0.6），保留它已有的原生实现；本次另附 2.0.7 滚动修复源码。GitHub 默认分支较旧，没有用旧网页包装版本覆盖本地新版。未推送任何仓库，未启动 Actions。

| 功能 | 本次 AGY 适配 | 与 PI 的区别 |
| --- | --- | --- |
| 模型与思考强度 | 两个独立控件；模型仅显示名称，再选该模型实际支持的强度 | 来源是 AGY 模型目录；后端用 `--model` 与 `--effort` 两个参数，不套用 PI 的模型协议 |
| Restriction Mode | 官方 PreToolUse Hook 拦截每次工具操作；手机单次允许/拒绝；超时、取消、连接失败默认拒绝 | 底层 `request-review` + 原生审批桥接，所有工具都先走单次确认；不复用 PI 的扩展确认 RPC |
| Turbo Mode | CLI session-only `toolPermission=always-proceed`，无逐项原生审批 | AGY 的显式 ask/deny 规则仍有效；不是修改全局权限，也不是 PI 的思考模式 |
| 执行方式 | 先计划／直接实施，和审批策略分开 | 对应 AGY `plan`／`accept-edits`。Auto Preview 依赖账号和沙箱，本版不伪装提供 |
| 三种输出展示 | 合入原版、步骤摘要、结论优先，保存选择；过程可展开 | AGY 的实际步骤和工具事件适配成展示结构；摘要只取真实内容，不额外推断结论 |
| 代码与表格 | 合入代码自动换行/横向滚动切换、完整表格换行、复制 | 修复代码块每次重新出现都重设展开状态的问题 |
| 图片、SVG | 合入工具图片、图片链接和 SVG 的原生预览、放大；源码可查看 | 保留 Google 官方 AGY 标识。使用固定 SwiftDraw 0.29.0，不用网页渲染 |
| 文件链接 | 合入 Unicode/sandbox/工作目录链接识别、下载、原生预览、保存和分享 | AGY 新增自己的会话文件接口；只允许该会话工作目录和自己 brain 中的产物。外部 HTTPS 下载用无网关令牌的独立连接 |
| 会话历史 | 合入本地时区分组、搜索；保留 AGY 的原生历史页 | 不导入官方 Remote Control 的全部会话；不冒充 PI 的会话树 |
| 缓存与草稿 | 会话缓存、按会话草稿；切换 Google 配置时清除旧账号待发送和缓存 | Google 登录在服务器独立 HOME 中完成，不复用 PI 的 Cookie 登录 |
| 滚动 | 两套 App 共用单一滚动跟随器，识别手指拖动与惯性；手动阅读时不因状态更新、图片载入或键盘变化重新跟随 | 移除懒加载底部坐标判定、逐 revision scrollTo 和竞争的 bottom anchor。代码块展开初始化只执行一次 |
| 额度 | 保留原生 `/v1/limits`，显示账户真实配额 | 使用 AGY `/usage`；不从 PI 的 token 统计推算订阅额度 |
| PI 独有操作 | 未硬接 PI 压缩、树分支、工具开关、技能/扩展管理和通知盒子接口 | 两个后端能力不同；没有对应 AGY 稳定接口的按钮不制造虚假的成功反馈 |

Restriction 的名称用于表达逐项审批体验；官方当前文档称 Request Review／strict。无头 `stream-json` 不接收 `control_response`，因此这次使用官方 Hook 的单次 `auto_approve`/`deny` 返回值桥接，未伪造不支持的协议事件。真实 CLI 已验证拒绝、单次允许与 Turbo 无审批三条链路。

原生 App 的审批发生在每次工具执行前。为避免 CLI 再停在手机无法操作的官方产物弹窗，网关单次设置 `artifactReviewPolicy=always-proceed`；计划/写入工具的参数仍先经过 Restriction 的逐项审核。它不是官方桌面产物审查界面的完整复刻。Turbo 同时关闭逐项工具等待和产物等待；明确的 ask/deny 规则仍由 CLI 保留。

文档依据：[AGY 权限](https://antigravity.google/docs/permissions)、[CLI 设置](https://antigravity.google/docs/settings)、[官方 Hooks](https://antigravity.google/docs/hooks)、[无头协议](https://antigravity.google/docs/cli/headless/)。

当前交付是源码包。Linux 本地后端回归、隔离 CLI 实测及 Swift 语法扫描已执行；没有 Xcode，未做本版 iPhone 归档、模拟器或真机验收。
