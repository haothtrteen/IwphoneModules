# iwsh 终端接入 · 落地说明（v1.3.26）

对应设计稿：`iwphone_iwsh_design.html`（工作区根目录）。
参考素材：`shizuku_ref/rish.sh` + `rish_shizuku.dex`（用户提供的 Shizuku 终端工具包，
**第三方素材的真实文件名，刻意保持原名**，不参与本项目的命名统一）。

**本文件记录的是已实现的代码，不是设计。**

---

## 1. 命名统一（v1.3.19，v1.3.20 沿用）

导出目录统一为 **`iwsh`**，项目内所有自有命名同步替换。下表是替换后的覆盖清单：

| 类别 | 统一后的命名 |
|---|---|
| 导出目录 / 构建源目录 | `getExternalFilesDir/iwsh/`、`tools/iwsh/` |
| 落地文档 | `doc/iwsh_terminal.md` |
| 设计稿 | `iwphone_iwsh_design.html` |
| 通道 / 方法名 | `exportIwsh`（Kotlin、Dart、MethodChannel 字符串） |
| 文案键 | `auth.iwshHint` |
| `.gitignore` / Manifest / 脚本 / 注释 / 文档 | 全部统一为 iwsh |

**刻意保留的第三方引用**（改了就是误改第三方素材）：
`shizuku_ref/` 目录及其内容、文档里对 `rish.sh` / `rish_shizuku.dex` 的文件名引用、
设计稿里展示的 Shizuku 源码片段（`RISH_APPLICATION_ID`、`--nice-name=rish`、
`rikka.shizuku.shell.ShizukuShellLoader`、`/data/local/tmp/rish-shizuku-*`）。
构建产物、`libadb.so`、Python 运行时的 "Irish" 等无关内容未触碰。

## 2. 权限获取逻辑（v1.3.19 改造，v1.3.20 沿用）

### 选定方案：传递应用包名，为**整个应用**授权

两个候选里选了后者。理由：

- **方案 A（自动获取进程 id 随请求传递）不适合**：pid 每次启动都变，不能作为稳定
  授权主体；广播路径下 pid 由客户端自报，App 在 Android 的 `hidepid` 下也读不到
  其它进程的 `/proc/<pid>/status` 去核验，无法稳定生效。
- **方案 B（传递应用包名）与现有实现契合**：`BrokerStore` 本来就有
  「包名 + uid + 签名哈希」三元组模型，可直接复用 `sigHashOf()`；一次授权长期有效；
  对齐 Shizuku `RISH_APPLICATION_ID` 的做法；调用方式 `sh iwsh.sh <cmd>` 完全不变。

### 链路

```
导出工具包时：直接导出，iwsh.env 里是带注释的默认包名（用户自己改）
终端：sh iwsh.sh id
  → iwsh.sh source iwsh.env，导出 IWPHONE_APPLICATION_ID / IWPHONE_DIR
  → app_process + iwsh.dex（纯 Java 标准库，零 hidden API）
  → 先读工具包目录的 .iwsh_token 缓存；命中则直接执行
  → 未命中：am broadcast --user 0 -a com.shellmgr.action.REQUEST_SHELL
            --es nonce <n> --es pkg <终端应用包名>
  → BrokerShellReceiver：PackageManager 查包名 → uid / 签名 / 应用名
      → 悬浮窗显示「授权给 <应用名>（<包名>），整个应用长期有效」
      → 用户确认 → IwshGrantStore.grant() 写持久授权记录 + 签发 token
      → token 写到 /sdcard/iwphone/broker/<n>.token
  → dex 读到 token，缓存到 .iwsh_token（整个应用长期有效）
  → GET 127.0.0.1:8539/exec?token&cmd
      → 每次重新校验 (pkg, uid, sig) → App 用私有 WebUI 密钥转发 /api/shell
      → 回显 stdout/stderr
```

### 与 v1.3.18「一次会话」的差别

| | v1.3.18 | v1.3.19 |
|---|---|---|
| 授权主体 | 一次调用 | 整个应用（包名 + uid + 签名） |
| token | 一次性、60s TTL、用过即废 | 持久，绑定授权记录 |
| 弹窗 | 每次调用都要确认 | 首次确认，之后不再弹 |
| 失效条件 | 用完 / 超时 | 应用卸载、换签名、uid 回收、用户手动撤销 |
| 撤销入口 | 无 | 授权页「已授权的终端应用」列表 |

