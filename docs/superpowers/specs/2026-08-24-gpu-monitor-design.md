# GPU Monitor macOS 菜单栏组件设计

## 1. 目标

构建一个面向 macOS 14 及以上版本的原生菜单栏应用，持续监控两台 NVIDIA GPU 服务器的每张 GPU 状态。应用每 15 秒通过 SSH 执行只读 `nvidia-smi` 查询，在 GPU 开始占用、恢复空闲、服务器持续离线或恢复在线时发送 macOS 系统通知。

首版不设置开机自启，不显示 Dock 图标，不保存服务器密码。通知层使用可扩展接口，首版实现 macOS 系统通知，并为后续微信接入预留稳定入口。

## 2. 监控目标

| 标识 | 地址 | SSH 端口 | 用户名 |
| --- | --- | ---: | --- |
| `server-10122` | `122.207.108.8` | `10122` | `yanxiaoyang` |
| `server-10165` | `122.207.108.8` | `10165` | `yanxiaoyang` |

密码只在首次部署专用 SSH 公钥时使用，不进入源码、配置文件、日志或最终应用包。

## 3. 用户体验

应用以无 Dock 图标的菜单栏程序运行。菜单栏标题显示全局摘要，例如：

```text
GPU 5/8 空闲
```

点击菜单栏图标后，弹出按服务器分组的状态面板：

```text
服务器 10122    在线
GPU 0  空闲       0%    120 MiB / 24 GiB   35°C
GPU 1  占用      92%     18 GiB / 24 GiB   71°C

服务器 10165    在线
GPU 0  空闲       0%     80 MiB / 24 GiB   33°C

上次更新：12:35:15       [立即刷新]
```

菜单还包含通知权限状态、最近错误摘要和“退出”。应用不提供“登录时启动”选项。

## 4. 架构

### 4.1 `GPUProbe`

负责对单台服务器执行一次只读采样。两台服务器通过 Swift 并发任务同时查询，任一服务器超时不阻塞另一台。

本地应用通过 `/usr/bin/ssh` 使用以下安全选项：

- `BatchMode=yes`
- `-F /dev/null`，完全忽略用户和系统 SSH 配置
- 独立身份密钥，并设置 `IdentitiesOnly=yes`
- 仅允许公钥认证：`PreferredAuthentications=publickey`、`PasswordAuthentication=no`、`KbdInteractiveAuthentication=no`
- 独立并固定的 `known_hosts`；`GlobalKnownHostsFile=/dev/null`。`UserKnownHostsFile` 的路径先转义反斜杠和双引号，再包在 OpenSSH 配置值层的双引号中，以单个 `-o` 参数传递，避免 `Application Support` 被配置解析器按空白拆分
- `ClearAllForwardings=yes`，禁止本地、远端、动态和配置继承的转发
- 8 秒连接超时
- 禁止交互式密码回退

远端受限密钥只允许执行以下固定命令，输出分为 GPU 清单和计算进程清单两段：

```sh
nvidia-smi --query-gpu=index,uuid,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits && printf '\n__GPU_MONITOR_PROCESSES__\n' && nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv,noheader,nounits
```

两次 `nvidia-smi` 与 marker 必须用 `&&` 串联，任一查询非零都会使 SSH 采样整体失败；不得用 `|| true` 掩盖 compute query 失败。compute query 成功但没有进程时可以没有进程行，此时所有 GPU 正常判为空闲。

解析器将计算进程按 GPU UUID 关联到对应 GPU。没有计算进程时，该 GPU 的原始状态为“空闲”；存在一个或多个计算进程时为“占用”。利用率、显存和温度只用于展示，不参与空闲判断。

### 4.2 `StateTracker`

每张 GPU 以“服务器标识 + GPU UUID”为稳定键，状态为：

- `unknown`
- `free`
- `busy`

首次成功采样直接建立基准，不发送状态变化通知。每个 GPU 记录完整的 confirmed GPU（占用状态、指标和进程），`ServerSnapshot` 只由 confirmed GPU 组合。此后某个候选状态必须连续出现两次才成为稳定状态；第一次相反候选不得改变稳定快照或 UI 占用。与 confirmed 占用一致的成功观察可以刷新指标和进程。15 秒轮询下，正常变化会在约 15–30 秒内确认，失败采样继续保留 confirmed snapshot。

