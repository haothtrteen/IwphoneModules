# su 式命令入口与会话能力设计（评估稿，未改动运行代码）

适用对象：iwphone modrunner v3 + Shell Manager v1.3.15（broker 协议 v2）。
本文只做评估与接口设计，**不修改任何运行代码**。落地前需先按第 3 节做冲突复现。

---

## 0. 证据基线

| 编号 | 结论 | 来源 |
|---|---|---|
| E1 | 框架全链路**没有任何 `app_process` 调用** | 全仓 grep：`app_process` 仅出现在本项目文档里对 `content` CLI 的说明 |
| E2 | 守护由 adb shell 下发：`nohup setsid -d sh $MAIN_SH >/dev/null 2>&1 </dev/null &` | `AdbBootstrap.startFramework()` / `ensureWebui()` / `bootstrap.sh` |
| E3 | WebUI 是 `nohup <python> webui_server.py`，服务器为 `ThreadingHTTPServer` 且仅绑 `127.0.0.1:8537` | `webui_start.sh`、`webui_server.py:2117` |
| E4 | 根因级注释：**adbd 重启会清理自己 spawn 的进程树**，即使 `setsid` + PPID=1 也照杀；因此禁止在 `AdbBootstrap` 之外重启 adbd（`adb usb` / `adb tcpip` / 开关无线调试） | `AdbBootstrap.kt` 类注释第 4 条 |
| E5 | App 选 legacy TCP：`adb tcpip 5555` 写 `persist.adb.tcp.port=5555`，**该操作会重启 adbd**；无线调试开关与动态端口被刻意弃用（"重启后不保持"、"构成死结"） | `AdbBootstrap.kt` 类注释第 1 条、`ensureFixedPort()` |
| E6 | 命令执行是单次 `subprocess.run(["sh","-c",cmd])`，无状态、无 stdin、无 tty、输出截断 20000 字符、超时 1~60s | `webui_server.py:run_shell_command` |
| E7 | 已有原生文件系统 IO 目录 `MODIO_DIR=$IWPHONE_ROOT/modio`；stdout 若落 `/sdcard`(FUSE) 会让 `cmd` 类命令因 fd 无法经 binder 传递而静默失败 | `env.sh:32`、`webui_server.py:1038` |
| E8 | broker 的 `exec`/`request` 每次调用都重新查三元组授权表，未授权时弹悬浮窗并同步等待 | `BrokerProvider.authorize()`、`BrokerPrompt.ask()` |
| E9 | Shizuku 服务端由 `app_process --nice-name=shizuku_server` 启动；native starter 在启动前会 `fork()+setsid()` 并**终止旧的 shizuku_server 进程**；user service 还会再起多个 `app_process` | Shizuku 公开源码/架构文档（外部资料，非本项目验证） |
| E10 | `app_process` 无全局单例语义；Shizuku 自身即并行起多个实例 | E9 同源 |

**未能确认**：用户观察到的"无法同时激活"的具体现象、报错、启动顺序、ROM 版本、设备日志。本文的冲突归因是机制推断，需按 3.2 复现确认。

---

# 一、可行性结论

## 1.1 约定位置的"可执行入口文件"：可以做，但它只能是转发 stub

**结论：可行，但必须纠正"类似 root 的 su"这个直觉。**

| 约束 | 说明 |
|---|---|
| 不能放 `/system/bin/su` | 需改系统分区，免 root 方案不可能 |
| 不能靠 setuid 提权 | `/data` 挂载带 `nosuid`；shell 脚本的 setuid 位无效；SELinux 下 `untrusted_app` exec 一个 shell 属主文件**不会改变 uid/domain** |
| 不能放 `/sdcard` | FUSE 挂载 `noexec`，且框架自己的注释已确认该处不能承载 fd/binder 语义 |
| `/data/local/tmp/iwphone/bin/` 的直接 exec | `untrusted_app` 对 `shell_data_file` 是否有 execute 权限**需真机验证**；即便能 exec，权限仍是 app uid，不提权 |

所以入口文件的正确定位是 **client stub**：把调用方的命令经 IPC 转给已经以 shell(2000) 常驻的框架，由框架执行。这与 Shizuku 的终端工具是同一形态（脚本 + 转发，不是 setuid 二进制）。

**推荐规格：**

| 项 | 值 |
|---|---|
| 路径 | `$IWPHONE_ROOT/bin/iwsh`（`/data/local/tmp/iwphone/bin/iwsh`） |
| 属主/权限 | `shell:shell` / `0644`（**不设 x**） |
| 调用方式 | `sh /data/local/tmp/iwphone/bin/iwsh …`，由 `/system/bin/sh` 解析，只需 read 权限，绕开 noexec 与 execute 权限不确定性 |
| 内容 | 纯 mksh 兼容脚本；内部只用 `/system/bin` 工具 + 框架自带 busybox；不写任何密钥 |
| 身份传递 | 不自带身份，靠 broker 的 `Binder.getCallingUid()`；stub 不做鉴权 |
| 部署 | 由 `framework.bin` 打包，随 `bootstrap.sh` 解包；版本戳与 App 对齐 |

**能提供 / 不能提供**：能提供统一调用点、让"其他软件"不必知道 authority/端口；**不能**提供提权，也**不能**给没有 INTERNET 权限或无法执行 `content` CLI 的调用方兜底。对这类调用方必须改走应用内 `ContentResolver.call()`。

`0644` 而非 `0755` 是刻意选择：避免制造"它像 su 一样可以直接执行"的误导，同时规避 SELinux execute 检查。

## 1.2 从"一次一个命令"扩展到连续多条：可行，且有三种粒度

当前 E6 是纯无状态 `sh -c`，`cd`、环境变量、shell 函数、后台任务、`trap` 都不保持。基于 E3（多线程 HTTP）与 E7（原生文件系统 IO），三种扩展粒度按改动量排序：

| 粒度 | 实现 | 状态保持范围 | 改动量 |
|---|---|---|---|
| G1 批处理 | `POST /api/shell/batch`，整段脚本一次 `sh` 进程执行，返回整体 stdout/stderr | 单次请求内 | 最小：新增一个 handler + 一个函数，`/api/shell` 原样保留 |
| G2 单连接会话 | 新增回环 TCP 端口 `127.0.0.1:8538`，`ThreadingTCPServer` 每连接 fork 一个 `sh`，stdin/stdout 桥接；**连接断开即 kill 进程组** | 当前客户端进程内 | 中：新增服务端 + stub 的 REPL 模式 |
| G3 持久会话 | WebUI 内 `SessionRegistry` 维护 `sid → Popen(["sh"])`，多次 HTTP 调用读写同一进程 | 跨多次调用、跨客户端进程 | 最大：会话表、锁、TTL、心跳、sentinel、回收 |

G1 已经能满足"授权后连续执行多条命令"（一次授权、一段脚本里 N 条命令共享 cwd/env），且**零会话状态**，是必须最先做的一层。G2 才提供"交互式敲命令"的体验。G3 是唯一能跨多次独立 CLI 调用保持状态的形式。

## 1.3 两种会话生命周期对比