`INVALID_TOKEN` / `GRANT_REVOKED` 时 dex 会删除本地缓存并重新走授权流程，
因此旧的 `.iwsh_token` 不会造成卡死。

### 安全边界（如实）

广播由 system_server 转发，接收器拿不到发送方 uid，所以**这不是
`Binder.getCallingUid()` 级的按应用授权**。可信根是：

1. 客户端声明的包名 → App 用 `PackageManager` 确认它真实存在，取 uid 与签名；
2. 授权弹窗把**应用名 + 包名**显示给用户，由用户确认；
3. 每次执行重新校验三元组，变化即自动撤销。

伪造包名只能让弹窗显示别的应用，用户看得见并可以拒绝。按 Binder 身份的授权
仍走 `BrokerProvider`。WebUI 访问密钥始终只在 App 内部，不下发终端。

## 3. 悬浮窗自授权

真机验证 `adb shell appops set com.shellmgr.shell_manager SYSTEM_ALERT_WINDOW allow`
使 `Settings.canDrawOverlays()` 立即变 true。封装为 `AdbBootstrap.grantOverlayViaAdb()`，
`startFramework()` 自启时自动补授权；授权页按钮优先自授权、失败才跳系统设置。

## 4. 使用方法（调用方式未变）

1. 安装 v1.3.21，打开 **授权 → 接入说明 → 导出工具包**：**直接导出，不需要
   预先指定应用**。得到 `.../files/iwsh/` 下的 `iwsh.sh` 与 `iwsh.dex` 两个文件。
2. 两个文件放进终端 App 自己的私有目录；按 `iwsh.sh` 顶部注释把
   `IWPHONE_APPLICATION_ID` 改成该终端 App 的包名（默认 `com.termux`），
   也可用同名环境变量覆盖，无需改脚本。
3. 确保即时授权弹窗已开启（授权页顶部卡片，可一键由 adb 自授权）。
4. 终端里 **`sh iwsh.sh` 进入交互模式**（连续敲命令，`exit` / Ctrl-D 退出），
   或 `sh iwsh.sh id` 执行单条后退出。首次弹出确认框，允许后长期免确认。
5. 撤销：授权页「已授权的终端应用」→ 撤销，该应用下次调用会重新请求授权。

## 5. 落地文件

| 位置 | 内容 |
|---|---|
| `assets/iwsh.sh` | 启动脚本；包名写在顶部（env 已合并）、绝对路径定位 dex、完整性预检、无条件 `chmod 400` |
| `assets/iwsh.dex` | 客户端；源码 `tools/iwsh/src/.../ShellLoader.java`，`tools/iwsh/build.sh` 重编 |
| `BrokerShell.kt` | `BrokerShellReceiver` + `127.0.0.1:8539` + `IwshGrantStore`（持久授权表） |
| `BrokerPrompt.askTerminal(ctx,label,detail)` | 参数化确认弹窗，显示应用名与包名 |
| `AppAuthChannel` | `exportIwsh(pkg)` / `listIwshGrants` / `revokeIwshGrant` / `grantOverlayViaAdb` |
| `app_auth_screen.dart` | 导出按钮直接导出（提示改 `iwsh.sh` 顶部包名）；新增「已授权的终端应用」列表与撤销 |
| `lib/services/app_auth_service.dart` | `IwshGrant` 模型与三个通道方法 |

## 6. 验证结果

**静态 / 构建期（本轮全部通过）：**

- `flutter analyze` 零问题；中英文文案键对齐；`sh -n assets/iwsh.sh` 通过；
- `ShellLoader.java` 经 `javac` + `d8` 编译成 `iwsh.dex`（6140 字节）成功；
- release APK 构建通过，APK 内 `assets/iwsh.sh`、`assets/iwsh.dex`、
  `BrokerShellReceiver` 清单项校验通过；
- 命名残留扫描：项目内仅剩 `doc/iwsh_terminal.md` 对第三方文件名的引用，
  以及工作区 `shizuku_ref/` 素材；无旧命名的标识符、目录或字符串；
