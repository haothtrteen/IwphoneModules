# 插件系统落地开发计划

> 性质：**开发执行清单**（不是设计稿）。本轮只写文档，未改任何运行代码。
>
> 设计依据：`C:\Users\admin\WorkBuddy\2026-09-16-19-58-15\ShellManager_插件化完善方案.md`
> 第 13 节（vFlow 机制提炼），落地时以该节为准。
> 参考源码：`reference_projects/vFlow`（GPL-2.0-or-later，**只读参考，不搬代码**）。

---

## 1. 开发前准备

| 项 | 现状 / 要求 |
|---|---|
| 分支 | `main`，当前 `ff19339`，已与 origin 同步 |
| 项目路径 | `F:\flutter\shell_manager_app` |
| Dart 侧 | `flutter analyze` 必须零问题 |
| Kotlin 侧 | 零第三方依赖；不用 EventBus/GreenRobot，复用现成 `android.net`、`java.net` |
| 工具链 | Flutter 在 PATH；JDK `F:/jdk21/jdk-21.0.12.1+1`；如需重编 dex 用 build-tools 34 的 d8 |
| Git push | 必须带代理证书参数（见第 9 节） |
| 参考项目 | `reference_projects/{Ruto-GLM,Open-AutoGLM,Shizuku,VirtualApp,vFlow}` |

**每次提交前必做**：`flutter analyze` + 检查改动文件无 NUL 字节（历史上多次被写坏）。

---

## 2. 阶段总览与依赖

```
P0 事件总线 + 状态机（纯内部）
      │
      ├── P1 能力契约 + 权限网关收敛
      │         │
      │         └── P2 无障碍 / MediaProjection 能力
      │                   │
      └───────────────────┴── P3 自动化编排（依赖 P0 事件质量）
                                    │
                                    └── P4 可选外部能力（Shizuku / 虚拟屏）
```

- **P0 不碰权限、不动 UI 主流程**，先在日志页展示事件，观察误报率。
- **P3 不能先于 P0**：vFlow 的触发器全靠 `TriggerSpec` + 事件分发，事件不稳则编排必乱。
- 每阶段独立可回滚，一次提交一个阶段。

---

## 3. 接口冻结清单（开发中不要随意改）

以下签名是各阶段共用的契约，先冻结：

