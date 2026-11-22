# 流式命令 · 落地说明（v1.3.27）

**本文件记录的是已实现的代码，不是设计稿。**

涉及入口：App 内置终端 / iwsh 终端（8539）/ 第三方授权应用（ContentProvider）。
三条入口最终都汇到框架的同一个端点：`POST /api/shell/stream`。

---

## 1. 为什么必须另开一条通道

原来的执行链路只有一条：`run_shell_command()` → `subprocess.run(capture_output=True, timeout=t)`。
语义是「等你跑完我再回话」，而且超时是**总时长**（1~60 秒），`TimeoutExpired` 时
连 `e.stdout` 都丢掉。

真机实测（22011211C）—— 一条命令就把问题暴露完：

| 尝试 | 结果 |
|---|---|
| `getevent -lt`，timeout=5 | 5.1 秒后返回 `{"ok":false,"msg":"命令执行超时（上限 5s）"}`，**零输出** |
| `getevent -lt -c 5`，timeout=10 | 设备空闲时永远凑不满 5 个事件，照样超时 |
| `nohup getevent -lt > /tmp/x.log &` + `wc -l` | 0.1 秒返回，14 行（设备枚举），**看不到后续事件** |

结论：不是「超时设太短」，而是通道语义不对。终端命令的输出是**流**，不是**返回值**。

---

## 2. 端点与协议

```
POST /api/shell/stream?cmd=<命令>&cwd=<目录>&idle=<秒>&max=<秒>&b64=1&token=<密钥>
```

| 参数 | 默认 | 语义 |
|---|---|---|
| `cmd` | — | 命令字符串，≤4096 字符，走与一次性通道**同一套**黑名单（`check_command()`） |
| `cwd` | — | 工作目录，非目录则忽略 |
| `idle` | 30 | **空闲超时**：连续 `idle` 秒没有输出才收工。`0` = 不限（谨慎使用） |
| `max` | 1800 | 单流最长生命周期，防止客户端异常退出后留下长跑进程。`0` = 不限 |
| `b64` | 0 | `1` 时输出用 base64 编码（二进制场景）；默认按 UTF-8 解码，非法字节替换为 `�` |

响应体是 **NDJSON**（每行一个 JSON 对象），按行 flush：

```json
{"type": "start", "id": "5f7110285243", "pid": 17627, "cmd": "getevent -lt", "idle": 3.0, "max": 1800.0}
{"type": "out", "data": "add device 1: /dev/input/event6\n  name:     \"uinput-fpc\"\n"}
{"type": "exit", "code": -9, "ms": 3038, "reason": "idle"}
```

`reason` 取值：

| reason | 含义 |
|---|---|
| `exit` | 命令自己退出了，`code` 是退出码 |
| `idle` | 空闲超时被停 |
| `max` | 达到最长运行时间被停 |
| `client` | 客户端断开（此时不会发 `exit` 行，连接已断） |

**前置错误**（`start` 之前）走普通 JSON 响应，不是 NDJSON：

| HTTP | code | 场景 |
|---|---|---|
| 400 | `BAD_CMD` | 命令为空 / 过长 / 命中框架黑名单 |
| 429 | `TOO_MANY_STREAMS` | 并发流已达 8 条 |
| 500 | `SPAWN_FAILED` | 起进程失败 |
| 403 | — | token 无效（`_auth()` 统一拦） |

### 为什么不用 chunked

本服务是 HTTP/1.0（`Handler` 没有改 `protocol_version`）。HTTP/1.0 里
「响应体 = 连接关闭前读到的全部字节」是标准语义，`dart:io HttpClient` /
`java.net.HttpURLConnection` / `BufferedReader` 都正确处理。

改成 HTTP/1.1 就必须给**每一个**响应补 `Content-Length` 或 `Transfer-Encoding: chunked`——
而这个文件里 `_send` / `_json` / `serve_module_webroot` 都是手写响应头，漏一处整站挂。
为了省一次连接关闭去重写分块逻辑，收益和风险不成比例。

---

## 3. 进程与资源回收

| 机制 | 实现 | 解决什么 |
|---|---|---|
| 独立进程组 | `Popen(..., start_new_session=True)`，`pgid = pid` | `sh -c 'a | b'` 的子进程能被整组杀掉 |
| 进程组回收 | `os.killpg(pgid, SIGKILL)` | 不留孤儿子进程 |
| 主进程退出后 0.5 秒宽限 | `proc.poll() is not None` 连续两轮才断 | 后台子进程还攥着 stdout 时，给尾巴留时间 |
| 空闲超时 | 读线程 + 队列，主循环 0.2 秒轮询 | 安静的命令不会永久占资源 |
| 最长生命周期 | `max` 参数（默认 1800 秒） | 客户端异常退出后兜底 |
| 并发上限 | `MAX_STREAMS = 8`，Popen 前先占位（非"数一遍再起"） | 防打满线程与进程 |
| 显式取消 | `POST /api/stream/kill?id=<id>` | 立即回收，不用等空闲超时 |
| 断连检测 | `wfile.write` 抛 `BrokenPipeError` → `reason=client` → 杀组 | 客户端关页面/Ctrl-C |