- 导出目录、通道名、文案键三处前后一致（`exportIwsh` ←→ `'exportIwsh'` ←→ `/iwsh/`）；
- `iwsh.env` 生成逻辑：包名经 `[A-Za-z0-9_.]+` 白名单校验，非法值回退
  `com.termux`；用 `bin.mt.termex` 实测过 `iwsh.env` 生成后由 `sh` source 能正确读出包名。

**真机接口探测（2026-11-08，设备 `2407FRK8EC` / Android 13，已装 v1.3.19）：**

- `content call ... --method version` → `Bundle[{prompt=true, ok=true, version=2, ...}]`，
  `BrokerShellReceiver` 在 `dumpsys package` 中注册、action 正确；
- 8539 回环服务监听正常（经 `adb forward` 从 PC 侧探测）：
  - 无效 token → `403 {"ok":false,"code":"INVALID_TOKEN"}`
  - 未知路径 → `404 {"ok":false,"code":"NO_METHOD"}`
  - 空命令 → `400 {"ok":false,"code":"BAD_CMD"}`
- `iwsh.dex` 经 base64 传到设备后 md5 与 assets 一致；`sh iwsh.sh id` 输出
  `[iwsh] 已请求授权（invalid.pkg.none）…`，证明 dex 被 `app_process` 正常加载、
  `iwsh.env` 的包名被正确读取并随广播发出；
- 用**不存在的包名**走拒绝分支：`am broadcast` 正常完成、无崩溃，
  `/sdcard/iwphone/broker/probe12345.token` **未生成**（`NO_TOKEN_AS_EXPECTED`），
  证明 `PackageManager` 校验与「不确认就不签发」生效。
- 探测用的临时文件与端口转发已清理。

**未执行（需人工在弹窗点确认，按验证习惯留给使用者）：** 弹窗确认 →
持久 token 签发 → 二次调用免弹窗 → 授权页撤销后旧 token 失效。
接上设备后按第 7 节清单验收这几步。

## 7. 真机验收清单

- [ ] `content call ... --method version` 正常；确认 8539 端口 LISTEN。
- [ ] 导出工具包（无需选应用），按注释把 `iwsh.sh` 顶部的包名改成自己的终端 App。
- [ ] 三个文件放进终端私有目录，`sh iwsh.sh id` → 弹窗显示正确应用名/包名
      → 允许 → 输出 `uid=2000(shell)`；同目录生成 `.iwsh_token`。
- [ ] 再执行一次 `sh iwsh.sh id -u`：**不再弹窗**，直接输出 `2000`。
- [ ] 授权页「已授权的终端应用」出现该应用；撤销后再次调用重新弹窗。
- [ ] 拒绝 / 超时 / 未开悬浮窗时不签发 token，dex 明确报错退出。
- [ ] WebUI 密钥不出现在脚本、dex、env 或 `ps` 输出；撤销后旧 token 返回
      `INVALID_TOKEN`。
- [ ] 回归：ContentProvider 的 `ping/request/exec`、底栏授权 tab、导出脚本、
      开机自启、悬浮窗自授权均不受影响。

## 8. 已知取舍

- v1.3.21 起提供交互式 REPL（`sh iwsh.sh` 无参数），`cd` 工作目录可在会话内保持；
  但每条命令仍是独立的 `sh -c`，**环境变量 / alias / shell 函数不保持**。
- 公共目录 `/sdcard/iwphone/broker/` 的可读性未在真机验证；App 侧另有
  App 外部私有目录兜底，但 Android 11+ 分区存储下其它 app 通常读不到，
  若真机发现失败，需改为「用户在 App 内复制 token」的手动模式。
- `BrokerShell` 的 HTTP 服务单端口、每连接一线程、无 TLS（仅绑 127.0.0.1）。
  token 持久后更应确保公共目录只被目标终端 app 读到；真机验收时优先确认这一点。


---

## 9. v1.3.20 修订（导出简化 + 启动健壮性）

### 9.1 澄清一次误判

排查过程中我在**未点击弹窗「允许」**的状态下测试，把 `am broadcast` 等待
`goAsync` 结束误读成「没弹窗」。实际上弹窗与授权流程本来是通的：用户点允许后
token 正常签发。因此**回退**了基于该误判加入的「接收器里临时用 adb 补悬浮窗权限」
逻辑；悬浮窗权限仍由授权页「去开启」按钮（adb 自授权）负责。

### 9.2 `Aborted` 的真实原因与修复