```kotlin
// ---- 事件：SharedFlow 语义，即时、无 replay、无 sticky ----
data class PlatformEvent(
    val id: String,                 // "framework" / "module:<名>" / "script:<id>"
    val kind: String,               // state | action | audit | error
    val from: String? = null,
    val to: String? = null,
    val reason: String = "",
    val severity: String = "info",  // info | warn | error
    val ts: Long = System.currentTimeMillis(),
    val payload: Map<String, String> = emptyMap(),
)

object PlatformEventBus {
    private val _events = MutableSharedFlow<PlatformEvent>()
    val events: SharedFlow<PlatformEvent> = _events.asSharedFlow()
    suspend fun publish(e: PlatformEvent)
    fun tryPublish(e: PlatformEvent): Boolean   // 非挂起场景（Receiver/回调）
    fun subscribe(idPrefix: String): Flow<PlatformEvent>
}

// ---- 状态机：6 态 + COOLING / MAX_REACHED ----
enum class MonitorState {
    UNKNOWN, STARTING, RUNNING, DEGRADED, COOLING, MAX_REACHED, ERROR, STOPPED
}

// ---- 监视器契约（按需启停） ----
interface MonitorPlugin {
    val id: String
    val subject: String
    val defaultIntervalMs: Long
    val requiredCapability: String?    // 缺失则 SUSPENDED
    fun onRegister(ctx: Context, bus: PlatformEventBus)
    fun probe(ctx: Context): ProbeResult
    fun startListening(ctx: Context)   // 首个订阅者加入时
    fun stopListening(ctx: Context)    // 最后订阅者离开时
    fun recover(ctx: Context, from: MonitorState): RecoveryResult?
    fun onUnregister(ctx: Context)
}

// ---- 触发器 DTO 与增量更新 ----
data class TriggerSpec(
    val triggerId: String,             // "${ownerId}:${stepId}"
    val type: String,                  // 插件 id，定义层与运行层唯一连接键
    val parameters: Map<String, Any?>,
)
data class TriggerDelta(
    val ownerId: String,
    val removed: List<String>,         // triggerId
    val added: List<TriggerSpec>,
)
interface TriggerHandler {
    fun start(ctx: Context)
    fun stop(ctx: Context)
    fun addTrigger(ctx: Context, t: TriggerSpec)
    fun removeTrigger(ctx: Context, triggerId: String)
}
abstract class ListeningTriggerHandler : TriggerHandler {
    protected val active = CopyOnWriteArrayList<TriggerSpec>()
    final override fun addTrigger(...)  { /* 首个加入 → startListening */ }
    final override fun removeTrigger(...){ /* 最后离开 → stopListening */ }
    abstract fun startListening(ctx: Context)
    abstract fun stopListening(ctx: Context)
}

// ---- 插件注册：必须支持 trigger/monitor 工厂 ----
enum class PluginKind { CAPABILITY, MONITOR, AUTOMATION, TRIGGER, ACTION }
data class PluginManifest(
    val id: String,
    val kind: PluginKind,
    val version: Int,
    val permissions: List<PermissionSpec>,
    val minAppVersion: Int,
)
object PluginRegistry {
    fun register(m: PluginManifest, factory: () -> Plugin)
    fun factories(kind: PluginKind): List<() -> Plugin>
}

// ---- 能力：权限按请求动态声明 ----
data class PermissionSpec(
    val id: String,
    val type: PermissionType,          // RUNTIME | SPECIAL
    val description: String,
    val runtimePermissions: List<String> = emptyList(),
)
interface Capability {
    val id: String
    fun availability(ctx: Context): Availability   // AVAILABLE/NEED_GRANT/UNSUPPORTED/EXTERNAL_DEP
    fun getRequiredPermissions(req: ActionRequest?): List<PermissionSpec>
    fun execute(req: ActionRequest, cb: (ActionResult) -> Unit)
}

// ---- 自动化生命周期 ----
enum class ScriptState {
    INSTALLED, ENABLED, ARMED, TRIGGERED, RUNNING, SUCCESS,
    FAILED, SKIPPED, BLOCKED, DISARMED, DISABLED, UNINSTALLED
}
```

---

## 4. P0：事件总线 + 状态机

**目标**：纯内部机制，不改权限、不改主流程，日志页可见事件。

### P0.1 `PlatformEventBus`

| 项 | 内容 |
|---|---|
| 新增 | `android/app/src/main/kotlin/com/shellmgr/shell_manager/plugins/PlatformEventBus.kt` |
| 要点 | `MutableSharedFlow`（无 replay/extraBuffer）；`tryPublish` 供 Receiver 用；`subscribe(prefix)` 按 id 前缀过滤 |
| 对接 | `AutostartChannel` 注册 `EventChannel("shellmgr/events")`；Flutter 侧 `lib/services/platform_event_service.dart` 暴露 `Stream<PlatformEvent>` |
| 验收 | 发布 100 条事件无丢失（同步 collect）；无订阅者不崩溃；Flutter 能收到并能 dispose |

### P0.2 `MonitorRegistry` 与状态机

| 项 | 内容 |
|---|---|
| 新增 | `plugins/MonitorRegistry.kt`、`plugins/MonitorPlugin.kt`、`plugins/MonitorState.kt` |
| 改造 | `AutostartJobService.kt` 加统一调度；`BootReceiver.kt` 触发后注册 |
| 要点 | 8 态；连续 3 次同向转移才生效；`RUNNING→DEGRADED` 立即上报；`DEGRADED→RUNNING` 需 2 次确认；`COOLING/MAX_REACHED` 防重复触发 |
| 验收 | 手动切状态能观察转移；抖动不刷屏；Doze 下靠 Job 补一次 |

### P0.3 三个优先监视器

| 监视器 | 探测方法（复用现有） | 恢复策略 |
|---|---|---|
| `framework` | `ps -A`/`/proc` + HTTP `/api/status` | `startFramework` / 无 adb 时框架自更新 |
| `module:<名>` | `locks/{名}/pid` + `kill -0` | `mod_stop` → 重新 `touch tmp/{名}` |
| `adb` | `get-state` + mDNS + 5555 探活 | `ensureTransportSmart` |