probe 失败保留脱敏的结构化分类：connectivity、host-key/security、authentication、remote-command、invalid-response 和 local-launch。只有连续 connectivity 失败才累计；连续三次后将服务器标记为离线并发送一次通知，真实的 `Network is unreachable` 与 `Connection refused` 都属于 connectivity。其余分类会中断 connectivity 连续计数：主机密钥失败显示独立安全错误，认证、远端命令、无效响应和本地启动失败显示独立查询警告，绝不触发离线通知。下一次成功查询后才发送一次恢复通知。任何错误文案都不得包含主机、用户、私钥路径或远端 stderr 中的秘密。

### 4.3 `Notifier`

通知层定义统一的 `NotificationSink` 接口，输入结构化事件：

- GPU 开始占用
- GPU 恢复空闲
- 服务器离线
- 服务器恢复在线

首版的 `MacOSNotificationSink` 使用 `UserNotifications`。应用启动前安装并强引用 `UNUserNotificationCenterDelegate`，使应用位于前台时通知仍以 banner/list 展示并播放系统提示音。通知权限会在每次刷新、菜单面板每次呈现及应用重新激活时重新读取；并发读取合并为一个任务，菜单关闭会取消对应的 SwiftUI view task，停止后返回的旧结果会被丢弃。同一服务器在同一次采样中有多张 GPU 变化时合并为一条通知，例如：

当前 ad-hoc 签名被系统以 `UNError.Code.notificationsNotAllowed` 拒绝且授权状态不是 `denied` 时，通知适配器切换到安全兼容模式：固定调用 `/usr/bin/osascript`，固定标题为“GPU Monitor”，把事件标题作为副标题、正文作为独立 argv 传入。菜单显示橙色“通知：兼容模式”，系统通知来源显示为“脚本编辑器”。原生权限以后可用时自动恢复原生通道；用户明确拒绝时绝不回退。

```text
服务器 10122：GPU 0、GPU 2 已空闲
服务器 10165：GPU 1 开始占用（python，PID 12345）
```

后续微信接入实现新的 `WeChatNotificationSink`，复用同一事件结构和状态逻辑。核心监控模块不依赖微信 SDK、Webhook 或具体账号类型。

### 4.4 `MenuBarUI`

使用 SwiftUI 与 AppKit 构建原生菜单栏应用。界面只读取监控快照，不直接执行 SSH。颜色语义如下：

- 绿色：所有服务器在线，至少有空闲 GPU
- 橙色：所有服务器在线，但全部 GPU 被占用
- 黄色：存在短暂 connectivity 失败或非安全查询警告
- 红色安全图标：存在主机密钥安全错误
- 红色离线图标：至少一台服务器已确认离线
- 灰色：尚未取得首次成功结果

“立即刷新”会触发一次并行采样；若已有采样正在执行，则复用当前任务，避免并发重复查询。

## 5. 配置与本地存储

应用配置位于：

```text
~/Library/Application Support/GPUMonitor/servers.json
```

配置只包含服务器标识、地址、端口、用户名、密钥路径和轮询参数，不包含密码。专用 SSH 文件为：

```text
~/.ssh/gpu_monitor_ed25519
~/.ssh/gpu_monitor_ed25519.pub
~/Library/Application Support/GPUMonitor/known_hosts
```

虽然进程调用边界已经把 `-o` 的值作为单个 argv 元素传入，OpenSSH 仍会按 `ssh_config` 语法再次解析它。因此上面的含空格路径必须编码成 `UserKnownHostsFile="..."`，不能只依赖 shell 或 Swift 的参数边界。

私钥权限必须为 `0600`。应用仅保存最后一次内存快照，不持久化进程历史或长期 GPU 使用记录。

## 6. SSH 安全模型

首次配置流程：

1. 本机生成一把无口令、仅供 GPU Monitor 使用的 Ed25519 密钥。
2. 使用用户提供的密码分别登录两个 SSH 端口。
3. 首次连接采用 TOFU（Trust On First Use）：读取并记录每个端口对应的服务器主机指纹，在安装报告中展示该指纹。
4. 向远端用户的 `~/.ssh/authorized_keys` 追加带 `restrict` 和强制命令的专用公钥。
5. 使用 `BatchMode=yes` 验证两台服务器均只能返回监控数据，且不能获得交互式 Shell。

该过程不覆盖现有 `authorized_keys`，只追加一行。若服务器 OpenSSH 不支持 `restrict`，使用等价的 `no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding` 限制选项。

首次记录后即固定主机指纹；后续指纹与已记录值不一致时，应用拒绝连接并显示安全错误，不自动接受新指纹。

