# 应用授权通道（broker）v1

让**其他应用**经 Shell Manager 以 `shell`（uid 2000）身份执行命令 —— 能力等价于
Shizuku 的那个「adb shell 代理」。

- 授权项：`content://com.shellmgr.shell_manager.broker`
- 协议版本：`1`
- 管理入口：Shell Manager → 设置 → 应用授权

---

## 1. 为什么是 ContentProvider

一开始考虑过让框架（跑在 shell 身份下）开一个 abstract Unix socket，客户端连上来，
框架用 `SO_PEERCRED` 取 uid。这条路走不通：

| 方案 | 问题 |
|---|---|
| Unix socket + `SO_PEERCRED` | 客户端在 `untrusted_app` 域、服务端在 `shell` 域，AOSP 默认策略没有 `allow untrusted_app shell:unix_stream_socket connectto`，直接 `EACCES`。而且**就算连通也没用**：授权要问用户，框架是 shell 脚本没有界面，最后还得转回 App |
| 回环 HTTP（框架的 `/api/shell`） | 通是通，但拿不到调用方身份 —— 谁都可能是请求方，无法按应用授权 |
| Service + Messenger | Handler 里 `Binder.getCallingUid()` 已经失效（消息是异步投递的），拿不到真实调用方 |
| **ContentProvider `call()`** | `call()` 同步执行在 Binder 线程上，`getCallingUid()` 就是真实调用方；客户端一行代码接入；跨应用 provider 调用走标准 Binder，不受 SELinux 域限制 |

所以授权点在 **App**，不在框架。框架只负责「以 shell 身份跑命令」，App 负责
「谁能让它跑」。

```
┌─────────┐  ContentResolver.call()   ┌──────────────────┐  HTTP /api/shell  ┌──────────┐
│ 客户端  │ ────────────────────────► │  Shell Manager   │ ────────────────► │  iwphone │
│ (任意App)│ ◄──────────────────────── │ BrokerProvider   │ ◄──────────────── │  (shell) │
└─────────┘   Bundle(stdout/exit)     └──────────────────┘     JSON           └──────────┘
                                       uid → 包名→ 签名 → 授权表
```

## 2. 身份 = 包名 + uid + 签名

单看包名不够（包名可被抢注），单看 uid 更不够（卸载后 uid 会被系统回收给新包）。
三者一起校验，任一变化都视为「换了人」，授权自动作废并重新走审批。

界面上显示的「签名」是签名证书的 SHA-256 前 32 个十六进制字符，用来让用户核对
是不是同一个开发者。

## 3. 客户端接入

### 3.1 声明可见性（Android 11+ 必需）

```xml
<queries>
    <provider android:authorities="com.shellmgr.shell_manager.broker" />
</queries>
```

不声明的话，`ContentResolver` 找不到这个 provider，会抛
`IllegalArgumentException: Unknown URL`。

### 3.2 调用

```java
Uri uri = Uri.parse("content://com.shellmgr.shell_manager.broker");

// 可选参数：timeout（1~60 秒，默认 15）、cwd（工作目录）
Bundle extras = new Bundle();
extras.putInt("timeout", 30);
extras.putString("cwd", "/data/local/tmp");

Bundle r = getContentResolver().call(uri, "exec", "id", extras);
if (r == null) return;

if (!r.getBoolean("ok")) {
    String code = r.getString("code");
    String msg  = r.getString("msg");
    // NEED_APPROVAL 表示用户还没授权 —— 引导用户打开
    // Shell Manager → 设置 → 应用授权 → 待授权 → 允许
    Log.w(TAG, code + ": " + msg);
    return;
}

int    exitCode = r.getInt("exitCode");
String stdout   = r.getString("stdout");   // 已截断到 20000 字符
String stderr   = r.getString("stderr");
int    elapsed  = r.getInt("elapsedMs");
```

Kotlin 版本：

```kotlin
val r = contentResolver.call(
    "content://com.shellmgr.shell_manager.broker".toUri(), "exec", "id", null
) ?: return
if (r.getBoolean("ok")) println(r.getString("stdout"))
```

## 4. 方法

| method | arg | extras | 返回 |
|---|---|---|---|
| `version` | — | — | `version`, `authority` |
| `ping` | — | — | `version`, `uid`, `package`, `granted`, `frameworkUp` |
| `exec` | 命令字符串 | `timeout`(Int), `cwd`(String) | `exitCode`, `stdout`, `stderr`, `elapsedMs`, `msg` |

`ping` 不需要授权即可调用（它不执行任何命令），适合客户端启动时探测
「用户在不在、授权了没、框架跑没跑」。

## 5. 结果码

失败时 `ok=false`，另有 `code` 与 `msg`：

| code | 含义 | 客户端该做什么 |
|---|---|---|
| `NEED_APPROVAL` | 还没授权（请求已记进「待授权」列表） | 提示用户去 Shell Manager 授权，稍后重试 |
| `FRAMEWORK_DOWN` | iwphone 框架没在运行 | 提示用户先启动框架 |
| `NO_TOKEN` | 本应用没配置访问密钥，调不动框架 | 提示用户在 设置 → 访问密钥 补一个 |
| `REJECTED` | 框架侧拒绝（命中命令黑名单 / 超时） | 看 `msg` |
| `EMPTY_CMD` / `TOO_LONG` | 参数不合法 | 修参数 |
| `UNKNOWN_CALLER` | 无法从 uid 反查包名/签名 | 少见，通常是 uid 被复用中的竞态 |
| `NO_METHOD` | 方法名写错 | 修代码 |
| `HTTP_xxx` / `IO_ERROR` | 与框架通信失败 | 重试或检查框架状态 |

## 6. 为什么首次调用不弹窗

Android 10 起禁止后台进程启动 Activity。客户端来请求授权时，本应用十有八九在后台
（用户正用着那个客户端），`startActivity` 会被系统**静默丢弃**，弹窗根本出不来。

所以和 Shizuku 一样采用「列表批准」：未授权的调用只返回 `NEED_APPROVAL` 并落一条
待授权记录，用户自己打开 Shell Manager 点「允许」。这既不依赖后台启动 Activity，
也不依赖通知权限。

## 7. 已知边界

- **执行依赖框架运行中**。App 自身的 adb 通道没有拿来做兜底 —— 两条链路
  （框架 WebUI / 自带 adb）同时暴露会让「到底谁在跑」变得难以排查。
- **未设置访问密钥时本页的授权控制可被绕过**。框架的 `/api/shell` 在无密钥时放行，
  任何应用都能直接打 `127.0.0.1:8537`。授权页检测到这种情况会显示橙色警告。
  彻底解决需要框架侧「没有密钥就拒绝」，属于独立改动（会破坏「密钥可选」的产品决策）。
- **不限制命令内容**，只复用框架的 `COMMAND_BLACKLIST`。被授权 = 完整的 shell 权限，
  这本来就是本功能的目的，界面上也如实写明了。
- **单次命令最长 60 秒**、输出各截断到 20000 字符。不适合长任务。
- **调用记录**最多保留 300 条，其中命令只存前 200 字符。