| 维度 | P 持久会话（跨多次终端调用） | S 进程内会话（关闭即销毁，类 Shizuku 终端工具） |
|---|---|---|
| 实现 | G3：`sid` + 服务端常驻 `sh` 进程 + 会话表 | G2：TCP 长连接 = 会话，连接即进程，断开即回收 |
| 状态载体 | 服务端内存中的 `SessionRegistry` | 客户端进程持有的 socket / 子进程 |
| 跨 `content call` 调用 | **能**（靠 sid） | **不能**；同一 stub 进程内 REPL 才能连续 |
| 授权语义 | 一次授权 → 长期可交互 shell，粒度从"每条命令"放大到"整个会话" | 一次授权 → 一次会话，退出即失效，与现有"请求即确认"一致 |
| 服务端状态 | 有状态：需 TTL、心跳、上限、重启失效定义 | 无状态：无表、无 TTL、无孤儿 |
| 会话劫持面 | `sid` 泄露 = 直接拿到 shell 会话；必须绑定 `(pkg,uid,sig)` + 一次性 nonce | 连接本身即凭证；需每连接 token + 首包鉴权 |
| 孤儿进程风险 | 高：客户端消失但 shell 不退出；需心跳 + `os.killpg` | 低：EOF/HUP 直接触发进程组回收 |
| WebUI 重启 | **所有会话全丢**，需向客户端返回明确错误码 | 仅当前连接断，语义天然清晰 |
| 输出边界 | 无 tty，多条命令输出易粘连；必须随机 sentinel + 非阻塞读 | 原生字节流，无粘连问题；但需处理 PTY 与 `cmd` 类命令 fd |
| 并发模型 | `ThreadingHTTPServer` 每请求一线程 + 每会话一把 `Lock`；读写要 condition variable | 每连接一线程，无共享状态 |
| 框架约束 | 会话 stdout 必须落 `MODIO_DIR`（E7），不能落 `/sdcard`；`exit`/`Ctrl-D` 会杀掉整个会话需拦截 | 同左；另外 8538 对全机开放，安全面比 8537 更大 |
| 与 Shizuku 形态 | 更像"远程 shell 服务" | 更像 Shizuku 终端工具（客户端进程持有一个特权 `sh`） |

**结论**：S 是默认形态，P 是显式开启的可选能力。理由：授权粒度不放大、无状态无孤儿、与 broker v2 的弹窗语义一致、WebUI 重启行为可预期。P 只在"确实需要跨多次独立调用保持 cwd/env"时才开，且必须以"用户显式选择 + 单独授权记录"为前置，不能默认启用。

## 1.4 app_process 冲突判定：**不是**

**判定：双方占用 `app_process` 导致互斥——不成立。**

1. E1：框架不用 `app_process`。启动链是 `adb shell` → `nohup setsid -d sh Main.sh`（mksh）与 `nohup python3 webui_server.py`（静态 Python ELF）。全仓仅有文档里提到 `content` CLI 是 `app_process` 起的，那是**系统工具**，不是框架进程。
2. E10：`app_process` 是 Zygote 的通用 Java 启动器，没有单例语义；Shizuku 自己就为 user service 并行起多个实例，并为每个实例指定不同 `--nice-name`。
3. E9：Shizuku native starter 的"kill old server"针对的是 `shizuku_server` 进程名，用于避免自己的重复实例；框架的进程名是 `sh Main.sh` / `python3`，不匹配。**唯一残留疑点**：`starter.cpp` 的 `foreach_proc()` 匹配条件未在本项目内核对，若按 uid=2000 宽匹配则可能误伤，需实测确认。

**真正的冲突根因（按证据强度排序）：**

| 级别 | 冲突点 | 依据 |
|---|---|---|
| **强** | **adbd 状态机 / 进程树**：App 的 `adb tcpip 5555` 会重启 adbd（E5）；Shizuku 的无线调试启动依赖 `adb_wifi_enabled` 与动态端口，开关/重配对会改变 adbd 状态。任何一方触发 adbd 重启，都会按 E4 把**由 adb shell 拉起的框架进程树清掉**；反向也会让 Shizuku 的连接/配对态失效 | E4 + E5（项目内实机注释） |
| 中 | **启动通道互斥的设计选择**：E5 明确选 legacy TCP 并弃用无线调试，而 Shizuku 恰恰依赖无线调试。两者抢的是同一套 adbd 配置（`persist.adb.tcp.port` vs `adb_wifi_enabled` / 动态端口） | E5 + E9 |
| 中 | **SELinux 域不一致**：root 路径下 `bootstrap.sh` 用 `su 2000 -c` 只改 uid、不改 domain；框架进程域可能不是 `u:r:shell:s0`。Shizuku starter 会显式校验 SELinux context。这不阻止共存，但会让框架侧 `cmd`/binder 类命令失败（E7 已踩过 fd 问题） | `bootstrap.sh` + E7 + E9 |
| 弱 | 端口/目录占用 | 8537、8538 与 Shizuku 不重叠；路径也不重叠 |

**一句话**：不是抢 `app_process`，是**共享 adbd 且双方都会触发 adbd 重启**，而框架进程正是 adbd 的子孙进程。

---

# 二、推荐方案边界

## 2.1 分层落地边界

| 层 | 内容 | 是否默认启用 |
|---|---|---|
| L0 | `/api/shell` 原样保留（向后兼容） | 是 |
| L1 | `iwsh` stub（0644，`sh` 解释执行）+ `/api/shell/batch` | 是 |
| L2 | G2 单连接会话（8538）+ `iwsh` REPL 模式 | 是，但可在 WebUI 配置关闭 |
| L3 | G3 持久会话（sid） | **否**，需用户在授权页显式开启并单独弹窗确认 |

明确不做：

- 不做 setuid / 系统分区写入 / 任何形式的"真 su"
- 不做 WebSocket（Python 标准库无实现，零第三方依赖约束下自研帧协议不划算）
- 不做 PTY 全仿真（`script`/`stty` 在 Android toybox 上行为不一），G2 先用管道 + 原始字节流
- 不做"会话内逐条弹窗"：一次会话建立时授权一次，会话内逐条**审计**但不再弹窗
- 不让会话绕过 `COMMAND_BLACKLIST`；会话内每条命令仍过黑名单

## 2.2 需要调整的接口（具体清单）

**Python / WebUI**

```
POST /api/shell/batch?cmd=<urlencoded 多行脚本>&cwd=&timeout=
    -> {ok, exitCode, stdout, stderr, count}        # 复用 run_shell_command 的黑名单/超时/截断

POST /api/session/ping                              # 探活 + 报告 8538 是否开启
```

`do_POST` 目前"读取并丢弃请求体，参数一律走 query string"（webui_server.py:1935）。batch 沿用 query string 即可，**不要改这个约定**；多行脚本用 URL 编码传，长度上限从 4096 提到 16384。

新增 `run_shell_batch()`：单个 `Popen(["sh"], stdin=PIPE, ...)`，一次性 write + `communicate(timeout)`。不引入会话表。

新增 `SessionServer`（仅 L2）：`socketserver.ThreadingTCPServer(("127.0.0.1", 8538), Handler)`，
- 首包必须带 token（复用 `current_token()`）；
- 每连接 `Popen(["sh"], start_new_session=True, stdin=PIPE, stdout=PIPE, stderr=STDOUT)`；
- 连接线程双向转发，任一方向 EOF → `os.killpg(pgid, SIGKILL)` 并关闭；
- 全局并发上限 8；
- stdout 缓冲落在 `MODIO_DIR/session/`（E7），不落 `/sdcard`；
- `daemon_threads = True`，WebUI 退出即全部断开。

