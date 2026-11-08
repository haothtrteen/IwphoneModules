# rish 式终端接入 · 落地说明（v1.3.18）

对应设计稿：`iwphone_rish_design.html`（工作区根目录）。
参考素材：`shizuku_ref/rish.sh` + `rish_shizuku.dex`（用户提供的 Shizuku rish 工具包）。

**本文件记录的是已实现的代码，不是设计。**

---

## 1. 落地内容

| 位置 | 内容 |
|---|---|
| `android/app/src/main/assets/iwsh.sh` | 启动脚本：`app_process -Djava.class.path=iwsh.dex /system/bin --nice-name=iwsh com.shellmgr.shell.ShellLoader "$@"`；Android 14+ 自动 `chmod 400` dex |
| `android/app/src/main/assets/iwsh.dex` | 客户端（Java 标准库编译，零第三方依赖）：发广播请求授权 → 轮询一次性 token → 回环 HTTP 执行命令 → 回显 stdout/stderr |
| `tools/rish/src/.../ShellLoader.java` | dex 源码；`tools/rish/build.sh` 一键重新编译 |
| `BrokerShell.kt` | 广播接收器 `BrokerShellReceiver` + 回环服务 `127.0.0.1:8539` + 一次性 token 表（60s TTL、用过即废）；App 内部持有 WebUI 密钥转发 `/api/shell` |
| `BrokerPrompt.askTerminal()` | 终端会话确认弹窗（复用现有悬浮窗，新增通用文案模式） |
| `AdbBootstrap.grantOverlayViaAdb()` | 通过自持 adb 给自己授予 `SYSTEM_ALERT_WINDOW`；`startFramework()` 自启后自动补授权 |
| `AppAuthChannel` | 新增 `grantOverlayViaAdb` / `exportRish` 两个方法 |
| `app_auth_screen.dart` | 弹窗卡片按钮改为「优先 adb 自授权，失败才跳系统设置」；接入说明顶部新增「导出工具包」，导出 `iwsh.sh` + `iwsh.dex` 到 `getExternalFilesDir/rish/` |

## 2. 与原设计稿的差异（重要）

设计稿写的是 **广播回传 Binder + `Binder.getCallingUid()` 按应用授权**。真机探测发现两条前置在这台小米（22011211C / Android 13）上不成立：

- `ActivityThread.systemMain()` 会初始化系统 Resources，MIUI 的 `ThemeCompatibilityLoader` 读 `/data/system/theme_config/theme_compatibility.xml` 失败，进程 `Aborted`；
- 从 app uid 用 `am start` 被 `assertPackageMatchesCallingUid` 拒绝（模拟环境里包名仍是 `com.android.shell`）。

而已实证可用的是：`app_process` 加载 dex、`am broadcast --user 0`、回环 TCP、`appops set`。
所以实现改为：

```
终端 sh iwsh.sh <cmd>
  → app_process + iwsh.dex（纯 Java 标准库，不碰 hidden API）
  → /system/bin/am broadcast --user 0 -a com.shellmgr.action.REQUEST_SHELL --es nonce <n>
  → BrokerShellReceiver（goAsync 后台线程）→ 悬浮窗让用户确认
  → 确认后签发一次性 token，写到 /sdcard/iwphone/broker/<n>.token
  → dex 轮询读到 token → GET http://127.0.0.1:8539/exec?token=...&cmd=...
  → App 用私有 WebUI 密钥转发框架 /api/shell → 结果回显
```

**安全边界必须如实理解**：广播由 system_server 转发，接收器拿不到发送方 uid，因此这里
**不做按应用授权**。权限来自「用户当场确认的这一次会话」：token 一次性、60 秒 TTL，
WebUI 访问密钥始终只在 App 内部，不下发终端。这与 Shizuku「用户确认一次会话」等价，
但**不等价于** `Binder.getCallingUid()` 的按应用授权。需要按应用授权的场景仍走
`BrokerProvider`（ContentProvider 通道）。`BrokerShellReceiver` 导出且无权限保护，
但它只负责触发确认弹窗，不据此放行任何命令；nonce 有长度与字符集校验。

## 3. 悬浮窗自授权（回答「既然拿到 adb 了能不能自己给自己授权」）

**能，已真机验证**：`adb shell appops set com.shellmgr.shell_manager SYSTEM_ALERT_WINDOW allow`
执行成功后，`Settings.canDrawOverlays()` 立即变 true（`content call --method version`
的 `prompt` 从 `false` 变 `true`）。代码里封装为 `AdbBootstrap.grantOverlayViaAdb()`：

- 授权页「去开启」按钮优先调它，失败才跳系统设置页（部分 ROM 不给 shell
  `MANAGE_APP_OPS_MODES`，例如某些 ColorOS）；
