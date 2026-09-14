# GPU Monitor

GPU Monitor 是 macOS 14 及以上版本的原生菜单栏应用。它每 15 秒通过专用受限 SSH 密钥查询四台服务器的 GPU 状态，并在 GPU 占用状态或服务器在线状态稳定变化时发送系统通知。应用不配置开机自启，也不提供远程终端或进程控制能力。

## 安装

在终端中依次运行以下命令。SSH 配置会按顺序访问 `10122`、`10165`、`18200` 和 `13000`；需要认证时，密码只由系统 `ssh` 在交互式终端读取，不进入脚本、配置、日志或应用包。

| 显示名称 | SSH 端点 |
| --- | --- |
| `3090 · 10122` | `122.207.108.8:10122` |
| `3090 · 10165` | `122.207.108.7:10165` |
| `A100 · 18200` | `js2.blockelite.cn:18200` |
| `A100 · 13000` | `js2.blockelite.cn:13000` |

首次连接采用 TOFU，脚本会显示保存到专用 `known_hosts` 的主机指纹，请与服务器管理员提供的指纹核对。

```bash
cd /Users/yxy/Documents/workspace/gpu-monitor
./scripts/provision_ssh.sh
swift run GPUMonitorCoreTestsRunner
./scripts/package_app.sh
./scripts/install_app.sh
```

`package_app.sh` 生成并验证 `dist/GPU Monitor.app` 的 ad-hoc 签名。`install_app.sh` 重新打包；只有检测到当前用户从 `/Applications/GPU Monitor.app/Contents/MacOS/GPUMonitor` 精确路径运行的实例时，才通过固定 bundle identifier 的非阻塞 Apple Event 请求已安装实例正常退出，并有界等待它完成 SSH 与兼容通知子进程清理。Apple Event 失败或实例在限定时间内未退出时，安装会停止，不发送 SIGTERM/SIGKILL。候选包先复制到 `/Applications` 下唯一 staging 路径并验证签名和 bundle identity；旧包再移入显式 backup，验证后的候选原子替换最终路径并再次校验。替换或最终校验失败时恢复并验证旧包；没有旧包时不会留下损坏的最终 bundle。安装过程不会修改其他应用，也不会停止调试版本或其他同名进程。

## 本地验证

以下命令不连接真实服务器、不发送真实通知，也不修改 `/Applications` 或 SSH 配置：