**Kotlin / broker（协议 v3）**

`BrokerProvider.call()` 新增三个 method，`identify()` / `authorize()` 复用不变：

| method | 语义 |
|---|---|
| `batch` | 一段脚本，一次授权，一次执行；等价于 `exec` 但 cmd 允许多行 |
| `sessionOpen` | 触发一次授权弹窗；成功返回 `{host, port, oneTimeToken, expiresAt}`；**不返回 shell 句柄** |
| `sessionClose` | 主动失效 `oneTimeToken`（仅当会话仍在） |

- `oneTimeToken` 随机 32 字节，绑定 `(pkg, uid, sig, 会话创建时间)`，**一次性**、90 秒未使用即失效，存于 `BrokerStore` 新增 `sessions` 表。
- 授权撤销 / 永久拒绝 / 三元组失效 → **立即遍历 sessions 表把所有该 app 的 oneTimeToken 置废**；已在 8538 上建立的连接由服务端在下一次心跳（10s）时断开。
- `BrokerStore` 新增 `sessions`（上限 32 条，随进程重启清空）与 `session_seq`（防重放）。
- 审计：会话建立记一条 `SESSION_OPEN`，关闭记 `SESSION_CLOSE`；会话内命令由 Python 侧写独立 `session_audit.log`，App 侧不重复记（避免绕过审计的错觉要如实说明：**App 侧无法逐条审计 8538 上的交互命令**，这是 S 方案的真实能力缺口）。

**Dart**

- `IwphoneService.runShellBatch()`；终端页支持多行输入（现有 `runShell` 保持单条）。
- 授权页新增「连续会话」开关（对应 L2 的 8538 启停）与「持久会话」显式开关（L3）。
- `WebuiTokenManager` 无改动；会话 token 只用 `X-Token`/首包，不暴露给用户。

**`iwsh` stub 参数面**（不做命令示例，只定接口）

```
sh iwsh batch <script-file>        # 走 /api/shell/batch
sh iwsh exec  <cmd>                # 等价当前 exec
sh iwsh shell                      # 进 REPL，走 8538 单连接会话；退出即销毁
sh iwsh session <id> <cmd>         # 仅 L3 启用时可用，跨调用保持状态
```

## 2.3 生命周期约束（硬性）

| 约束 | 值 / 规则 |
|---|---|
| 会话创建授权 | 一次弹窗；允许「记住」则后续 `sessionOpen` 不再弹，但**每次仍生成新的一次性 token** |
| oneTimeToken | 一次性、90s TTL、绑定三元组、绑定端口实例 ID（WebUI 重启后旧 token 全废） |
| 单连接会话 TTL | 无独立 TTL；连接断开即回收；服务端 10s 心跳，客户端无响应即 killpg |
| 持久会话（L3） | 默认关闭；上限 4 个/应用、300s 空闲 TTL、`exit`/`exec`/`set -e` 语义需在 handler 里拦截 |
| 授权撤销联动 | 撤销 / 永久拒绝 / 签名或 uid 变化 → 立即使 token 失效并断开所有活跃连接 |
| WebUI 重启 | 所有会话立即失效，返回明确错误码 `SESSION_GONE`，客户端必须重新 `sessionOpen` |
| 并发上限 | 8538 全局 8 连接；`ThreadingHTTPServer` 不因此增加常驻线程 |
| 输出 | 会话 stdout 只落 `MODIO_DIR/session/`；不落 `/sdcard`；单会话输出上限 1MB 环形缓冲 |
| 黑名单 | 会话内命令同样过 `COMMAND_BLACKLIST`；stub 不做二次校验 |

## 2.4 与 Shizuku 共存的候选方案与取舍

| 方案 | 做法 | 优点 | 代价 / 风险 |
|---|---|---|---|
| **A 隔离 adb 通道**（推荐默认） | 检测到 Shizuku 运行时**不再执行 `adb tcpip 5555`、不写 `persist.adb.tcp.port`**；App 改走 mDNS 发现的动态端口直连；自持 adb server 用独立 `ADB_SERVER_PORT` 避免与系统 adb 抢 5037 | 改动集中在 `ensureFixedPort()` / `ensureTransport()`；保留现有架构；不依赖第三方 | 开机自启失效（动态端口重启后变，E5 的原始理由）；需重新配对；仍需实测 Shizuku 侧是否也会重启 adbd |
| **B 框架脱离 adbd 进程树** | 启动时把框架迁出 adbd 的 cgroup（或用 `am`/JobService/Sui 拉起），使 E4 的"清理进程树"不再命中 | 根治 adbd 重启连锁杀进程 | 免 root 下缺少可靠拉起者；改动 bootstrap/startFramework 全链路；可能与 E4 实机结论冲突，风险最高 |
| **C 复用 Shizuku 作提权后端** | 检测到 Shizuku 时框架通过 Shizuku API 启动/执行，不再自持 adb | 单一通道，天然无冲突；可顺带用其终端会话能力 | 强依赖第三方；框架要加 Java 层与 binder 客户端；Shizuku 未启动时的降级路径要单独维护；授权模型从自己的授权表变成双套 |
| **D 显式互斥**（推荐兜底） | 检测到对方运行时，在授权页/首页提示"两者共用 adb 通道，同时启用可能互相中断"，让用户二选一 | 零实现风险、验收最简单、不撒谎 | 能力受限，体验差；不能解决"用户就是想两个都要" |

**推荐组合**：A（默认自动避让）+ D（检测到 Shizuku 时的显式提示），C 作为后续可选增强，B 不推荐（与免 root 定位冲突且风险最高）。

**可共存条件（全部满足才算通过）**：

1. App 在 Shizuku 活跃期间不执行 `adb tcpip` / `adb usb` / 不改写 `persist.adb.tcp.port`；
2. 框架进程不在 adbd 的进程树/cgroup 内，或 adbd 在此期间不重启（二者至少满足其一）；
3. 8537 / 8538 与 Shizuku 端口无重叠，且 `ThreadingHTTPServer` 与 `ThreadingTCPServer` 都能绑定成功；
4. Shizuku starter 的 `foreach_proc()` 清理逻辑不命中框架进程名；
5. 框架按 `u:r:shell:s0` 域运行（root 路径不能只 `su 2000 -c` 降 uid）；
6. 双方都能在对方已运行的前提下冷启动成功，且 30 分钟内不互相中断。

## 2.5 潜在风险