**不改** `BrokerShell` / `BrokerProvider` / `BrokerStore`。

### P0.4 日志页展示

| 项 | 内容 |
|---|---|
| 改造 | `lib/screens/logs_screen.dart` 加事件来源 tab（只展示，不做 UI 主流程变更） |
| 新增 | `lib/models/platform_event.dart` |
| 验收 | 能看到状态转移与 reason；不影响原有日志 tab |

**P0 验收清单**：见方案文档第 10.2 节（kill Main.sh、WebUI 挂、模块超时、抖动、Doze 五项）。

---

## 5. P1：能力契约 + 权限网关

**目标**：把散落的 shell 调用收敛到统一入口，为 P2/P3 铺路。

| 项 | 内容 |
|---|---|
| 新增 | `plugins/Capability.kt`、`plugins/PermissionGateway.kt`、`plugins/CapabilityRegistry.kt` |
| 改造 | `ShellCapability` 基于现有 `AdbBootstrap` + `IwphoneService.runShell`；`BrokerProvider.exec`、`BrokerShell.handle` 改走 `PermissionGateway` |
| 要点 | `getRequiredPermissions(req)` 按请求动态；高危动作必须二次确认；所有动作写 `BrokerStore.appendAudit` |
| 兼容 | **不改变**现有确认弹窗语义、授权表、审计格式 |
| 验收 | 所有 shell 动作可在审计里看到；高危动作仍弹确认；iwsh 终端与 ContentProvider 两条通道行为不变 |

**风险**：这是改动面最大的一步，建议按"先加新接口、再逐条迁移调用点、最后删旧路径"三步提交。

---

## 6. P2：无障碍 / MediaProjection 能力

| 项 | 内容 |
|---|---|
| 新增 | `AccessibilityBridgeService.kt` + Manifest、`ScreenCaptureService.kt`、Flutter 插件管理页 |
| 权限 | `PermissionType.SPECIAL`；用户手动开启后能力自动变 `AVAILABLE`，无需重启 App |
| 降级 | 撤销权限后能力即时降级，正在执行的自动化 `SUSPENDED` |
| 注意 | 商店审核敏感、前台服务类型（Android 14+）、多 ROM 验证 |
| 验收 | 见方案第 10.1 节四项 |

---

## 7. P3：自动化编排

**前置**：P0 事件稳定（至少观察一周无误报）。

| 项 | 内容 |
|---|---|
| 新增 | `plugins/AutomationRegistry.kt`、`plugins/TriggerHandlerRegistry.kt`、`plugins/ListeningTriggerHandler.kt`、`plugins/CircuitBreaker.kt` |
| 改造 | `webui_server.py` 加 `/api/automations`、`/api/automation/<id>/{arm,disarm,run}`；**不改旧端点** |
| 契约 | `.iwp` 包加**可选** `automation.prop`（trigger/guard/action/timeout/on_error/rollback）；旧模块零改动 |
| 增量 | `TriggerDelta` 从第一天就用，禁止全量重建 |
| 熔断 | 30 秒×10 次失败 → 停用依赖该能力的所有自动化，只能 UI 手动恢复 |
| 回滚 | 有写操作的脚本必须声明 `rollback`，否则禁止注册 |
| 验收 | 见方案第 10.3 节五项 |

**触发器落地顺序**（按依赖分级）：
1. 纯广播/定时器：app_package、battery、power、screen、time、interval、wifi、bluetooth
2. 系统服务：notification、clipboard（走我们已有 shell，不接 Core）
3. 无障碍：app_start、app_switch、element、gkd
4. 传感器（可选）：backtap、pose
5. 不做：key_event（native `/dev/input`）、voice_template（独立麦克风服务）

---

## 8. P4：可选外部能力

Shizuku / 虚拟屏维持"外部依赖插件"定位，默认关闭。
若做 L2（`LocalSocket` + `SO_PEERCRED`），先跑最小探针：App 起 abstract socket + iwsh dex 连接 + 打印 peer uid，
验证 `untrusted_app` 不同 MLS category 能否连接，再决定是否替换 8539 TCP。

---

## 9. Git 同步规范