用户看到的 `line: N Aborted bash "$@"` 来自 ART 中止（`app_process` 加载 dex 失败），
不是授权逻辑。真机复现确认：把 dex 传成 1044 字节（截断版）会异常，完整的 dex 文件
在终端 App 私有目录、app uid 下可正常运行。三个加固：

- **绝对路径**：`BASEDIR=$(cd "$(dirname "$0")" && pwd)`，避免终端 App 的包装脚本
  改了 cwd 后按相对路径找不到 dex（`ClassNotFoundException` → Aborted）。
- **完整性预检**：`wc -c` 小于 1000 字节直接给中文错误「iwsh.dex 不完整，请重新
  导出工具包」，不再让 ART 吐一堆栈。
- **无条件 `chmod 400`**：不再依赖 `getprop`（部分终端环境取不到值）；FUSE 路径上
  改不动时明确提示「Android 14+ 会拒绝加载，请放到终端 App 私有目录」。

### 9.3 广播与回执

- 广播改为**显式指定组件** `-n com.shellmgr.shell_manager/.BrokerShellReceiver`，
  避免系统对隐式自定义广播的拦截（真机显式广播能触发接收器）。
- 客户端不再无限 `waitFor()`：`am broadcast` 会等接收器 `goAsync` 结束（最长 45s），
  改成 `waitFor(2, TimeUnit.SECONDS)` 后立刻进入 token 轮询，用户不点允许时也不会
  卡在广播回执上。

### 9.4 导出简化

按使用者要求，「导出工具包」**不再要求先选终端应用**，直接导出三件套；
`iwsh.env` 带注释说明如何改包名，用户自己按终端 App 修改即可。

### 9.5 真机验证（2026-11-08，`22011211C`）

- 从 `/` 目录用绝对路径调用 `sh <绝对路径>/iwsh.sh id` → 正常输出
  `[iwsh] 已请求授权（com.termux）…`，不再 Aborted。
- 把 dex 换成 4 字节损坏文件 → 输出
  `[iwsh] iwsh.dex 不完整（4 字节），请重新导出工具包`，无 ART 崩溃。
- 用不存在的包名走拒绝分支：请求提示**立刻**出现（不卡 `waitFor`），不签发 token；
  用户设备的悬浮窗权限保持原状（未被探测改动）。
- 探测用的临时目录已清理。
- 弹窗确认 → 持久 token → 二次调用免弹窗，仍按使用者习惯留其自行验收。


---

## 10. v1.3.21 修订（env 合并 + 交互式 REPL + 输出修复）

### 10.1 `.env` 合并进脚本

`iwsh.env` 取消，导出只剩 **`iwsh.sh` + `iwsh.dex` 两个文件**。包名写在
`iwsh.sh` 顶部（`: "${IWPHONE_APPLICATION_ID:=com.termux}"`），带注释说明
改成自己的终端 App 包名；同名环境变量仍可覆盖。`exportIwsh()` 不再生成 env 文件。

### 10.2 交互式 REPL（对齐 rish 的持续对话）

- `sh iwsh.sh`（无参数）→ 进入 `iwsh>` 提示符，连续读 stdin 执行，
  `exit` / `quit` / Ctrl-D 退出；`sh iwsh.sh <cmd>` 保持原来的单次执行。
- REPL 内每条命令复用**同一个持久 token**，不会重复弹窗。
- **`cd` 可保持**：客户端维护 cwd，`cd X` 时让框架执行 `cd X && pwd` 回读真实
  路径（能处理 `..` 与软链接），后续命令通过 `/exec?cwd=...` 带上工作目录。
  服务端 `BrokerShell.kt` 已把 `cwd` 透传到框架 `/api/shell`。
- 限制：每条命令仍是独立 `sh -c`，**环境变量、alias、shell 函数不跨命令保持**。

### 10.3 「执行完什么都没输出」的真实根因

框架返回的是 **带空格** 的 JSON：`{"ok": true, "stdout": "2000\n", ...}`，
而客户端的极简解析器只匹配 `"stdout":"..."`（无空格）→ 取不到 stdout，
旧 `print()` 又没有 stdout/stderr/msg 可显示 → 静默退出，看起来就是
「授权完输出几行日志就没了」。修复：