| 风险 | 说明 | 缓解 |
|---|---|---|
| 会话 = 长期可交互 shell，提权粒度放大 | 与 broker v2「一次调用一次授权」的模型不同 | 默认 S，L3 显式开关 + 单独弹窗 |
| `sid` / token 泄露与重放 | 回环端口对同设备所有 app 开放 | 一次性 token + 三元组绑定 + 90s TTL + 进程实例 ID |
| App 侧无法逐条审计 8538 交互命令 | 直连后绕过了 `BrokerProvider` | 如实写入文档；Python 侧独立日志 + 每连接 token 可追溯到 app |
| 孤儿 `sh` 进程 | 客户端崩溃、连接半开 | `start_new_session` + `killpg` + 10s 心跳 + 全局上限 |
| `cmd` 类命令 fd 失败 | E7 已实锤 `/sdcard` 上会静默失败 | 会话 IO 全落 `MODIO_DIR` |
| WebUI 重启 / adbd 重启 | E4：adbd 重启会连框架一起杀，会话自然全丢 | 明确 `SESSION_GONE` 语义；不做"自动恢复会话" |
| `exit` / `Ctrl-D` 把会话打死 | 常驻 `sh` 与 `sh -c` 语义差异 | handler 拦截 `exit`；REPL 模式下给明确退出提示 |
| 输出粘连 / 阻塞 | 无 tty 时多条命令输出难分界 | G1 用整段脚本一次返回；G3 才需要随机 sentinel |
| 新增安全面 | 无密钥时 `_auth()` 仍放行，8537 老问题会被 8538 放大 | 会话端口**强制要求非空 token**，无密钥时直接不监听 8538 |

---

# 三、验收要点

## 3.1 入口文件

- [ ] `$IWPHONE_ROOT/bin/iwsh` 随 `framework.bin` 解包存在，属主 `shell:shell`、权限 `0644`、**无 x 位**
- [ ] `sh <stub>` 在 adb shell 与终端 App 两种上下文中都能解析执行；直接 exec 该路径失败但不产生误导性报错
- [ ] stub 内不含任何密钥、token、绝对路径硬编码之外的敏感信息
- [ ] 无任何 setuid/setgid 位；`grep -r nosuid` 记录设备挂载状态作为证据
- [ ] 明确记录：`untrusted_app` 是否能读 `/data/local/tmp/iwphone/bin/`（真机判定，决定 stub 是否要改放别处）
- [ ] stub 调用走 broker 授权，未授权时仍会弹窗/返回 `NEED_APPROVAL`，**不绕过授权表**

## 3.2 Shizuku 冲突复现与判定（先做，再决定要不要落地共存改动）

采集项（每次都要留档）：

```
ps -A -o pid,ppid,uid,args            # 确认框架进程是 sh / python3，而非 app_process
ps -A -o pid,uid,args | grep shizuku  # 确认 shizuku_server 的 nice-name
getprop persist.adb.tcp.port
settings get global adb_wifi_enabled
cat /proc/net/tcp                     # 5555 / 8537 / 8538 / 无线调试动态端口
cat /proc/<pid>/attr/current          # 框架 vs shizuku_server 的 SELinux 域
logcat -d -b events | grep -i adbd    # adbd 重启时间点
```

顺序矩阵（4 组，各跑 3 次，记录哪一方掉线及掉线时刻）：

| 组 | 顺序 | 观察重点 |
|---|---|---|
| 1 | 先启框架 → 再启 Shizuku | Shizuku 启动后框架 PID 是否消失（验证 E4） |
| 2 | 先启 Shizuku → 再启框架 | App 的 `adb tcpip 5555` 是否打断 Shizuku 连接 |
| 3 | 组 1 + 关闭 App 的「固定 adb 端口」 | 冲突是否消失（验证方案 A） |
| 4 | 组 2 + Shizuku 以 root 模式启动 | 是否绕过无线调试状态争用 |

判定标准：
- 若组 1 框架 PID 消失且 `logcat` 有 adbd 重启 → **确认是 adbd 进程树清理**，与 `app_process` 无关；
- 若组 3 冲突消失 → 方案 A 有效；
- 若组 1/2 中 `shizuku_server` 与框架 Python 进程都活着、只是功能异常 → 转查 SELinux 域与 `cmd` fd 问题，不是进程互斥；
- 若发现 Shizuku starter 的清理命中了框架进程 → 需核对 `starter.cpp:246-267` 的匹配条件，给框架进程改名规避。

## 3.3 会话能力

- [ ] G1：一段含 `cd` + 变量赋值 + 读取的多行脚本，在一次请求内状态保持，退出码为最后一条命令
- [ ] G1：`/api/shell` 原有单条行为**完全不变**（回归）
- [ ] G2：REPL 内连续 5 条命令 cwd/env 连续保持；客户端退出后 `ps -A` 中对应 `sh` 进程数回到基线（无孤儿）
- [ ] G2：连接半开（kill -9 客户端）后 10 秒内心跳回收生效
- [ ] G2：无访问密钥时 8538 **不监听**
- [ ] 授权：建立会话只弹一次窗；会话内命令不再弹窗但逐条留痕
- [ ] 撤销授权后：已有 8538 连接在 10 秒内断开，旧 token 无法再建会话
- [ ] 永久拒绝 / 签名变化：所有该 app 的 token 立即失效
- [ ] WebUI 重启：所有会话返回 `SESSION_GONE`，不残留进程
- [ ] token 重放：同一 `oneTimeToken` 第二次使用被拒
- [ ] 越权：A 应用的 token 在 B 应用进程里使用被拒（三元组绑定生效）
- [ ] 并发：8 连接打满后第 9 个被明确拒绝，WebUI 其它 API 仍可响应
- [ ] `cmd` 类命令在会话内可用（stdout 落 `MODIO_DIR`，不落 `/sdcard`）
- [ ] 会话内命中 `COMMAND_BLACKLIST` 的命令被拒
- [ ] L3（若实现）：默认关闭；开启后 `exit` 不杀死会话；300s 空闲回收；WebUI 重启全清
- [ ] 审计：SESSION_OPEN / SESSION_CLOSE 在 App 侧可见，且如实标注"会话内命令仅框架侧有日志"

## 3.4 共存回归

- [ ] 顺序矩阵 4 组 × 3 次，双方 30 分钟互不中断
- [ ] 方案 A 生效时：不写 `persist.adb.tcp.port`、不执行 `adb tcpip`，App 仍能通过动态端口连上
- [ ] 关掉「固定端口」后开机自启失效这一代价，在 UI 上有明确告知（不静默降级）
- [ ] 8538 与 8537 同时监听、与 Shizuku 端口无冲突
- [ ] 框架域为 `u:r:shell:s0`（root 启动路径也要满足，不能只降 uid）
- [ ] 检测到 Shizuku 时的提示文案出现，且用户可选「仍要同时启用」/「暂时停用其一」

---

# 四、端口探测能否替代固定端口实现自动化激活（补充评估）

## 4.1 结论速览

**探测该加，且应该加；但它只解决「端口是多少」，不解决「开机后 adbd 有没有在 TCP 上监听」。因此单靠探测不能替代固定端口实现可靠的开机自启。**

不过要先纠正一个容易被误解的前提：**「固定端口」不等于「每次开机都执行 `adb tcpip` 重启 adbd」。** `ensureTransport()` 第一步就是 `transportAlive(5555)`，命中即直接返回；`adb tcpip` 只在「5555 不通 + 发现动态端口成功」时执行，即首次配置或端口状态丢失时。日常开机自启**根本不碰 adbd**。所以「为了和 Shizuku 共存而放弃固定端口」是代价大于收益的交换。

开机后能否自动化，取决于设备处于哪一档：

