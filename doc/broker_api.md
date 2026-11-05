# 应用授权通道（broker）v2

让**其他应用**经 Shell Manager 以 `shell`（uid 2000）身份执行命令 —— 能力等价于
Shizuku 的「adb shell 代理」。

- 授权项：`content://com.shellmgr.shell_manager.broker`
- 协议版本：`2`
- 管理入口：Shell Manager → 设置 → 权限 → 应用授权

**v2 变化**：从「先登记、事后批准」改成 **请求即确认** —— 未授权应用发起调用时
当场弹出「允许 / 拒绝」对话框（Magisk 式），用户点完才继续执行。

---

## 1. 为什么是 ContentProvider

| 方案 | 结论 |
|---|---|
| 框架开 abstract Unix socket + `SO_PEERCRED` | 客户端在 `untrusted_app` 域、服务端在 `shell` 域，AOSP 默认策略没有 `connectto` 规则 → `EACCES`；且授权需要界面，框架是 shell 脚本没有 UI |
| 回环 HTTP（框架的 `/api/shell`） | 拿不到调用方身份，无法按应用授权 |
| Service + Messenger | Handler 里 `Binder.getCallingUid()` 已失效（异步投递） |
| **ContentProvider `call()`** | 同步执行在 Binder 线程上，`getCallingUid()` 是真实调用方；客户端接入成本低；跨应用 provider 调用走标准 Binder，不受 SELinux 域限制 |

授权点在 **App**，不在框架：框架只负责「以 shell 身份跑命令」，App 负责「谁能让它跑」。

## 2. 请求即确认：悬浮窗弹窗

Android 10 起禁止后台进程启动 Activity。broker 被动被调起时本应用几乎必然在后台，
`startActivity` 会被系统静默丢弃，所以**不能用普通 Activity 弹窗**。

Magisk / Shizuku 的做法是 **SYSTEM_ALERT_WINDOW 悬浮窗**：它不是 Activity，属于系统
明确允许的后台显示界面通道。本项目同样用 `TYPE_APPLICATION_OVERLAY` 画一个对话框，
provider 的 Binder 线程 `CountDownLatch.await()` 等用户点完，再继续执行或拒绝 —— 与
`su` 卡住等用户点允许是同一个体验。

| 弹窗行为 | 结果 |
|---|---|
| 「允许」+ 勾选记住此选择 | 写入授权表，长期有效，后续不再弹 |
| 「允许」+ 不勾选 | 只放行**本次调用**，不落盘 |
| 「拒绝」+ 勾选 | 写入永久拒绝表，以后直接拒、不再弹（可在授权页解除） |
| 「拒绝」+ 不勾选 | 本次拒绝，60 秒冷却 |
| 45 秒无人处理 | 自动按拒绝处理，释放 Binder 线程 |
| 同一应用重复调用 | 共用同一个弹窗与决定，不重复弹 |
| 超过 3 个应用同时等授权 | 返回 `PROMPT_BUSY` |

**降级**：悬浮窗权限必须用户到系统设置手动开（`Settings.ACTION_MANAGE_OVERLAY_PERMISSION`），
不能运行时弹窗授予。没开时 `BrokerPrompt.ask()` 返回 `NO_UI`，自动回落到 v1 的
「待授权列表 + `NEED_APPROVAL`」—— 功能不中断，只是没有即时弹窗。

## 3. 身份与状态

身份 = **包名 + uid + 签名哈希**（签名证书 SHA-256 前 32 个十六进制字符）。
单看包名会被抢注，单看 uid 会被系统回收复用；三者任一变化都视为「换了人」，
授权与「永久拒绝」记录都自动失效。

状态存于 App 私有 SharedPreferences（三份 JSON 数组 + 一份拒绝表）：

| 表 | 内容 |
|---|---|
| `grants` | 包名 / uid / 签名 / 授予时间 / 最近使用 / 调用次数 |
| `pending` | 降级模式下的待授权请求（10 秒节流、上限 20 条） |
| `denied` | 永久拒绝（解除后恢复弹窗） |
| `audit` | 调用记录（上限 300 条，命令截断 200 字符） |

每次调用都重新读盘校验，撤销即时生效。授权是二元且长期有效的：无 TTL、无分级、
无按应用的命令白名单。provider **不暴露 grant 方法** —— 写授权表只能经本应用界面，
第三方无法给自己发权限。

## 4. 客户端接入

### 4.1 声明可见性（Android 11+，Java/Kotlin 调用必需）

```xml
<queries>
    <provider android:authorities="com.shellmgr.shell_manager.broker" />
</queries>
```

### 4.2 Java / Kotlin

```java
Uri uri = Uri.parse("content://com.shellmgr.shell_manager.broker");

// 只请求授权、不执行命令。未授权时会弹窗并阻塞到用户决定
Bundle req = getContentResolver().call(uri, "request", "", null);

Bundle extras = new Bundle();
extras.putInt("timeout", 30);              // 1~60 秒
extras.putString("cwd", "/data/local/tmp");

Bundle r = getContentResolver().call(uri, "exec", "id", extras);
if (r != null && r.getBoolean("ok")) {
    int exit = r.getInt("exitCode");
    String out = r.getString("stdout");
}
```

### 4.3 纯终端 shell（用户要求示例）

