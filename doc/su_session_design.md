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

所以入口文件的正确定位是 **client stub**：把调用方的命令经 IPC 转给已经以 shell(2000) 常驻的框架，由框架执行。这与 Shizuku `rish` 是同一形态（脚本 + 转发，不是 setuid 二进制）。

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

| 维度 | P 持久会话（跨多次终端调用） | S 进程内会话（关闭即销毁，类 Shizuku rish） |
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
| 与 Shizuku 形态 | 更像"远程 shell 服务" | 更像 Shizuku `rish`（客户端进程持有一个特权 `sh`） |

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
| **C 复用 Shizuku 作提权后端** | 检测到 Shizuku 时框架通过 Shizuku API 启动/执行，不再自持 adb | 单一通道，天然无冲突；可顺带用 `rish` 的会话能力 | 强依赖第三方；框架要加 Java 层与 binder 客户端；Shizuku 未启动时的降级路径要单独维护；授权模型从自己的授权表变成双套 |
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

## 附：本文未做的事

- 未修改任何运行代码（Python / Kotlin / Dart / Manifest 均未动）
- 未在真机复现 Shizuku 冲突（设备未连接）
- 未验证 `/data/local/tmp` 对 `untrusted_app` 的读/执行权限
- 未核对 Shizuku `starter.cpp` 的 `foreach_proc()` 精确匹配条件

以上四项是落地前的阻塞项，尤其 3.2 的复现结果会决定"共存方案"选 A 还是 D。