| 开机后 adbd 状态 | 只读探测能否自启 | 说明 |
|---|---|---|
| `persist.adb.tcp.port=5555` 已设 | **能**（甚至不需要探测） | 现状；开机即监听，直连即可 |
| 无线调试服务开机自启（部分 ROM 或 `persist.adb.tls_server.enable` 生效） | **能** | mDNS 发现动态端口 + 已有配对密钥直连，无需重新配对 |
| 无线调试不自启（本项目实机小米、ColorOS 实测） | **不能** | adbd 不监听任何 TCP 端口 → mDNS 无广播 → 探测无对象；而 App 此时没有 shell，无法执行 `settings put global adb_wifi_enabled 1` 打开开关，死结 |

**探测方案真正的价值**在第二档：ADB 配对密钥跨重启保持（XDA ColorOS 实测：重启后只需重新打开无线调试，TLS 端口变了但配对仍有效，不需要重新输配对码）。所以只要 adbd 肯监听，探测链就能直接复用旧密钥连上；但**「把无线调试开关拨一次」这一步仍然躲不掉**，App 只是省掉了后面的配对与端口查询。

## 4.2 补充的外部实证（印证第 1.4 节）

- `tcpip 5555` 与 `adb_wifi_enabled` **互斥**：启用固定端口会把无线调试标志清 0（ColorOS 实测）。这正是 App 的 `adb tcpip 5555` 打断 Shizuku 的具体机制，比上一轮的推断更实。
- `adb_wifi_enabled` 这个 global setting 值本身是持久的，但**服务不会因此自启**：重启后全端口扫描找不到任何 ADB 监听端口，必须手动把无线调试开关拨一次。与 `AdbBootstrap.kt` 类注释的实机结论一致。
- **AOSP 源码确认（修正上一轮"理论路径"的措辞）**：`AdbService.WIFI_PERSISTENT_CONFIG_PROPERTY = "persist.adb.tls_server.enable"`，
  `systemReady()` 读它决定 `mIsAdbWifiEnabled` 并回写 `ADB_WIFI_ENABLED`，`bootCompleted()` 再调
  `mDebuggingManager.setAdbEnabled(mIsAdbWifiEnabled, WIFI)`。**原生设计上，写这一个 persist 属性确实能让开机自动开启 WiFi ADB**，
  不需要每次执行 `adb tcpip`。所以"改一个属性就全自动"在 AOSP 层面成立（见 R2）。
- **但真机有反例**：Android 13 实机日志显示，开机时若当前 WiFi 未连接或不被判定为可信网络，
  `AdbDebuggingManager` 会把 `persist.adb.tls_server.enable` **改回 0** 并停掉 wifi adb
  （日志：`changed to 0` / `adb wifi stopped`），表现正是"设了 1，开机后读回来还是 0"。
  另外 `service.adb.tls.port` 是 `adb_wifi.cpp` 使能时写出的**结果属性**，手动设它没有意义。
- `Settings.Global.ADB_WIFI_ENABLED` 只是 UI 状态记录，会被 `systemReady()` 用 persist 属性**覆盖**——
  这解释了 XDA 那条"值持久但服务不自启"：单独改 settings 值没用。
- 有资料称 Android 12+ 的 `_adb-tls-connect._tcp` 自动发现可在无线调试关闭时广播，但与主流 OEM 实测相反，**以本项目真机为准，不作为设计前提**。

## 4.3 设计：只读探测链 `probeTransport()`

硬约束：**探测阶段绝不执行 `adb tcpip` / `adb usb` / `setprop` / 开关无线调试**。任何一次写都会重启 adbd，重新踩进 E4 的「清理自己 spawn 的进程树」，也重新和 Shizuku 抢状态。

```kotlin
/**
 * 只读探测：找到一条可用 transport，但不改变 adbd 的任何状态。
 * 总预算 <= 15s，跑在 JobService 的子线程，禁止放平台主线程。
 */
fun probeTransport(ctx: Context): Result {
    // 0) 已有连接（含 5555）—— 零成本
    if (transportAlive(ctx)) return Result(true, "已连接 $TARGET")

    // 1) 上次成功的动态端口（SharedPreferences 缓存）
    //    很多 ROM 会复用端口，命中可省掉整段 mDNS 等待
    AutostartPrefs.lastDynamicPort(ctx)?.let { p ->
        connectAndVerify(ctx, "127.0.0.1:$p").let {
            if (it.ok) { cachePort(ctx, p); return it }
        }
    }

    // 2) mDNS _adb-tls-connect._tcp（开机路径 6s，首次配置路径 12s）
    discoverConnectPort(ctx, timeoutMs = probeTimeoutMs)?.let { p ->
        connectAndVerify(ctx, "127.0.0.1:$p").let {
            if (it.ok) { cachePort(ctx, p); return it }
        }
    }

    // 3) 只读属性候选：persist.adb.tcp.port / service.adb.tls.port
    //    读属性本身需要 shell，无 transport 时读不到；
    //    仅作「已有 transport 但端口变了」的补充，不作为开机主路径
    for (p in readCandidatePorts(ctx)) {
        connectAndVerify(ctx, "127.0.0.1:$p").let {
            if (it.ok) { cachePort(ctx, p); return it }
        }
    }

    // 4) 可选：读 /proc/net/tcp 找 LISTEN(state 0A) 且落在无线调试端口段的候选
    //    一次文件读 + 少量候选 connect；App 能否读该文件受 SELinux 限制，失败即跳过
    for (p in listeningPortCandidates(ctx)) {
        connectAndVerify(ctx, "127.0.0.1:$p").let {
            if (it.ok) { cachePort(ctx, p); return it }
        }
    }

    return Result(false, "只读探测失败：开机后 adbd 没有可连的 TCP 监听（未改动任何 adbd 状态）")
}
```

**不做全端口扫描**：Android 无线调试端口落在 30000–49999，从 App 侧逐个 `adb connect` 验证成本过高；XDA 那条 1.4 秒是设备 shell 内扫 `/proc/net/tcp`，App 侧没有这个条件。`/proc/net/tcp` 快路径若可读就够用。

## 4.4 `ensureTransport()` 拆分与调用点改造

```kotlin
fun ensureTransport(ctx: Context, allowReprovision: Boolean = false): Result {
    probeTransport(ctx).let { if (it.ok) return it }
    if (!allowReprovision) {
        return Result(false, "只读探测失败；为避免重启 adbd 已停止自动配置，请手动重试")
    }
    return ensureFixedPort(ctx)   // 唯一允许 adb tcpip 的入口
}
```

| 调用点 | 现状 | 改造后 `allowReprovision` |
|---|---|---|
| `startFramework()` ← `AutostartJobService`（开机） | `ensureTransport(ctx)` | **false** —— 开机路径绝不重启 adbd |
| `startFramework()` ← `AutostartChannel.runNow`（用户手点） | 同上 | **true**，但 UI 需二次确认「这会重启 adbd，可能中断 Shizuku」 |
| `ensureFixedPort()` ← `PairingReceiver`（配对成功） | 直接调 | 保持 true，这是首次配置的唯一合法窗口 |
| `ensureFixedPort()` ← `AutostartChannel`（用户点「固定端口」） | 直接调 | 保持 true，同上 |
| `AdbBootstrap:317 / :618` | `ensureTransport(ctx)` | 按业务判断：读状态类用 false，用户显式操作用 true |

配套新增：