- `jsonField()` 跳过冒号后的空白再解析；
- `print()` 在无 stdout/stderr 时兜底打印 `code` / `msg` / 原始响应，
  不再出现「什么都不输出」。

用户贴出的 `[okhttp]` / `[com.mediatek.cta.CtaAdapter]` /
`ClassNotFoundException: com.mediatek.cta.CtaUtils` 是联发科 ROM 网络栈
在每次 HTTP 请求时注入的日志，**与 iwsh 无关、无害**，无需处理。

另外 `iwsh.sh` 的「仍可写」提示现在只在 SDK ≥ 34 且 getprop 取到值时输出，
避免 Android 13 上出现误导性警告。

### 10.4 真机验证（`22011211C`，用户已授权的 token 复用）

用 `printf 'id -u\npwd\ncd /sdcard\npwd\nexit\n' | sh iwsh.sh`：

```
iwsh · 交互模式   exit / Ctrl-D 退出   cd 可保持工作目录
2000
/
/storage/emulated/0
bye
```

`cd` 后 `pwd` 正确变为 `/storage/emulated/0`；单次调用 `sh iwsh.sh id -u`
仍输出 `2000`。测试用的是临时目录副本，未改动用户原始工具包与 token。


---

## 11. v1.3.22：ROM 噪声静默开关

### 11.1 噪声来自哪里（真机分离验证）

把 `sh iwsh.sh` 的 stdout / stderr 分别重定向到两个文件后确认：
`[okhttp]` / `com.mediatek.cta.CtaUtils` / `[OkHttp] sendRequest` 这些日志
**全部在 stdout**，stderr 是空的。因此 `2>/dev/null` 无效，
它们是联发科 ROM / 终端 App 在每次 HTTP 请求时往 fd 1 注入的，
与 iwsh 逻辑无关，也不影响执行结果。

### 11.2 方案

- dex 的**所有输出统一改写 `System.err`**（提示符、命令 stdout/stderr、
  `[iwsh]` 提示、错误兜底）。
- `iwsh.sh` 默认 `IWPHONE_SHOW_ROM_LOG=0`：
  ```sh
  exec 3>&1                     # 保存终端原始 stdout
  exec app_process ... 1>/dev/null 2>&3
  ```
  fd 1 的 ROM 噪声进 `/dev/null`，dex 的 stderr 经 fd 3 送回终端正常显示。
  不用管道 / grep，因此没有缓冲延迟，REPL 提示符仍然即时出现。
- 想看原始日志：把脚本里的 `IWPHONE_SHOW_ROM_LOG` 改成 `1`，或执行时
  `IWPHONE_SHOW_ROM_LOG=1 sh iwsh.sh`；此时不重定向，dex 输出仍在 stderr
  （终端照常显示），ROM 日志也会一起出现。

### 11.3 真机验证（`22011211C`，复用已授权 token）

默认：
```
iwsh · 交互模式   exit / Ctrl-D 退出   cd 可保持工作目录
iwsh> 1
iwsh> this-is-iwphone
iwsh> bye
```

`IWPHONE_SHOW_ROM_LOG=1` 时 `[okhttp]` / `[OkHttp] sendRequest` 等日志恢复出现。
两条命令输出正确、`exit` 正常退出。测试用临时副本，未改动用户工具包与 token。


---

## 12. v1.3.25：撤销授权必须让已缓存 token 立即失效

### 12.1 问题

授权页有两张互不相通的表：

| 表 | 通道 | UI 位置 | 撤销方法 |
|---|---|---|---|
| `BrokerStore` | ContentProvider (`content call`) | 「已授权的应用」 | `revoke` |
| `IwshGrantStore` | 回环 HTTP 8539 | 「已授权的终端应用」 | `revokeIwshGrant` |

iwsh 首次确认后把 token 缓存在工具包目录 `.iwsh_token`。之前撤销任一张表
都只删自己的记录，另一条通道的 token 仍有效；客户端拿着失效 token 时
既不删缓存也不重新授权，于是「撤销后下次执行还能直接用」。

### 12.2 三层联动（v1.3.25）

1. **统一撤销**：`BrokerStore.revoke(ctx, pkg)` 现在同时清
   `IwshGrantStore` 记录并 `BrokerShell.invalidate(pkg)`；
   `revokeAll` 同理清全表。授权页两个撤销入口都走这一条。
