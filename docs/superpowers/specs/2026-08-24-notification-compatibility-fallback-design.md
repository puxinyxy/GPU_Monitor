# GPU Monitor macOS 通知兼容回退设计

## 1. 背景与目标

GPU Monitor 已使用 `UserNotifications` 发送原生 macOS 通知。当前安装包采用 ad-hoc 签名，实际启动时 `UNUserNotificationCenter.requestAuthorization` 稳定返回 `UNErrorDomain` 的 `notificationsNotAllowed` 错误；系统中也没有可用的 Apple 代码签名身份。相同机器上，由 `/usr/bin/osascript` 调用 `display notification` 可以被通知中心正常投递和展示。

本次改动的目标是在保留原生通知主通道的同时，为这种“系统拒绝临时签名应用注册通知”的环境增加安全兼容通道，使 GPU 占用、空闲、服务器离线和恢复事件仍能产生 macOS 系统通知。既有 `NotificationSink` 接口保持不变，后续微信实现仍通过该接口接入。

## 2. 已选方案

采用“原生优先、按明确错误自动回退”的双通道设计：

1. 应用启动时照常请求 `UserNotifications` 授权。
2. 原生授权成功时只使用原生通知，通知来源为 GPU Monitor。
3. 用户明确拒绝授权时返回“未授权”，不得启用兼容通道绕过用户选择。
4. 只有原生授权调用抛出 `UNErrorDomain` 且错误码等于 `UNError.Code.notificationsNotAllowed.rawValue`，同时当前授权状态不是 `denied` 时，才启用兼容通道。
5. 其他未知授权错误仍返回“状态错误”，不静默降级。
6. 应用重新激活或菜单重新打开时继续读取原生授权状态；一旦变为 authorized、provisional 或 ephemeral，立即恢复原生通道。一旦变为 denied，立即停用兼容通道。

兼容通道发出的通知由 macOS 显示为“脚本编辑器”来源，通知标题仍为“GPU Monitor”。这是当前无 Apple 签名身份环境下的明确产品限制，并在 README 中说明。

## 3. 组件与数据流

### 3.1 原生通知客户端

既有 `UserNotificationCenterClient` 继续封装 `UNUserNotificationCenter`，负责请求授权、读取状态和调度原生通知。它不负责兼容策略。

### 3.2 兼容通知客户端

新增一个仅负责投递单条通知的内部协议及实时实现。实时实现通过现有 `CommandRunning` 抽象启动固定可执行文件 `/usr/bin/osascript`，超时为 5 秒。

AppleScript 程序是源码中的固定参数，不拼接任何事件数据。通知标题和正文在 `--` 之后分别作为独立 argv 元素传入：

```text
/usr/bin/osascript
  -e 'on run argv'
  -e 'display notification (item 2 of argv) with title "GPU Monitor" subtitle (item 1 of argv) sound name "default"'
  -e 'end run'
  --
  <title argv>
  <body argv>
```

该调用不经过 Shell。固定通知标题为“GPU Monitor”，事件标题作为副标题，事件正文作为正文。事件标题或正文中的引号、反斜杠、换行、分号、反引号和命令替换文本都只是一个普通参数，不会成为 AppleScript 源码或 Shell 命令。

### 3.3 通道选择器

`MacOSNotificationSink` 保存当前投递模式：native 或 compatibility。

- `requestAuthorization()` 负责首次选择模式。
- `authorizationState()` 负责随系统状态变化纠正模式。
- `send(events:)` 继续使用既有 `NotificationFormatter` 聚合事件，再将每条消息发送给当前通道。
- 任一消息投递失败时沿用 `NotificationDeliveryFailureReason.schedulingFailed`，只报告失败数量，不把命令 stderr、路径或事件正文写入错误摘要。
- 任务取消后不得继续启动新的兼容通知进程。

`NotificationAuthorizationState` 新增 `compatibility`。菜单显示“通知：兼容模式”，使用橙色和 `bell.fill` 图标；它不被当作授权错误。

## 4. 状态转换

| 当前观察 | 投递模式 | 对外状态 |
| --- | --- | --- |
| authorized / provisional / ephemeral | native | 原状态 |
| denied | native，禁用回退 | denied |
| 请求抛出 notificationsNotAllowed，且读取状态不是 denied | compatibility | compatibility |
| compatibility 模式下读取到 notDetermined 或 error | compatibility | compatibility |
| compatibility 模式下后来读取到允许状态 | native | 对应允许状态 |
| compatibility 模式下后来读取到 denied | native，禁用回退 | denied |
| 其他请求错误 | native | error |

兼容模式只存在于当前应用进程内，不写入配置文件。应用每次启动都会先尝试原生授权，因此以后使用正式 Apple 证书签名安装时会自然回到原生通知。

## 5. 安全与隐私

- 固定使用绝对路径 `/usr/bin/osascript`，不从 `PATH` 查找可执行文件。
- 不使用 `/bin/sh`、`zsh -c`、`do shell script` 或字符串命令拼接。
- AppleScript 源码固定；动态标题和正文只通过 argv 传递。
- 不把服务器密码、SSH 私钥、认证错误原文或远端 stderr 放入通知。
- 不在授权诊断日志中保留通知正文或用户凭据。
- 用户明确拒绝原生通知时，兼容回退必须关闭。

## 6. 错误处理

- `osascript` 启动失败、超时或非零退出：该条通知记为调度失败，监控轮询和菜单显示继续运行。
- 多条聚合通知逐条投递：单条失败不阻止后续未取消的消息。
- 未知原生授权错误：显示“通知：状态错误”，不启用兼容模式。
- 兼容模式运行期间原生权限发生变化：下次应用激活、菜单打开或状态刷新时按状态表切换。
- 兼容投递失败不会触发重试循环，避免系统服务异常时每 15 秒累积子进程。

## 7. 测试策略

按测试先行实现，至少覆盖：

1. `notificationsNotAllowed` 激活 compatibility，其他错误不激活。
2. 原生状态为 denied 时绝不回退。
3. compatibility 后读取到 authorized 时恢复 native；读取到 denied 时关闭回退。
4. 兼容客户端只启动 `/usr/bin/osascript`，固定脚本参数、`--`、标题和正文顺序完全正确。
5. 含引号、换行、分号、反引号和 `$()` 的恶意样式正文仍是单个 argv，不进入脚本源码。
6. 兼容投递成功、部分失败、超时和取消时的计数与停止行为。
7. 菜单对 compatibility 的文字、图标、颜色和非错误语义。
8. 包装策略测试禁止 Shell 与动态 AppleScript 拼接。

真实验收包括：

- 重新打包并安装 `/Applications/GPU Monitor.app`。
- 启动后确认菜单显示“通知：兼容模式”。
- 利用端口 10165 当前稳定的连接拒绝，在第三次 connectivity 失败后确认通知中心收到一次服务器离线通知，后续轮询不重复发送。
- 确认端口 10122 仍能实时显示 7 张 GPU 的状态。
- 确认没有新增登录项或开机自启设置。

## 8. 文档与非目标

README 将说明原生通知与兼容通知的选择条件、兼容通知来源显示为“脚本编辑器”，以及安装正式 Apple 签名后可恢复 GPU Monitor 原生来源。

本次不包含：

- 申请或安装 Apple 开发者证书。
- 实际接入微信发送服务。
- 为兼容通知增加历史记录、重试队列或自定义声音。
- 绕过用户明确的通知拒绝选择。