- `AutostartPrefs.lastDynamicPort()` / `setLastDynamicPort()` —— 缓存上次成功的动态端口。
- `PairingNsd.findConnectPort()` 的 `timeoutMs` 由调用方传入；开机路径降到 6s。
- `probeTransport()` 检测到 `_adb-tls-connect._tcp` 存在时（意味着无线调试开着、Shizuku 可能正用），置 `coexistMode = true`：只连不写，并把该状态回传给 UI。
- `AutostartJobService` 失败时**指数退避重试 2 次**（10s / 30s / 90s）：无线调试广播可能在 BOOT_COMPLETED 之后才出现，一次判死会误报。用 `AutostartPrefs` 记重试次数，成功或用户在场操作后清零。
- 失败文案必须给出三条可行动路径，不能只说「失败」：① 打开无线调试开关；② 在设置里点一次「固定端口」（会重启 adbd，提示先停用 Shizuku）；③ 若已有 root/Sui，走 root 直启框架路径，完全绕开 adbd。

### 4.4.1 已确认的代码缺陷：`pinPort` 开关被开机路径绕过

`UiPrefs.pinPort()` 只在 `ensureFixedPort()`（886 行）里被检查；
**`ensureTransport()`（231 行）里的 `adb tcpip 5555`（255 行）完全不检查这个开关**，
而 `startFramework()` → `AutostartJobService`（开机路径）直接调 `ensureTransport()`。

后果：用户在安装页勾选「不固定 adb 端口」后，只要开机时 5555 不通，链路仍会
`mDNS 发现动态端口 → 连上 → 无条件 adb tcpip 5555` —— 写 persist 属性 + 重启 adbd。
**开关形同虚设**，而且恰好在无线调试开着（Shizuku 正要用）的时候触发。

修这个缺陷不能只在 255 行前加一个 `if (!pinPort) return`：后续 `startFramework()`、
`withDeviceSelector()`、三处 push 都硬编码了 `TARGET = 127.0.0.1:5555`，
跳过 tcpip 后连的是动态端口，所有后续命令会打到不存在的 5555。
安全修法必须先把 **transport target 参数化**（当前连接串贯穿 AdbBootstrap），
这属于 R1 的一部分，不能作为一行 hotfix 草率落地。

### 4.4.2 归因强度修正：Shizuku「失去激活」尚未在本项目证实

之前把「固定端口导致 Shizuku 失效」写得过于确定，这里降级并区分两个层次：

| 层次 | 机制 | 更贴合的现象 |
|---|---|---|
| (a) **一次性动作** `adb tcpip 5555` | 重启 adbd → E4 清理自己 spawn 的进程树 | **框架**突然消失 / 当次 Shizuku 连接被打断 |
| (b) **持久状态** `persist.adb.tcp.port=5555` | adbd 长期处于 legacy TCP 模式；ColorOS 实测会把 `adb_wifi_enabled` 清 0 | **Shizuku 开机后起不来 / 反复失去激活** |

对用户观察到的「Shizuku 失去激活」，**(b) 更可能是主因**；4.4.1 的缺陷会让 (a) 在每次
开机 5555 不通时额外发生一次。但两者都仍是**机制推断**：本项目从未在真机复现，
没有 logcat / 启动顺序 / 报错记录。反向因果也存在：Shizuku 切换无线调试 → adbd 重启 →
框架被杀（E4），表现是「框架掉了」而不是「Shizuku 掉了」。

判定对照实验（会重启 adbd 一次，注意框架会被杀）：
清掉 `persist.adb.tcp.port` 后观察 Shizuku 能否正常启动并保持。
- 清掉后正常 → 坐实 (b)；
- 清掉后仍不正常 → 与本 App 无关，转查 Shizuku 自身开机自启 / 多用户 / ROM 限制。

### 4.4.3 R2 的隐藏前置：免 root 能否写这个属性

`ensureFixedPort()` 注释已实机确认：**shell 身份写不了 `persist.adb.tcp.port`**
（SELinux `adbd_config_prop`），所以才必须由 adb 协议指令或 root 写。
`persist.adb.tls_server.enable` 同属系统属性，AOSP 的 `property_contexts` 是否允许
shell 写入**未验证**；公开资料里的 `setprop` 示例多来自 root shell。
若免 root 写不了，R2 直接不成立（除非借 Shizuku/Sui 的权限写一次）。
`Settings.Global.adb_wifi_enabled` 虽然 adb shell 能写，但会被 `AdbService.systemReady()`
用 persist 属性覆盖，跨重启无效。

## 4.5 三条「不固定端口」路线对比

| 路线 | 做法 | 开机自启 | 与 Shizuku 共存 | 代价 / 风险 |
|---|---|---|---|---|
| **R1 只读探测 + 保留 5555（推荐）** | 加 `probeTransport()`；保留已写入的 `persist.adb.tcp.port`，但把 `adb tcpip` 收窄到「用户在场显式操作」 | **可靠** | **可靠**（日常自启不碰 adbd；首次配置窗口与 Shizuku 错开即可） | 需改 `ensureTransport` 与 4 个调用点；已部署设备的 5555 属性不清除（清除本身也会重启 adbd） |
| **R2 持久 TLS 开关 + mDNS** | 首次配置写 `persist.adb.tls_server.enable=1`（不固定端口），开机靠 mDNS 探动态端口 | **AOSP 源码支持开机自启，但真机需过"WiFi 可信"门槛**；开机时 WiFi 未连/不可信会被重置回 0 | 好（不写 `adb.tcp.port`，不会把 `adb_wifi_enabled` 清 0） | 依赖开机时 WiFi 已连接且可信、依赖 mDNS 广播时机、动态端口仍需探测；小米 22011211C 上**未验证**；写入仍会改变 adbd 状态一次 |
| **R3 完全不写任何属性** | 只靠 mDNS + 端口探测 | **不可靠**：本项目实机与 ColorOS 上开机无监听 | 最好 | 每次开机需用户手动拨一次无线调试开关；与「免 root 自启」的产品定位冲突 |

### 4.5.1 三个「属性」不是一回事（最容易被混淆的点）

| 名称 | 类型 | 谁读它 | 写一次能否开机全自动 |
|---|---|---|---|
| `persist.adb.tcp.port` | persist prop | **init / adbd 启动脚本** | **能**（本项目实机已验证）：开机 adbd 直接监听 5555，不依赖 WiFi、不依赖解锁后服务、不需要 mDNS |
| `persist.adb.tls_server.enable` | persist prop | `AdbService.systemReady()` / `bootCompleted()` | AOSP 源码上能，但受开机时 WiFi 可信检查制约，可能被重置为 0；小米未验证 |
| `Settings.Global.adb_wifi_enabled` | Settings | UI + `AdbSettingsObserver` | **不能单独成立**：只是状态记录，会被上面的 persist 属性覆盖 |

**关键**：现行方案里的 `persist.adb.tcp.port=5555` **本来就是「改一个属性就全自动」**，而且是三者中唯一不需要
WiFi、不需要 mDNS、不需要等系统服务回调的。R2 想换的那一个属性，价值不在于"更自动"，而在于
**不占用 5555、不会把 `adb_wifi_enabled` 清 0，因而对 Shizuku 更友好**；代价是把自动化建立在一串
开机时序条件（WiFi 已连接且可信 → AdbService.bootCompleted → adb_wifi 启动 → mDNS 广播 → App 探测）之上。