2. **双向登记**：`IwshGrantStore.grant()` 签发 token 时同步
   `BrokerStore.grant(ctx, pkg, uid, sig)`；`IwshGrantStore.valid()`
   再用 `BrokerStore.find(...)` 兜底校验，漏删也能拦住 8539 请求
   （返回 `INVALID_TOKEN` / `GRANT_REVOKED`）。
3. **客户端自清**：dex 收到 `INVALID_TOKEN` / `GRANT_REVOKED` 时
   删除 `.iwsh_token`，重新发广播请求授权；单次执行与 REPL 两条路径
   都处理，撤销后的下一次执行必须重新弹窗确认，不能静默继续。

UI 撤销确认文案同步写明「已缓存的终端工具包凭据也会立即失效」。

### 12.3 验证状态

静态验证：`flutter analyze` 零问题、Kotlin 编译与 `javac`+`d8` 编译 dex
通过、APK 1.3.25+155 构建通过。
**本轮设备未连接，撤销后的端到端闭环未做真机验收**，接上设备后按：
授权 → 撤销（两个入口各试一次）→ 再次 `sh iwsh.sh id -u` 应重新弹窗，
不点允许则明确报授权失败；直接拿旧 token 打 8539 应返回 403。


---

## 13. v1.3.26：收紧凭据落盘 + 调用审计（L0）

### 13.1 为什么「下发文件设 600」不能直接做

原先的 `/sdcard/iwphone/broker/<nonce>.token` 是 **App 进程写的**（属主 App uid），
客户端是另一个终端 App 的 uid。设 600 客户端就读不到；保持可读又会被
有 `MANAGE_EXTERNAL_STORAGE` 的其它应用扫走。两难。

**改成不落盘**：用户确认后把 token 挂在一个 256 位随机的**一次性 nonce** 上，
存在服务端内存（`pendingTokens`），客户端通过
`GET http://127.0.0.1:8539/token?nonce=<64hex>` 领取：

- nonce 由客户端生成，随显式广播传给 App（其它应用收不到该广播）；
- 60 秒 TTL、`remove` 一次即失效、格式 `[0-9a-f]{64}` 校验；
- 服务启动时清理旧版本遗留的 `/sdcard/iwphone/broker/*.token` 明文文件。

客户端缓存 `.iwsh_token`（**这个是客户端自己写的**）收紧到仅属主读写：
写缓存后收紧，读旧缓存时也顺手收紧一次，覆盖历史遗留的 660 文件。
注意 FUSE(`/sdcard`) 上 chmod 可能不生效，部署建议仍是把工具包放进
终端 App 私有目录。

### 13.2 调用审计

`/exec` 每次（成功 / `INVALID_TOKEN` / `GRANT_REVOKED`）都调
`BrokerStore.appendAudit(...)`，复用授权页已有的「调用记录」section，
命令摘要加 `[iwsh] ` 前缀便于识别。记录含 pkg、uid、命令（截断 200）、
结果码、退出码、耗时、输出长度；失效/伪造 token 也留痕，可据此发现扫描。

### 13.3 真机验证（22011211C）

- `/token?nonce=bad` → 400 `BAD_NONCE`；
  `/token?nonce=<64hex 随机>` → 404 `NO_PENDING_TOKEN`；
  `/exec?token=invalid` → 403 `INVALID_TOKEN`；
- 审计落库实测：`broker_store.xml` 出现
  `[iwsh] id -u / code=INVALID_TOKEN` 记录；
- 安装并重启 App 后 `/sdcard/iwphone/broker/` 旧明文文件被清空（total 0）；
- 未验证：完整"用户点允许 → /token 领到 token → .iwsh_token 变 600"
  需人工点弹窗；旧工具包 token 属已撤销的 `bin.mt.plus`，
  实测按预期删缓存并重新发起授权（旁证 v1.3.25 撤销联动生效）。

## 14. 关于 Shizuku / L2（评估，未落地）

**没有在这台设备上验证过 Shizuku 的完整链路。** 之前的「Shizuku 做法」
是基于 Binder 机制 + 用户提供的 `rish.sh` / `rish_shizuku.dex` 字符串推断，
不是实测结论。