终端类应用（Termux 之类）不需要集成任何库，用系统自带的 `content` 命令行工具即可。
它继承终端应用的 uid，所以身份识别、弹窗、授权表与 Java 调用完全一致。

```sh
# ① 只请求授权，不执行命令 —— 未授权时当场弹窗，允许后返回 granted=true
content call --uri content://com.shellmgr.shell_manager.broker \
             --method request --arg ""

# ② 直接执行命令 —— 未授权时同一条调用先弹窗，允许后立刻执行并回显结果
content call --uri content://com.shellmgr.shell_manager.broker \
             --method exec --arg "id"

# ③ 查状态：granted / denied / promptReady / frameworkUp
content call --uri content://com.shellmgr.shell_manager.broker \
             --method ping --arg ""

# ④ 带超时参数（extras 用 --extra 传）
content call --uri content://com.shellmgr.shell_manager.broker \
             --method exec --arg "getprop ro.build.version.release" \
             --extra "timeout:i:30"
```

要点：

- `request` 和 `exec` 都会**同步阻塞**到用户点按钮或 45 秒超时，这是预期行为，
  不要在 UI 线程上调用；
- `content call` 的返回以 Bundle 文本形式打印（不同系统版本格式略有差异），
  `ok=false` 时重点看 `code` 与 `msg`；
- 前提是 Shell Manager 已开启「显示在其他应用上层」权限，否则不会弹窗，
  只会返回 `NEED_APPROVAL` 并登记到「待授权」列表；
- **待真机验证**：Android 11+ 的包可见性过滤对 `app_process` 启动的 `content`
  二进制如何归属尚未实测。若被拦（报 Unknown URL / 返回 null），改用应用内
  `ContentResolver.call()` 并在 manifest 声明上面的 `<queries>`；
  从 `adb shell`（uid 2000）发起会因反查不到普通应用包名而被拒。

## 5. 方法

| method | arg | extras | 返回 |
|---|---|---|---|
| `version` | — | — | `version`, `authority`, `prompt`（悬浮窗是否可用） |
| `ping` | — | — | `uid`, `package`, `granted`, `denied`, `promptReady`, `frameworkUp` |
| `request` | 任意（建议空） | — | `granted`, `code`, `once`, `msg`；未授权时触发弹窗 |
| `exec` | 命令字符串 | `timeout`(Int), `cwd`(String) | `exitCode`, `stdout`, `stderr`, `elapsedMs`, `msg` |

`ping` 与 `version` 不需要授权（不执行任何命令），适合客户端启动时的能力探测。

## 6. 结果码

失败时 `ok=false`，另有 `code` 与 `msg`。

| code | 含义 | 客户端该做什么 |
|---|---|---|
| `ALREADY` / `GRANTED` | 已有授权 / 用户刚点了允许并已记住 | 正常继续 |
| `ONCE` | 用户只允许本次 | 别缓存授权，下次还会弹 |
| `DENIED` | 用户永久拒绝 | 引导用户到 应用授权 → 已拒绝 解除 |
| `DENIED_ONCE` | 本次拒绝 | 60 秒后可重试 |
| `DENIED_COOLDOWN` | 处于拒绝冷却期 | 稍后重试 |
| `PROMPT_TIMEOUT` | 弹窗 45 秒无人处理 | 重试 |
| `PROMPT_BUSY` | 并发弹窗过多 | 稍后重试 |
| `NEED_APPROVAL` | 降级模式：没开悬浮窗权限，已登记待授权 | 提示用户去授权页点允许或开启弹窗 |
| `FRAMEWORK_DOWN` | iwphone 框架没在运行 | 提示用户先启动框架 |
| `NO_TOKEN` | 本应用没配置访问密钥 | 提示用户到 设置 → 访问密钥 补一个 |
| `REJECTED` | 框架侧拒绝（黑名单 / 超时） | 看 `msg` |
| `EMPTY_CMD` / `TOO_LONG` / `UNKNOWN_CALLER` / `NO_METHOD` | 参数错误 | 修代码 |
| `HTTP_xxx` / `IO_ERROR` | 与框架通信失败 | 重试或检查框架状态 |

## 7. 已知边界

- **未设置访问密钥时授权可被绕过**。框架 `/api/shell` 在空密钥时放行，任何有网络权限的
  应用都能直接打 `127.0.0.1:8537`；而 broker 在空密钥时反而返回 `NO_TOKEN`。
  授权页会对这种情况显示橙色警告。彻底修复需改框架侧鉴权（会打破「密钥可选」的产品决策）。
- **投递脚本通道默认开启**（`CONTROL_ADBSH=1`），能写 `/sdcard/iwphone/` 的应用也能让
  框架以 shell 身份执行，同样不查授权表。
- **执行依赖框架运行中**；App 自身的 adb 通道没有拿来做兜底。
- **不限制命令内容**，只复用框架的 `COMMAND_BLACKLIST`；单次最长 60 秒、命令 ≤4096
  字符、stdout/stderr 各截断 20000 字符，且是**一次性非交互命令**（无 tty、无持续会话）。
- **悬浮窗权限**在小部分 ROM 上可能被额外拦截，即便 `canDrawOverlays` 返回 true；
  此时 `addView` 失败也会回落到降级模式。
- **调用记录**最多 300 条，命令只存前 200 字符。