#### 4.5.2 纠错：「可信 WiFi」门槛不适用于固定端口方案

有一个容易混淆的推理：「不可信 WiFi 下无线调试本来就不能激活，所以固定端口也一样受限，
两者门槛相同」。**不成立**，因为这两条路径根本不是同一套机制：

| | legacy `adb tcpip` + `persist.adb.tcp.port` | 无线调试 / TLS（R2） |
|---|---|---|
| 谁启动监听 | **init 直接读 persist 属性**，adbd 启动即在 `*:5555` 监听 | `AdbDebuggingManager` 在 `AdbService.bootCompleted()` 之后按条件开启 |
| 是否判断 WiFi 可信 | **不判断** | **判断**（不可信/未连接时会把 `persist.adb.tls_server.enable` 改回 0） |
| 连接路径 | App 自持 adb 连 **127.0.0.1 回环** | 同为回环，但服务端要先被系统服务拉起 |
| 需不需要 WiFi | **不需要**，飞行模式下也能连 | 需要 WiFi 已连接且被判定可信 |

关键点：**App 是「连自己」，所有命令走 `adb connect 127.0.0.1:5555`，流量在设备内部回环，
不经过任何网络接口。** `AdbDebuggingManager` 的可信网络检查管的是「要不要开启无线调试
TLS 服务」，跟回环 TCP 端口和 adb 授权密钥是两回事。adb 配对公钥是 adbd 的连接认证凭据，
也不受 WiFi 可信状态影响。

所以「不可信 WiFi 下密钥无法使用」这个判断对固定端口方案不成立；**可信 WiFi 恰恰是 R2 独有的
门槛，不是两者的共同门槛**。这也解释了 `AdbBootstrap.kt` 当年为什么选 legacy 5555：它把
自启从一串系统服务时序里摘出来，压到 init 阶段一个 persist 属性上。

代价是另一回事：`tcpip 5555` 与 `adb_wifi_enabled` 互斥（ColorOS 实测会把后者清 0），
这就是 Shizuku 冲突的根源。**固定端口在「自启可靠性」上明显更优，在「Shizuku 共存」上明显更差**，
两个目标本身冲突，R2 的价值只在后者。

**推荐 R1**：它把用户真正想要的东西（自动化激活 + 不与 Shizuku 抢 adbd）都拿到了，而且不必放弃已经生效的固定端口。R2 作为增强实验项，在真机验证 `persist.adb.tls_server.enable` 确实能跨重启保持且开机自启 TLS 服务之后再考虑；R3 不建议。

一句更直白的总结：**该改的不是「要不要固定端口」，而是「谁有资格触发 `adb tcpip`」。** 把写操作从开机链路里摘出去，冲突窗口就从「每次开机」缩小到「首次配对那一次」。

## 4.6 验收要点（补充）

- [ ] 冷启动探测总耗时 ≤ 15s，平台主线程无阻塞（冷启动时间不回退到秒级）
- [ ] 探测全程 `logcat -b events | grep -i adbd` **无重启事件**；`getprop persist.adb.tcp.port` 前后不变
- [ ] 三档设备状态矩阵各跑 3 次：5555 已设 / 无线调试已开但端口动态 / 无线调试关闭；记录各自能否自启与耗时
- [ ] Shizuku 活跃 + 无线调试已开：探测连上后 `settings get global adb_wifi_enabled` 仍为 1（没被清 0），Shizuku 服务不掉线
- [ ] 开机路径（`AutostartJobService`）**任何情况下都不产生 `adb tcpip` 调用**（代码审查 + 日志断言）
- [ ] 10s / 30s / 90s 退避重试生效；无线调试开关在第一次探测之后才打开时，第二次能救回
- [ ] 缓存端口命中路径：构造「端口复用」场景，确认跳过 mDNS
- [ ] 探测失败时 UI 给出三条恢复路径且 `coexistMode` 标记正确
- [ ] 回归：首次配对 → `PairingReceiver` → `ensureFixedPort(true)` 链路仍能把 5555 固定下来
- [ ] 回归：现有 `isPortFixed()` 只读属性、不建连的性能修复不被破坏

## 4.7 仍未确认

- 小米 22011211C 上 `persist.adb.tls_server.enable=1` 写入后，**开机解锁并连上 WiFi 时该值是否仍为 1**（会不会被可信网络检查重置为 0）
- **免 root（adb shell, uid 2000）能否写入 `persist.adb.tls_server.enable`** —— 写不了则 R2 不成立（见 4.4.3）
- Shizuku「失去激活」的真实时间点与原因：需 logcat 中 adbd 重启事件与 Shizuku 启动/失败时间对齐（见 4.4.2）
- App 进程能否读 `/proc/net/tcp` 并看到 adbd 的 LISTEN 条目
- `NsdManager` 在开机后多久开始稳定广播 `_adb-tls-connect._tcp`（决定退避窗口取值）
- Shizuku 具体版本在无线调试开启时是否也会重启 adbd（影响共存判据）

以上决定 R2 是否可选、以及退避参数怎么定；R1 不依赖这些结论，可先落地。
R2 不是 R1 的替代：R1 的「只读探测 + 开机路径禁止写 adbd」正是 R2 的前置条件。

---

# 五、当前首次激活与「固定 ADB 端口」的实际实现（代码核对）

## 5.1 首次激活的两条入口

**入口 A：通知栏配对（`startPairingFlow` → 通知 → `PairingReceiver`）**

1. `PairingNsd.findPairingPort()` 用 mDNS 找 `_adb-tls-pairing._tcp` 端口
2. `AdbBootstrap.pair()`：`adb kill-server`，再 `adb pair 127.0.0.1:<配对端口>`（配对码走 stdin）
3. 配对成功 → **立刻 `ensureFixedPort()`**：这一步才是自启持久化的真正落地点
4. 通知栏回报结果

**入口 B：安装页「部署框架」（`FrameworkInstallScreen._runInstall`）**

1. `status()` 查 `provisioned`（判据只是 `filesDir/adbhome/.android/adbkey` 存在）
2. `setPinPort(_pinPort)` → **只写 UI 偏好，不执行任何 adb 命令**
3. `deployFramework()` → `ensureTransport()` → push `framework.tar.gz` → `shell` 解压/建 busybox 链接
4. `WebuiTokenManager.set()` 下发访问密钥
5. `runNow()` → `startFramework()` → `ensureTransport()` + `frameworkRunning()` + `ensureWebui()`
   + `nohup setsid -d sh Main.sh >/dev/null 2>&1 </dev/null &`
6. 轮询 `GET /api/status` 直到 `daemonRunning=true`（最多 5 次 × 800ms）

## 5.2 自启持久化的四根支柱

| # | 内容 | 落地位置 | 跨重启机制 |
|---|---|---|---|
| ① | App 端 adb 私钥 | `filesDir/adbhome/.android/adbkey` | App 私有目录 |
| ② | adbd 记住的公钥 | `adb pair` | 系统侧保存，注释明确「密钥跨重启保持，此后无需再配对」 |
| ③ | **开机后有 TCP 监听** | `adb tcpip 5555` → `persist.adb.tcp.port=5555` | **init 属性；开机 adbd 自动监听 5555** |
| ④ | 开机调度 | `BootReceiver` → `AutostartScheduler`（`setPersisted(true)` JobScheduler，delay 10s）→ `AutostartJobService` → `startFramework()` | 系统 JobScheduler 持久化 |