本机代理会让 schannel 报 `CRYPT_E_NO_REVOCATION_CHECK`，push 必须带证书参数：

```bash
cd /f/flutter/shell_manager_app
git -c http.sslBackend=openssl \
    -c http.sslCAInfo=C:/Users/admin/WorkBuddy/2026-09-16-19-58-15/win_roots.pem \
    push
```

大仓库下载用国内镜像（实测 `ghfast.top` 249KB/s，比 ghproxy.net 快 22 倍）：

```bash
curl -sS -L --ssl-no-revoke -o pkg.tar.gz \
  "https://ghfast.top/https://github.com/<owner>/<repo>/archive/refs/heads/master.tar.gz"
```

提交规范：按 P0/P1/P2/P3 分阶段提交，每次提交写清"新增/改造文件 + 验收结果"。
版本号在每个阶段完成后递增（`pubspec.yaml` + `lib/app_info.dart` 同步）。

---

## 10. 回退策略

| 阶段 | 回退方式 |
|---|---|
| P0 | 删除 `plugins/` 目录 + 卸载 EventChannel，不动现有功能 |
| P1 | 保留新接口但调用点回退到原方法；确认弹窗与审计表结构不变 |
| P2 | Manifest 禁用 Service + 能力标记 `UNSUPPORTED`，不影响其他能力 |
| P3 | 停用所有 automation.prop（不删除），WebUI 新端点返回空列表即可 |
| P4 | 默认关闭，无回退成本 |

---

## 10.5 补充：adb shell 模式（v1.3.28）

这是 P1/P3 的实用补充：**自动化动作可以不依赖无障碍**，直接走已配对的 adb shell。
`AdbShellCapability` 把常用 UI 操作封装为命名动作，参数白名单校验防注入：

```
adb:tap x y                      → input tap
adb:swipe x1 y1 x2 y2 [duration] → input swipe
adb:text <text>                  → input text
adb:key <keycode>                → input keyevent
adb:start <pkg> / adb:stop <pkg> → am start / am force-stop
adb:screencap <安全路径>          → screencap -p
```

与无障碍模式的取舍：
- **adb shell**：无需用户开无障碍、不受 ROM 保活限制；只能操作当前前台界面，
  不能读 UI 节点树做内容匹配（适合固定坐标 / 固定流程）。
- **无障碍**：能读节点树、做内容匹配（element / gkd 触发器）；需用户手动开启。

任意 raw 命令仍须显式 `shell:` 前缀（highRisk，走二次确认），
`adb:` 前缀只接受白名单参数，避免自动化脚本变成任意命令执行器。
guard 可写 `capability:adb_shell`。

## 10.6 补充：可视化工作流编辑器（v1.3.29）

不用写 `automation.prop` 文本，像搭积木一样编排：

- 入口：自动化页 → 「可视化工作流」→ 新建 → 从模块库选步骤 → 动态表单填参数 → 保存/执行。
- 内置积木：触发器（事件/手动）、adb 动作（点击/滑动/文本/按键/启动/停止/截图/raw）、
  模块动作（运行 iwphone 模块）、逻辑（延时/调用其它工作流）。
- 模块声明 `ParamDef`（text/number/boolean/enum），编辑器据此生成表单；
  新增模块只需 Dart `ModuleCatalog` 加一条 + Kotlin `WorkflowStore.executeStep` 加分支。
- 当前只做**顺序执行**；分支/循环（vFlow 的 BaseBlockModule）留后续。

## 10.7 补充：触发器预设与自动化模块化（v1.3.30）

三件事一起做，都是为了把「自动化」从演示变成能用的东西。

### (1) 触发器不再是裸事件串

旧界面把 `monitor:framework`、`a11y:window` 直接摆给用户选，看不出「什么时候会触发」，
更看不出「武装之后靠什么跑」。现在：

- `TriggerPresets.kt` 把人话 key 映射到「事件前缀 + 关心的状态 + 要保活的监视器」；
- 界面只显示中文名与一句说明（`TriggerCatalog` 与 Kotlin 侧一一对应）；
- 触发器从「第一步动作」提升为**工作流头部属性**，`trigger.*` 积木退出选择器，
  旧数据里的这类步骤运行时直接跳过（不再当成动作执行）。