### 读线程而不是 select

最初用 `select.select([fd], ...)` 做非阻塞读，两个问题：

1. Windows 上 `select` 只能选套接字，管道直接抛错 —— 本地冒烟测试跑不起来；
2. `signal.SIGKILL` 在 Windows 上不存在，模块导入就崩。

改为「读线程 + `queue.Queue` + `None` 作 EOF 哨兵」，另加 `_HAS_KILLPG` 能力探测。
真机（Android）行为不变，本地也能测。

**如实说明的边界**：断连检测依赖「下次要写」。命令若一直安静，框架不知道
客户端已经走了，实际回收时间是 `idle` 秒。这就是 `idle` 默认不为 0 的原因，
也是 App 侧 `cancel()` 会额外调一次 `/api/stream/kill` 的原因。

---

## 4. App 内置终端

`lib/services/iwphone_service.dart`：

```dart
final ShellStream? s = await IwphoneService.instance.streamShell(
  'getevent -lt',
  idleSec: 120,
  maxSec: 1800,
);
await for (final ev in s.events) {
  if (ev.isOutput) append(ev.data);
  else if (ev.isExit) { /* ev.exitCode, ev.reason */ }
}
```

- 用 `dart:io` `HttpClient` + `response.transform(utf8.decoder).transform(LineSplitter())`，
  **零第三方依赖**。
- `cancel()` 关闭连接后还会 POST `/api/stream/kill`，回收是即时的。
- `terminal_screen.dart` 的渲染做了两件事：
  1. **120ms 节流**：输出先写进 `StringBuffer`，每 120ms 才同步成字符串并 `setState`。
     否则 `getevent` 每来一个 chunk 就重建 `SelectableText`，立刻卡成幻灯片。
  2. **上限 12 万字符**：超出只保留尾部一半并在首行标注，避免长跑 OOM。
- 「空闲超时」在顶部横幅右侧可点按切换（30 / 120 / 600 / 不限），
  因为不同命令合适的值差别很大（`getevent` 10 秒就够，`tail -f` 可能几分钟没动静）。
- 输入框右侧按钮在有命令运行时变成红色停止键。

---

## 5. iwsh（8539）

`BrokerShell` 新增 `/exec/stream`，把框架的 NDJSON **原样转发**：

```
iwsh> getevent -lt
```

- 校验沿用 `/exec` 的同一套（token → `IwshGrantStore.findByToken` → `valid()` 三元组复验）。
- 交互式 REPL **默认走流式**；一次性调用 `iwsh <cmd>` 仍走 `/exec`（省一次连接），
  想流式就加 `-s`：`iwsh -s logcat`。
- `HttpURLConnection.readTimeout = 0`（不限）：空闲判断交给框架的 `idle`，
  客户端再压一个总超时只会把长跑命令提前掐断 —— 那正是老通道的毛病。
- 客户端断开（Ctrl-C / 关终端）→ 写 socket 抛异常 → 立即 `POST /api/stream/kill`。
- 审计记录写成 `[iwsh·stream] <命令>`，带转发字节数与退出码
  （退出码从尾行 `{"type":"exit",...}` 里扒出来，不需要完整 JSON 解析）。

`IWPHONE_STREAM_IDLE` 环境变量可覆盖空闲超时（默认 300 秒，0 = 不限）。

### 5.1 不常驻，但要能唤醒

8539 监听随 App 进程存活。App 被回收后，持有缓存 token 的 iwsh 不会再发授权广播，
直连会 `ECONNREFUSED`。解决办法是**按需唤醒**而不是常驻后台：

- 有缓存 token → 发 `com.shellmgr.action.WAKE_SHELL`，Receiver 只调
  `BrokerShell.startServer()`，不弹窗、不签 token、不动授权表。
- 没有 token → 原有 `REQUEST_SHELL` 授权广播本来就会拉起进程并弹窗。
- 两条广播都带 `-f 0x20`（`FLAG_INCLUDE_STOPPED_PACKAGES`），
  应用被强制停止后仍能唤醒 —— 和 Magisk 一样：平时不常驻，但应用申请能力时必须响应。

