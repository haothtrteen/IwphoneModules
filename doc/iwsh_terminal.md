# iwsh 终端接入 · 落地说明（v1.3.21）

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