- `startFramework()` 每次开机自启时，若检测到悬浮窗权限未开就自动补一次。

代价要说清楚：这等于 App 用 shell 权限给自己开了一个能覆盖其它应用的窗口。
属于用户主动选择开启「即时授权弹窗」后的自服务行为，默认不额外提权其它应用。

## 4. 使用方法

1. 安装 v1.3.18，打开 **授权 → 接入说明 → 导出工具包**，得到
   `.../Android/data/com.shellmgr.shell_manager/files/rish/` 下的 `iwsh.sh` 与 `iwsh.dex`。
2. 把这两个文件放进终端 App（Termux / MT 等）自己的私有目录。
3. 确保即时授权弹窗已开启（授权页顶部卡片，点一下即可由 adb 自授权）。
4. 终端里执行 `sh iwsh.sh id`（或别的命令）。首次调用弹出确认框，允许后返回结果。
5. token 用后即废；下次调用会再次请求确认。若需要长期免确认，应在 App 侧
   增开「记住本次终端会话」的显式开关（当前未实现，避免静默放大权限）。

## 5. 已验证 / 未验证

**2026-11-06 真机已验证（22011211C）：**

- `app_process` 从第三方 uid 10350 加载系统 dex 起 Java main 成功；
- `am broadcast --user 0` 成功；回环 TCP（curl + X-Token）能以 `uid=2000(shell)` 执行命令；
- `appops set ... SYSTEM_ALERT_WINDOW allow` 成功且立即生效；
- `content` CLI 从第三方 uid 被 `ACCESS_CONTENT_PROVIDERS_EXTERNALLY` 拒绝；
- `ActivityThread.systemMain()` 在 MIUI 崩溃；`am start` 从模拟 app uid 被拒。

**未验证（2026-11-08 设备未连接，本轮只做静态检查与打包）：**

- `iwsh.dex` 端到端跑通（广播 → 弹窗 → token → 8539 → `/api/shell` → 回显）；
- 公共目录 `/sdcard/iwphone/broker/` 能否被第三方 app 进程读取并删除 token 文件
  （App 侧有 `MANAGE_EXTERNAL_STORAGE`，读取端未测；代码里另有 App 外部私有目录兜底，
  但该目录在 Android 11+ 分区存储下其它 app 通常读不到）；
- 8539 端口在 MIUI 后台保活 / Doze 下的存活情况；
- `BrokerShellReceiver` 的显式广播是否被 MIUI 电池优化拦截（Shizuku rish 自己也提示过这个风险）；
- 悬浮窗确认弹窗在真机上的显示与点击；
- 与 Shizuku 同时启用的兼容性。

## 6. 真机验收清单（接上设备后按序做）

- [ ] 安装后启动 App，`content call --uri content://com.shellmgr.shell_manager.broker --method version` 返回 `version=2`；检查 8539 端口 LISTEN。
- [ ] 授权页顶部卡片显示「即时授权弹窗已开启」；若未开，点按钮后 `appops get` 变为 `allow`。
- [ ] 「导出工具包」生成两个文件，dex 魔数为 `dex\n037\0`、大小与 assets 一致。
- [ ] 把两个文件放进 Termux 私有目录，`sh iwsh.sh id` → 弹窗 → 允许 → 输出 `uid=2000(shell)`。
- [ ] 拒绝 / 超时时 dex 明确退出且不签发 token；token 二次使用返回 `INVALID_TOKEN`。
- [ ] 框架停止时返回明确错误码，不静默失败；WebUI 密钥不出现在终端脚本、dex 或 `ps` 输出。
- [ ] 回归：ContentProvider 的 `ping/request/exec`、底栏授权 tab、导出脚本、开机自启均不受影响。

## 7. 已知取舍

- 会话粒度是「一次调用一次确认」，不是交互式 REPL，也不是跨调用保持 cwd/env 的持久会话。
  这是有意的：设计稿里推荐的就是进程内会话，避免会话表 / TTL / 孤儿进程 / 输出粘连。
- 没有做按应用授权。若后续要把广播换成 Binder（真正拿 `getCallingUid()`），需要解决
  MIUI 上 `systemMain()` 崩溃的问题，或改走 `ServiceManager` + `IActivityManager` 反射。
- `BrokerShell` 的 HTTP 服务是单端口、每连接一线程、无 TLS（仅绑 127.0.0.1）。
  token 一次性 + 60s TTL 是主要防护；同设备其它 app 在 token 有效窗口内若能读到
  公共目录文件，理论上可抢先使用一次。接上真机后应优先验证并视情况收紧到
  「App 外部私有目录 + 用户在 App 内复制 token」的手动模式。