客户端用 `waitReady()` 探真实的 `GET /token?nonce=<64 个 0>`（返回 404 即可），
而不是只探 TCP connect —— 真机上出现过「连得上但 handle 线程还没就绪」的窗口。
详见 `doc/iwsh_terminal.md §16`。

---

## 6. 第三方授权应用（ContentProvider）

`call()` 返回一个 Bundle，装不下持续输出，所以拆成两步 ——
**授权在 `call()` 里做（可以同步等弹窗），数据在 `openFile()` 里给**：

```java
Bundle r = resolver.call(uri, "stream.open", "logcat -v time", args); // args: idle / cwd
String sid = r.getString("streamId");
InputStream in = resolver.openInputStream(
        Uri.parse("content://com.shellmgr.shell_manager.broker/stream/" + sid));
// 读 NDJSON；要停就 resolver.call(uri, "stream.kill", sid, null) 或 in.close()
```

| 环节 | 做了什么 |
|---|---|
| `stream.open` | `identify()` → `authorize()`（弹窗）→ `frameworkAlive()` → 生成 96 位随机 sid → 登记，TTL 30 秒 |
| `openFile` | 取登记 → **校验 `Binder.getCallingUid()` == 登记 uid** → `createPipe()` → 起线程灌数据 |
| `stream.kill` | 未打开的撤登记；已打开的按 `runningIds` 调框架 `/api/stream/kill` |

安全边界：

- sid 是 96 位随机数，猜不到；且 `openFile` 再验一次 uid，别的应用拿到 sid 也打不开。
- 同一个 sid 只能打开一次（`pending.remove`），读完即废。
- 管道读端被关 → 写端抛 `BrokenPipe` → 顺手 kill 远端进程组。
- 并发上限与框架侧一致（8 条）。
- `openFile` 里**不弹窗**：授权只在 `stream.open` 发生一次，避免调用方拿到一个含义不明的 fd。

---

## 7. 验证记录（真机 `IFBYCQ89WGS4EIXC`，Android 13）

| 项 | 命令 | 结果 |
|---|---|---|
| `getevent` 实时输出 | `cmd=getevent -lt&idle=3` | 首块即返回 7 个输入设备枚举；3.038 秒后 `{"type":"exit","reason":"idle","code":-9}` |
| 持续输出 | `cmd=yes tick`，客户端 4 秒强断 | 逐块 flush 正常；断开后 `/api/streams` 为空、`ps` 无残留 |
| 空闲超时 | `cmd=sleep 10&idle=1` | 循环在 t=1.03s 判定 idle（调试日志确认），进程组被回收 |
| 空命令 / 黑名单 | `cmd=` | 400 `{"ok":false,"code":"BAD_CMD","msg":"命令为空"}` |
| b64 模式 | `printf '\xff\xfeABC'&b64=1` | `{"type":"out","b64":"//5BQkM="}` |
| iwsh 路由 | `/exec/stream?token=deadbeef` | `INVALID_TOKEN`（不是 `NO_METHOD`，说明确实走到了流式分支） |
| Provider 版本 | `content call --method version` | `version=3` |

**未在真机验证的部分（如实）**：`/exec/stream` 与 `openFile` 的**完整数据通路**需要
一个已授权的终端应用 / 客户端应用。测试机上的 `com.termux` 授权在本次改动前就已经失效
（`broker_store.xml` 里根本没有 `grants` 键），复验时会走 `GRANT_REVOKED` 分支并清掉陈旧记录。
重新在 App 里授权一次即可复测。

---

## 8. 改动清单

| 文件 | 改动 |
|---|---|
| `framework/webui/webui_server.py` | `check_command()` 抽出；`run_shell_stream()` / `kill_stream()` / `stream_count()`；`/api/shell/stream`、`/api/stream/kill`、`/api/streams`；`Handler` 增加 HTTP/1.0 的说明注释 |
| `lib/services/iwphone_service.dart` | `streamShell()` / `ShellStream` / `ShellStreamEvent` / `activeStreams()` |
| `lib/screens/terminal_screen.dart` | 改为流式执行：增量渲染、节流、停止键、空闲超时切换 |
| `lib/i18n/app_strings.dart` | 终端流式相关文案（中/英） |
| `android/.../BrokerShell.kt` | `/exec/stream` 直通 + 断连回收 + `[iwsh·stream]` 审计 |
| `android/.../BrokerProvider.kt` | `stream.open` / `stream.kill` / `openFile()` 管道；`API_VERSION` → 3 |
| `tools/iwsh/src/.../ShellLoader.java` | REPL 默认流式；`-s` 标志；`jsonInt()`；`IWPHONE_STREAM_IDLE` |
| `android/app/src/main/assets/iwsh.dex` | 重新编译 |