从附件能确认的：`rish.sh` 用 `app_process` 起
`rikka.shizuku.shell.ShizukuShellLoader`；dex 里有
`rikka.shizuku.intent.action.REQUEST_BINDER`、`putBinder` / `readStrongBinder` /
`onTransact`、`RISH_APPLICATION_ID`、`getuid`、
`moe.shizuku.manager.shell.Shell`、`DexClassLoader`、
`/data/local/tmp/rish-shizuku-*`，以及「连接可能被电池优化阻断」的超时提示。

即：**广播请求 Binder → Shizuku manager 回传 IBinder → 后续调用全走 Binder
transact**。服务端可用 `Binder.getCallingUid()` 拿内核保证的调用方 uid，
身份来自 IPC 通道而非随请求携带的凭据——这是与当前「回环 HTTP + bearer
token」的本质差别。

值得借鉴的是**模型**（一次握手换会话句柄、授权依据用内核身份、服务端可撤销），
不是 API 本身。直接搬的障碍（均在本机实测过）：
`content` CLI 从 app uid 被 `ACCESS_CONTENT_PROVIDERS_EXTERNALLY` 拦；
`ActivityThread.systemMain()` 在 MIUI 崩于 `ThemeCompatibilityLoader`；
客户端是 app_process 纯 Java 进程，发广播取 result / 用 IBinder 都要碰
hidden API；且 rish 依赖已安装的 Shizuku manager 与已启动的 Shizuku 服务端，
我们没有这个前提。

**更贴近本项目的 L2 形态**是 `LocalSocket` + `SO_PEERCRED`
（`android.net.LocalSocket#getPeerCredentials()` 是公开 API，内核返回真实 uid，
不需要 hidden API），把 8539 换成 abstract unix socket，服务端比对
授权记录里的 uid。但 `untrusted_app` 之间不同 MLS category 能否连接抽象
socket 未验证，SELinux 可能拦。建议先做一个最小探针（App 起 socket + dex
连接 + 打印 peer uid），接上设备 10 分钟即可定性，再决定 socket 还是 Binder。

## 15. v1.3.27：流式命令（`/exec/stream`）

完整协议见 `doc/shell_streaming.md`。这一节只记 iwsh 侧的变化与理由。

### 15.1 改了什么

| 项 | 之前 | 现在 |
|---|---|---|
| REPL 每条命令 | `/exec`（一次性，必须等命令退出） | `/exec/stream`（边跑边回传） |
| 一次性调用 `iwsh <cmd>` | `/exec` | 不变；想流式加 `-s` / `--stream` |
| 读超时 | 70000ms 固定 | `0`（不限），空闲判断交给框架的 `idle` |
| 长跑命令 | 撞 60 秒总超时，输出被丢弃 | 只要还在输出就一直跑 |

### 15.2 为什么 REPL 直接换成流式，而不是"检测到长跑命令才切"

命令是不是长跑，客户端**事前不可能知道**：`logcat` 可以一次打印完就退出
（`logcat -d`），`ls` 也可以因为目录挂在慢速 FUSE 上跑很久。按命令名猜
（`getevent`/`logcat`/`top` 白名单）会带来两类误判，而且用户一改参数就失效。

流式通道对**短命令也没有坏处**：它输出完、进程退出，框架发 `exit` 就结束，
多出来的成本是一次连接（回环口，可忽略）。所以统一走流式，规则只有一条，
不会出现"有的命令能跑有的不能"。

一次性调用保留 `/exec` 是因为它在脚本里更常用（`iwsh id -u` 这种），
结果一次给全，客户端少解析一遍。

### 15.3 结束原因必须说出来

框架会在 `exit` 事件里带 `reason`。`idle`（空闲超时）和 `max`（30 分钟上限）
**不是命令自己退出**，如果静默收工，用户会以为命令跑完了。所以这两种情况
iwsh 会额外打一行说明：

```
[iwsh] 空闲超时，命令已停止（IWPHONE_STREAM_IDLE 可调，0 为不限）
```

`IWPHONE_STREAM_IDLE` 默认 300 秒。设 0 表示不限 —— 但这时若终端进程被强杀，
远端要靠框架的 30 分钟上限才会被回收。

### 15.4 非流事件的处理

通道提前拒绝时（黑名单 / 流数超限 / 框架没起）返回的是普通 JSON
（`{"ok":false,"code":…,"msg":…}`），不是 NDJSON 事件。早期 `print()` 只认
`stdout`/`stderr`，遇到这种情况什么都不打，用户体验是"执行完什么都没有"。
现在行内没有 `type` 字段时会退回打印 `msg` / `code`。