## 7. 错误处理

- SSH 超时、DNS/路由失败、`Network is unreachable`、`Connection refused`：保留旧状态，只累计连续 connectivity 失败。
- 主机密钥、认证、远端命令、无效响应和本地 SSH 启动错误：保留旧状态，显示各自的 warning/security health，并中断 connectivity 连续计数。
- `nvidia-smi` 不存在或任一查询返回非零：SSH 采样整体失败并显示远端命令警告，不把服务器当作无 GPU。
- 单行 GPU 数据格式错误：本次服务器采样整体失败，避免产生部分状态误报。
- GPU UUID/名称、进程 GPU UUID/名称不得为空；GPU UUID 与 index 不得重复；进程 GPU UUID 必须引用本次 GPU 清单。
- 无计算进程输出：正常解析为所有 GPU 空闲。
- 通知权限明确被用户拒绝：菜单栏继续工作并显示“通知：未授权”，不得启用兼容通道。
- ad-hoc 签名触发精确的 `notificationsNotAllowed` 错误：启用兼容通道；其他授权错误显示“通知：状态错误”。
- 兼容通知启动失败、超时或非零退出：只把对应消息记为调度失败，不泄露命令 stderr 或通知正文。
- 应用退出：所有正常退出路径由 AppKit 生命周期桥统一进入异步停止流程，等待取消定时器和正在运行的 SSH 子进程后再答复系统允许退出；重复退出请求共享一次停止，并在停止完成后逐一答复所有仍在等待的系统请求。

日志只记录时间、服务器标识、错误类别和状态变化，不记录密码、私钥内容或认证令牌。

## 8. 测试策略

### 单元测试

- 解析单卡、多卡、无进程、多进程和异常 `nvidia-smi` 输出。
- 按 GPU UUID 正确关联进程。
- 首次采样不通知。
- 连续两次相同候选状态才确认变化。
- 单次候选和抖动不改变 confirmed snapshot；稳定观察可以刷新指标和进程。
- 抖动序列不会产生错误通知。
- 同一服务器的多卡变化合并通知。
- 连续三次连接失败触发一次离线事件，恢复后触发一次在线事件。
- 非 connectivity 失败不会累计或触发离线；主机密钥失败显示安全 health。
- GPU/compute query 非零的离线 command harness 都验证整体命令非零；成功的空进程输出仍视为正常空闲。
- 精确匹配 `notificationsNotAllowed`、明确拒绝不回退、原生权限恢复和兼容投递取消。
- 验证兼容通知固定使用 `/usr/bin/osascript`，动态内容只作为 argv，不能进入 AppleScript 源码或 Shell。

### 集成测试

- 使用假的 SSH 执行器测试超时、非零退出码和取消。
- 对两台真实服务器执行只读采样，核对 GPU 数量、利用率、显存、温度和进程关联。
- 验证专用密钥可以执行固定监控命令，但不能启动交互式 Shell。

### 安装验收

- 构建并安装 `GPU Monitor.app` 到 `/Applications`。
- 首次启动可请求 macOS 通知权限。
- 菜单栏每 15 秒更新，手动刷新可用。
- 模拟状态变化时只发送预期通知。
- 应用不出现在“登录项”中。
- 安装验收应按运行时授权结果判断：原生授权成功时预期由 GPU Monitor 原生投递；只有精确 `notificationsNotAllowed` 且授权状态不是 `denied` 时才预期进入“通知：兼容模式”并由“脚本编辑器”显示。
- 2026-08-24 实机验收：原生 `com.yxy.gpumonitor` 通知在 10165 第三次连接拒绝附近展示一次，后续观察未重复；本次未在实机触发兼容模式。
- 安装器的离线行为 harness 在临时目录用假命令覆盖无匹配进程、不同 UID/路径、Apple Event 失败、退出超时和正常退出顺序，保证测试不接触真实 `/Applications`、进程或 Apple Event。

## 9. 交付物

- 可运行的 `/Applications/GPU Monitor.app`
- 完整 Swift 源码
- 自动化测试
- 安装、配置和卸载说明
- 不含密码的服务器配置样例

应用在当前 Mac 上本地构建并采用 ad-hoc 签名，不进行 App Store 分发、公证或公开发布。

## 10. 非目标

首版不包含以下功能：

- 开机自启
- 微信实际发送实现
- GPU 历史曲线或长期数据库
- 作业调度、终止进程或远程命令终端
- 多用户账号体系
- 公网服务端或云同步