外加 `AutostartPrefs.isEnabled` 总开关、`deployStamp`（App 升级自动重铺框架）、`.deployed` 版本标记。

**③ 是唯一让「开机后 adbd 有端口可连」的东西**；①②④ 都只是「能连上」的必要条件。
注释里那句「死结：开无线调试需要 shell，而重启后没 shell」说的就是：不靠 ③，
开机后没有任何 TCP 监听，`_adb-tls-connect._tcp` 也就没有广播，探测找不到对象。

## 5.3 UI「固定 ADB 端口」按钮的命令序列

位置：设置 → 开机自启设置 → 第 3 步（`autostart_screen.dart:388`）
→ `AutostartService.ensurePort()` → MethodChannel `ensurePort` → `AdbBootstrap.ensureFixedPort()`。

`run()` 的 `withDeviceSelector()` 会自动给 `get-state` / `shell` / `tcpip` / `push` 等补
`-s 127.0.0.1:5555`（除非调用方已显式指定目标，如 tcpip 阶段必须用动态端口）。

按顺序实际下发：

1. 读 `UiPrefs.pinPort()`；为 false 直接返回，**一条 adb 命令都不发**
2. `ensureTransport()`：
   - `adb -s 127.0.0.1:5555 get-state`（探活，命中就返回）
   - 不通 → `adb connect 127.0.0.1:5555`，再 `adb -s … shell id`（校验 `uid=2000`）
   - 仍不通 → mDNS 找 `_adb-tls-connect._tcp` 动态端口 → `adb connect 127.0.0.1:<动态>`
     + `adb -s 127.0.0.1:<动态> shell id`
   - **`adb -s 127.0.0.1:<动态> tcpip 5555`** ← 唯一的写操作：写 persist 属性并重启 adbd
   - 轮询 `connectAndVerify(5555)` 最多 20s
3. `adb -s 127.0.0.1:5555 shell getprop persist.adb.tcp.port`；已是 `5555` 则直接成功
4. 没写进去 → 再 `adb -s 127.0.0.1:5555 tcpip 5555`
5. 15s 轮询：`connectAndVerify` + `getprop persist.adb.tcp.port`，**必须读到 `5555` 才算成功**

第 5 步是踩过坑加的：只看 `adb tcpip` 回的 "restarting in TCP mode" 会被骗 ——
adbd 可能只设运行时 `service.adb.tcp.port` 而不写 persist，结果是「本次开机能用、重启就失效」。

## 5.4 与「不固定端口」有关的两处绕不过去的事实

- `ensureTransport()`（231 行）里的 `adb tcpip 5555` **不检查 `pinPort`**，
  而 `deployFramework()` 与 `startFramework()` 都直接调它。所以安装页勾了「不固定端口」，
  只要 5555 不通仍会执行 tcpip（见 4.4.1）。这个选项当前**没有真正生效**。
- 密钥不是障碍：配对公钥跨重启保持，App 私钥也在私有目录。**「开机用密钥连接」这半句成立，
  「开机探测到端口」这半句不成立** —— 开机后若无线调试没自启，adbd 根本不监听任何 TCP 端口，
  mDNS 没有广播，探测无对象；而打开无线调试开关又需要此刻还没有的 shell。

---

# 六、v1.3.16 已实现：无线发现模式（安装页高级选项）

**默认行为完全不变**：不勾选时仍走原来的 `adb tcpip 5555` 固定端口链路，
`ensureTransport()` 一行未改。

勾选「无线调试自动发现（不固定端口）」后：

| 阶段 | 行为 |
|---|---|
| 首次激活 / 配对成功 | `enableWirelessAutostart()`：`settings put global adb_wifi_enabled 1` → 由 `AdbSettingsObserver` / `AdbService` **让 system_server 写** `persist.adb.tls_server.enable=1`，绕开 shell 写不了 `adbd_config_prop` 的限制；随后读回校验。**不执行 `adb tcpip`，不写 `persist.adb.tcp.port`** |
| 每次开机 | `BootReceiver` → JobService → `startFramework()` → `ensureTransportDiscover()`：缓存端口 → mDNS `_adb-tls-connect._tcp`（8s）→ `connectAndVerify()` 复用跨重启的配对公钥 → 拉起框架。全程只读，不重启 adbd |
| 失败 | 30s / 90s 退避重试 2 次（mDNS 广播常晚于 BOOT_COMPLETED）；成功清零 |

关键实现点：

- **transport target 参数化**：`activeTarget: String`（默认 `TARGET=127.0.0.1:5555`），
  `withDeviceSelector()` 与所有显式 `-s` 都取它。否则会出现「连的是动态端口、
  后续 push/shell 却打到不存在的 5555」。这同时修掉了 4.4.1 的前提。
- **偏好即时落盘**：`setDiscoverMode` / `setPinPort` 在勾选时立刻写原生 prefs，
  不等点「部署框架」——因为 `PairingReceiver` 配对成功会**立刻**调 `ensureFixedPort()`。
- **互斥与冲突检测**：`ensureFixedPort()` 在发现模式下转调 `enableWirelessAutostart()`；
  后者若检测到 `persist.adb.tcp.port=5555` 已存在，直接报错并提示「需在首次配对前开启」，
  **不自动清除**（清属性会重启 adbd 并杀掉框架）。
- **两个开关互斥**：打开无线发现会自动把「固定 ADB 端口」置回开并禁用其交互。
- `isPortFixed()` 在发现模式下直接返回 false，避免白等一次 3s 的 getprop 超时。
- 文案与日志：安装页高级选项说明代价与前置，安装日志新增 `log.discoverModeOn`。

**仍需真机验证（设备未连接，未做任何端到端验证）**：

1. `settings put global adb_wifi_enabled 1` 在小米 22011211C 上是否真的让
   `AdbService` 写出 `persist.adb.tls_server.enable=1`，且重启后值仍为 1；
2. 开机时 `AdbDebuggingManager` 的 WiFi 可信检查会不会把它改回 0（AOSP/Android 13
   实机有此现象）——这是本模式最大的不确定项，也是高级选项文案里明示的风险；
3. `NsdManager` 在开机后多久稳定广播 `_adb-tls-connect._tcp`（决定 8s 超时与退避窗口）；
4. 与 Shizuku 同时启用时是否真的不再互相打断。

若 1 或 2 不成立，模式会在安装日志里如实报错并建议切回默认的固定端口模式，
不会静默假装成功。

---

## 附：本文未做的事

- 第一至五章为评估；**第六章所述无线发现模式已在 v1.3.16 落地**（Kotlin / Dart / i18n / 安装页）
- 未在真机复现 Shizuku 冲突（设备未连接）
- 未验证 `/data/local/tmp` 对 `untrusted_app` 的读/执行权限
- 未核对 Shizuku `starter.cpp` 的 `foreach_proc()` 精确匹配条件

以上四项是落地前的阻塞项，尤其 3.2 的复现结果会决定「共存方案」选 A 还是 D；
第 4.7 的四项只影响 R2 与退避参数，不阻塞 R1。