### (2) 修掉「触发只发事件、不执行」的空洞

上一版 `AutomationRegistry` 命中后只往总线发一条 `trigger:xxx`，没有任何执行体，
用户看到「武装成功」却什么都没发生。现在触发器绑定执行体，命中后在**单线程池**里跑：

- 单线程 → 多个触发器同时命中时串行，不会交叉点击；
- 不占主线程 → adb 调用与 delay 步骤不会拖住 UI；
- 队列已在执行时，新的命中被丢弃并每 10 秒最多记一条审计，避免窗口事件把队列堆爆；
- 武装时顺带 `subscribe` 对应监视器 —— 没有订阅就没有轮询，这是「武装了却不动」的另一半原因。

武装状态持久化在 `iwphone_automation/armed`，冷启动在后台线程恢复。
注意：`AutomationRegistry` 的构造函数**不能**读 SharedPreferences ——
`MonitorChannel` 是 Activity 的字段初始化器，那时还没有 base context，会直接打崩启动。

### (3) 自动化可以打包成 iwphone 模块

细节见 `doc/automation_module.md`。要点：

- 模块包放 `automation.json`（`unzip` 整包解压，装完就在 `work/<模块>/`）；
- App 用**一段 shell 循环**一次 adb 扫完所有模块（逐模块 cat 会为每个模块起一次 libadb）；
- 模块带来的流程只读，可「复制为我的一份」再编辑；
- 反向支持：任意流程可「导出为模块」，生成 `iwphone.prop + main.sh + automation.json`
  的 `.iwp` 推到 `iwphone/module/`，走的是已验证的 `importPackageBytes` 链路。

### 导航调整

底栏第 4 位由「日志」换成「自动化」（自动化高频、日志低频），
日志改为首页底部常驻卡片，`LogsScreen` 增加 `standalone` 形态（自带 Scaffold + 返回按钮）。

## 10.8 补充：应用级触发器（v1.3.31）

「某应用到前台」「某应用出通知」—— 监视器从「框架/模块」扩到「具体应用」。

### 事件源

| 事件 id | 产生者 | 说明 |
|---|---|---|
| `a11y:fg:<包名>` | 无障碍服务 | 包名**变化**才发；同应用内部切页面/弹框不发；跳过自己 |
| `notif:<包名>` | 通知监听服务 | 跳过常驻通知、分组摘要；同包 1.5s 内合并 |

触发器 key 是自描述的：`app_foreground:<包名>`、`notif_post:<包名>`，包名留空表示任意应用。
指定包名时**精确匹配**（否则 `notif:com.a` 会误命中 `notif:com.abc`）。

### 为什么通知要单独一个 Service

通知不是无障碍事件，必须用 `NotificationListenerService`，权限是**独立的**
「通知使用权」（`enabled_notification_listeners`）。这带来两个后果：

- 未授权时服务根本不会被系统绑定 → 触发器**静默失效**，UI 必须主动提示；
- 声明时 `exported=false` 仍可被 system_server 绑定（system uid 绕过导出检查），
  比 `exported=true` 更安全，不需要额外加权限守卫。

### 成本与边界

- 无障碍关闭时「到前台」收不到任何事件；通知同理。两者都是可选项，不影响其它触发器。
- 事件只在 App 进程活着时有订阅者；进程被杀后武装流程会停（与 v1.3.30 的已知边界一致）。
- 应用清单用 `queryIntentActivities(MAIN/LAUNCHER)` + manifest 的 `<queries>`，
  只列有桌面入口的应用，排序走中文 Collator。

## 11. 本次准备状态

- [x] 设计文档第 13 节（vFlow 机制提炼）已完成
- [x] 接口冻结清单（第 3 节）已写明
- [x] 阶段任务与验收（第 4-8 节）已写明
- [x] Git 同步参数与回退策略（第 9-10 节）已写明
- [x] P0-P3 已落地（v1.3.27）+ adb shell 模式（v1.3.28）
- [x] 可视化工作流编辑器（v1.3.29）
- [x] 触发器预设 + 自动化模块化 + 导航调整（v1.3.30）
- [ ] P4 可选外部能力（默认关闭）