```bash
swift run GPUMonitorCoreTestsRunner
swift run GPUMonitorAppTestsRunner
zsh Tests/PackagingTests/provisioning_behavior_test.sh
zsh Tests/PackagingTests/install_app_behavior_test.sh
zsh Tests/PackagingTests/package_scripts_test.sh
swift build -Xswiftc -swift-version -Xswiftc 6 -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

## 通知模式

应用优先使用 `UserNotifications` 发送来源为 GPU Monitor 的原生通知。当前 ad-hoc 签名若被 macOS 以 `notificationsNotAllowed` 拒绝，应用会自动进入“通知：兼容模式”，通过固定的 `/usr/bin/osascript` 系统通道投递；通知标题仍为 GPU Monitor，系统显示的来源为“脚本编辑器”。标题和正文作为独立参数传入，不经过 Shell。用户若明确拒绝通知，应用不会启用兼容模式。有效 Apple 证书签名可能使系统允许原生通知，但不是恢复的保证；应用只有在随后观察到授权状态为 `authorized`、`provisional` 或 `ephemeral` 时才恢复原生通道，`denied` 仍保持未授权且绝不回退。

## 状态含义

- 绿色：全部服务器在线，且至少一张 GPU 空闲。
- 橙色：全部服务器在线，但所有 GPU 均被计算进程占用。
- 黄色：至少一台服务器发生短暂连接失败，或存在认证、远端查询、响应解析、本地 SSH 启动警告；界面保留 confirmed snapshot。
- 红色安全图标：SSH 主机密钥校验失败；不会累计为服务器离线。
- 红色离线图标：至少一台服务器已连续三次发生 connectivity 失败并确认离线。
- 灰色：启动后尚未取得首次成功采样。

GPU 的空闲/占用由是否存在计算进程判断。利用率、显存和温度只用于展示。首次成功采样仅建立基准；第一次相反候选不会改变 UI 的 confirmed 占用，连续第二次才更新并触发通知。与 confirmed 占用一致的观察仍会刷新指标和进程。

失败分为 connectivity、host-key/security、authentication、remote-command、invalid-response 和 local-launch。只有连续 connectivity 失败才计入三次离线阈值；`Network is unreachable` 与 `Connection refused` 属于 connectivity。其他失败会中断该连续计数并显示独立 warning/security 状态，错误摘要不会回显主机、用户名、密钥路径或 SSH stderr 中的秘密。

## 配置与服务器编辑

首次启动会创建：

```text
~/Library/Application Support/GPUMonitor/servers.json
```

退出 GPU Monitor 后可编辑这个 JSON 文件中的 `id`、`label`、`host`、`port`、`username` 和 `identityFile`，再重新打开应用。配置不得加入密码。升级时，应用先纠正精确匹配的旧 `server-10165` 地址，再只更新仍使用旧数字标签的两台 3090 记录，并按批准顺序追加缺失的 A100 端点。自定义标签、记录、用户名、密钥路径和相对顺序会保留；同一主机名和端口不会重复添加，批准 ID 冲突时使用稳定回退 ID。只有配置实际变化时才原子写回。SSH 主机密钥固定在：

```text
~/Library/Application Support/GPUMonitor/known_hosts
```

该路径包含空格。应用和配置脚本会先转义路径中的反斜杠与双引号，再把完整路径包在 OpenSSH 配置值层的双引号中，以单个 `-o` 参数传递为 `UserKnownHostsFile="..."`；仅靠 shell 参数引号不足以阻止 OpenSSH 再次按空白拆分配置值。

主机指纹变化时应用会拒绝连接。不要直接删除或替换记录；先向服务器管理员核实新指纹，再显式更新对应条目。

## 隐私与安全

应用只在内存中保留最近一次 GPU 快照，不保存长期 GPU 使用历史。查询结果可能包含 GPU 型号、利用率、显存、温度、进程名和 PID；这些数据只在本机界面和通知中使用。日志只记录服务器标识、错误类别和状态变化，不应包含密码、私钥或认证令牌。

专用私钥为 `~/.ssh/gpu_monitor_ed25519`，权限为 `0600`。应用忽略用户 SSH 配置，只使用该身份和专用 `known_hosts`，只允许公钥认证，并清除全部转发。远端 `authorized_keys` 条目禁止 Agent/X11/端口转发、PTY 和用户 rc，并强制执行以下固定只读命令：

```sh
nvidia-smi --query-gpu=index,uuid,name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits && printf '\n__GPU_MONITOR_PROCESSES__\n' && nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv,noheader,nounits
```

两条查询与 marker 用 `&&` 串联，任一查询非零都会使采样失败；成功但没有计算进程输出仍是正常的空闲状态。配置脚本会实际请求 `echo SHOULD_NOT_RUN` 并验证转发被拒绝，只有所有安全检查均成功才保留新装的远端行。若本轮新加的精确行未通过后续验证，脚本会重新进行密码认证，只回滚该行并确认它已不存在；相同行若在运行前已经存在则绝不自动删除。回滚失败会失败关闭并给出不含公钥或私钥材料的人工修复提示。

## 卸载

先退出 GPU Monitor，然后显式删除应用：

```bash
rm -rf "/Applications/GPU Monitor.app"
```

本地卸载不会自动修改任何服务器。在删除本地 `.pub` 文件之前，若要撤销远端访问，必须先显示并临时记录公钥 blob：

```bash
awk '{print $2}' "$HOME/.ssh/gpu_monitor_ed25519.pub"
```

再分别登录四个端口，备份并编辑 `authorized_keys`：

```bash
ssh -p 10122 yanxiaoyang@122.207.108.8
ssh -p 10165 yanxiaoyang@122.207.108.7
ssh -p 18200 yanxiaoyang@js2.blockelite.cn
ssh -p 13000 yanxiaoyang@js2.blockelite.cn
```

在每台服务器上运行 `cp ~/.ssh/authorized_keys ~/.ssh/authorized_keys.gpu-monitor-backup`，然后用编辑器只删除公钥 blob 与上一步输出完全相同的那一行。此远端操作是独立、显式步骤；任何卸载脚本都不会代为执行。

完成所需的远端撤销并确认不再使用专用 SSH 身份与本地配置后，才选择执行：

```bash
rm -f "$HOME/.ssh/gpu_monitor_ed25519" "$HOME/.ssh/gpu_monitor_ed25519.pub"
rm -rf "$HOME/Library/Application Support/GPUMonitor"
```