## 16. 按需唤醒：不常驻，但调用时必须能起来（v1.3.33）

### 16.1 实测前提

| 场景 | 实测结果 |
|---|---|
| App 被 `am force-stop` 后，`content call` 走 Provider | **自动拉起** App 进程，`version=3` 正常返回 |
| App 不在时，iwsh 连 8539 | `ECONNREFUSED`（curl rc=7） |
| App 被强停后，`am broadcast -f 0x20 … WAKE_SHELL` | 进程被拉起（PID 从 NONE 变成 13714） |

结论：只有 8539 这一条链路需要额外处理，Provider 通道**本来就会按需拉起进程**，
不需要保活。WebUI 是独立的 Python 进程，App 不在时也照常运行。

### 16.2 为什么不做"隐藏后台保活"

- Android 8+ 后台限制 + HyperOS 的进程管理，"隐藏常驻"不可靠；
  唯一合规方式是前台服务，但通知栏条目**藏不掉**，换来常驻耗电。
- `android:persistent="true"` 需要系统签名 / priv-app，普通安装拿不到。
- AlarmManager / JobScheduler 是分钟级，做不到"调用即响应"。
- 流式命令的生命周期本来由框架管：App 死了管道断开，框架靠断连检测 + 空闲超时
  回收进程组，不需要 App 活着兜底。

### 16.3 选的方案：Magisk 式按需唤醒

客户端发一条**轻量广播** `com.shellmgr.action.WAKE_SHELL`，接收器里只调
`BrokerShell.startServer()`：不弹窗、不签 token、不动授权表。然后重试 8539。

```
iwsh 启动
  ├─ 本地没有缓存 token → obtainToken() 发 REQUEST_SHELL（本来就会拉起进程 + 弹窗）
  └─ 已有缓存 token    → ensureBroker() 发 WAKE_SHELL → waitReady(3000) → 连 8539
```

两条广播都带 `-f 0x20`（`FLAG_INCLUDE_STOPPED_PACKAGES`）：即便应用被用户
强制停止进入 stopped 状态，这一次调用仍能唤醒它。理由是要跟 Magisk 一致 ——
**平时不常驻没问题，但应用来申请能力时必须能给出响应**：
- 有缓存 token：唤醒后直接放行（仍需 token 三元组校验）；
- 没有 token：授权广播必须送到用户眼前，形成明确的允许/拒绝，
  不能因为 stopped 状态把请求吞掉、让用户看到"点了没反应"。

### 16.4 一个踩过的坑：只探 TCP 端口不够

第一版 `waitPort()` 只做 `Socket.connect(127.0.0.1:8539)`。真机上出现过
"TCP 连得上、`handle()` 线程却还没进入读循环"的窗口，curl 卡到超时退出，
netstat 上留下一排 `CLOSE_WAIT`。

改成 `waitReady()`：探一个真实的 `GET /token?nonce=<64 个 0>`。这个 nonce
格式合法但绝不会命中待领取 token（返回 404 `NO_PENDING_TOKEN`），**拿到 HTTP
响应才算服务就绪**。最多等 3 秒。

### 16.5 边界

- 唤醒本身不需要授权，8539 上的每条命令仍然走 `IwshGrantStore.valid()` 三元组复验。
- 唤醒广播是导出的、无权限保护；`am broadcast -f 0x20` 任何应用都能发。
  能造成的最大影响是"把 8539 监听叫起来"，不改变任何授权状态，不构成提权。
- 如果用户长期不用 iwsh，App 进程仍会被系统回收；下次用会再唤醒一次，
  延迟约 0.3~3 秒。

### 16.6 改动文件

| 文件 | 改动 |
|---|---|
| `BrokerShell.kt` | 新增 `ACTION_WAKE`；Receiver 增加唤醒分支（先于授权分支，不弹窗） |
| `AndroidManifest.xml` | Receiver intent-filter 增加 `WAKE_SHELL` |
| `ShellLoader.java` | `ensureBroker()` / `waitReady()`；两条广播都加 `-f 0x20`；`ConnectException` 给出明确提示 |
| `iwsh.dex` | 重新编译 |
