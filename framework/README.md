# iwphone modrunner v3

Android shell 插件执行框架。无需 root，在 `adb shell` 权限下运行，用纯 POSIX shell 实现模块的**安装、触发、并发执行、互斥锁、日志隔离与超时保护**。

核心设计：**文件即信号** —— 在触发目录 `touch` 一个与模块同名的文件，运行器即执行该模块的 `main.sh`。不依赖任何二进制与 IPC 机制，只要有 `/system/bin/sh` 就能运行；配上 Python WebUI 后可以在浏览器里完成全部管理操作。

## 三条控制通道（任选，可混用）

| 通道 | 触发方式 | 适用场景 |
|---|---|---|
| **触发文件** | `touch /data/local/tmp/iwphone/tmp/{模块名}` | 脚本 / App / 定时任务调用 |
| **命令文件** | 在 `/sdcard/iwphone` 下创建 `reupdate` / `readbsh` / `rebooti` | 无 App 场景：adb push 或直接文件管理器操作 |
| **WebUI** | 浏览器访问 `http://127.0.0.1:8537` | 可视化管理：模块启停、日志查看、包安装、守护控制 |

---

## 快速上手

```sh
# 0. 推送到设备
adb push iwphone_modrunner_v3 /data/local/tmp/
cd /data/local/tmp/iwphone_modrunner_v3

# 1. 安装模块（从本目录 module/ 下查找 .iwp 包）
sh mod_install.sh IWPhone息屏深度doze

# 2. 启动综合守护进程（消费命令文件 + 周期执行触发目录）
sh Main.sh &

# 3. 触发模块的三种方式
touch /data/local/tmp/iwphone/tmp/IWPhone息屏深度doze   # 触发文件
sh mod_run.sh IWPhone息屏深度doze                        # 直接执行（不经守护）
sh webui/webui_start.sh                                  # 或启动 WebUI 用浏览器操作

# 4. 查看日志（stdout / stderr / 框架日志三分离）
cat /sdcard/iwphone/logs/modules/IWPhone息屏深度doze/*.log

# 5. 停止
sh mod_stop.sh IWPhone息屏深度doze    # 停单个模块
sh stop_runner.sh                     # 停守护进程（模块继续跑）
sh stop_runner.sh all                 # 停守护 + 所有模块
sh uninstall.sh                       # 全部卸载
```

## WebUI 使用（开箱即用，无需安装 Python）

```sh
sh webui/webui_start.sh      # 启动（nohup 后台，日志在 logs/webui.log）

# 设备浏览器直接打开：
http://127.0.0.1:8537

# 电脑浏览器（通过 adb 转发）：
adb forward tcp:8537 tcp:8537
# 然后打开 http://127.0.0.1:8537
```

**内置 Python 运行时**：`webui/runtime/` 自带一份**完全静态链接**的 CPython 3.12（musl static，不依赖系统 libc/动态库），无需 Termux、无需 `pkg install python`、无需联网，解压即可启动。

启动器按以下优先级选择解释器，全部自动完成：

| 优先级 | 来源 | 说明 |
|---|---|---|
| 1 | `$PYTHON_BIN` | 手动指定路径（调试用） |
| 2 | `webui/runtime/` | **内置静态 Python**（离线可用，默认路径） |
| 3 | 系统 `python3` | Termux 已装 Python 时的备选 |

若内置运行时与设备 CPU 架构不匹配（例如把 arm64 版本用在 x86 模拟器上），启动器会**自动降级**到系统 Python 并给出提示，不会静默失败。

> **架构支持**：内置运行时为 `aarch64`（覆盖绝大多数 Android 设备）。32 位 armv7 设备无上游静态构建，请改用系统 Python（Termux `pkg install python`），或用 `sh tools/build_runtime.sh` 重新生成。

WebUI 能力：守护进程启停与状态、模块列表与运行状态（3 秒自动刷新）、模块启动/停止、三类日志查看（.log/.out/.err 切换，2.5 秒自动刷新）、.iwp 模块包安装/重装、状态同步。

安全：仅绑定 `127.0.0.1`；在 `env.sh` 中设置 `WEBUI_TOKEN` 后，访问需带 `?token=xxx`（页面会记住令牌）。

停止 WebUI：`sh webui/webui_stop.sh`

---

## 文件说明

| 文件 | 职责 |
|---|---|
| `env.sh` | **唯一配置入口**：路径 / 超时 / 黑名单 / WebUI 端口与令牌 |
| `core.sh` | 公共函数库：日志 / 模块名校验 / 原子锁 / 黑名单 / 模块启动器 |
| `Main.sh` | **综合守护进程**：消费 `/sdcard` 命令文件 + 周期调用 iwphone.sh |
| `iwphone.sh` | **单轮运行器**：扫描触发目录执行一轮后退出（可独立手动运行） |
| `mod_run.sh` / `mod_stop.sh` | 单模块直启 / 停止（不经守护轮询） |
| `mod_install.sh` | 安装 `.iwp` 模块包 |
| `stop_runner.sh` | 停止守护进程；`modules` 只停模块；`all` 全停 |
| `uninstall.sh` | 卸载框架（停 WebUI + 守护 + 模块，删除全部目录） |
| `sync.sh` | 目录同步工具（MD5 对比） |
| `uid2pkg.sh` | 实用工具：文件所有者 UID → 应用包名反查 |
| `webui/webui_server.py` | WebUI 后端（Python3 标准库，零三方依赖） |
| `webui/webui_start.sh` / `webui_stop.sh` | WebUI 启停（自动挑选可用 Python 解释器） |
| `webui/static/index.html` | WebUI 前端（深色主题，移动端优先） |
| `webui/runtime/` | **内置静态 CPython 3.12 运行时**（离线可用，详见 `RUNTIME.txt`） |
| `tools/build_runtime.sh` | 重新生成内置运行时（需 curl+zstd+tar，在电脑/Termux 上执行） |
| `module/*.iwp` | 官方示例模块（息屏深度 doze / aapt 应用管理） |

### 分发包说明

| 包 | 体积 | 内容 | 适用 |
|---|---|---|---|
| `iwphone_modrunner_v3.zip` | 较大（含 37MB 运行时） | 完整包，**解压即用** | 推荐：设备无 Python、无网络 |
| `iwphone_modrunner_v3_slim.zip` | 极小 | 不含 `webui/runtime/` | 设备已有 Python（Termux），或自行生成运行时 |

精简包要补运行时，在电脑或 Termux 上执行：

```sh
sh tools/build_runtime.sh --arch aarch64            # 生成到 webui/runtime
sh tools/build_runtime.sh --arch aarch64 --push     # 生成并 adb push 到设备
```

> **为什么不能在设备上自行下载运行时？** 上游发布包是 `.tar.zst`，而 Android shell 没有 `zstd`，无法在设备端解压。因此运行时必须在有工具链的一侧生成后拷入，这也是提供完整包的原因。

> **部署路径**：请解压到 `/data/local/tmp/` 等**可执行**目录。`/sdcard` 以 `noexec` 挂载，脚本与内置二进制都无法运行。

## 运行时目录布局

```
/data/local/tmp/iwphone/          # 框架根目录 IWPHONE_ROOT
├── work/{模块名}/main.sh         # 模块安装目录（.iwp 解压产物）
├── tmp/{模块名}                  # 触发文件（存在即触发执行）
├── locks/{模块名}/pid            # 模块锁（目录级原子锁，崩溃自愈）
├── modrunner.pid                 # 守护进程 PID
├── webui.pid                     # WebUI 服务 PID
└── end                           # 守护进程退出信号

/sdcard/iwphone/                  # 用户命令区 SDCARD_DIR（用户/ADB 可写）
├── reupdate / readbsh / rebooti  # 命令文件（创建即生效，消费后自动删除）
├── adbsh/main.sh                 # readbsh 投递的用户脚本
├── state/                        # 执行区状态镜像（sync 同步产物）
└── logs/                         # 日志根目录
    ├── modrunner_YYYYMMDD.log    # 框架运行日志（按天切割）
    ├── webui.log                 # WebUI 服务日志
    └── modules/{模块名}/
        ├── {模块名}.log          # 框架视角：开始/结束/退出码
        ├── {模块名}.out          # 模块 stdout
        └── {模块名}.err          # 模块 stderr
```

## 命令文件详解（无 App 场景操作面）

在 `/sdcard/iwphone` 下创建同名文件，守护进程下一轮（≤POLL_SEC 秒）消费并自动删除：

| 命令文件 | 动作 |
|---|---|
| `reupdate` | 把执行区同步到 `/sdcard/iwphone/state/`（在文件管理器里直接查看 work/locks/tmp 实时状态） |
| `readbsh` | 执行 `/sdcard/iwphone/adbsh/main.sh`（先 `adb push` 脚本上去再创建此文件） |
| `rebooti` | 停止所有运行中的模块 |

> ⚠️ **readbsh 通道风险**：任何有存储权限的 App 都能在 `/sdcard` 创建文件，从而以 shell 权限执行自己的脚本。不需要时在 `env.sh` 置 `CONTROL_ADBSH=0` 关闭。

## 模块格式（.iwp）

`.iwp` 本质是 **zip 包**，解压后即为模块目录：

```
{模块名}.iwp
├── iwphone.prop     # 元信息（PackageName/version/author/description，可选）
├── main.sh          # 入口脚本（执行约定）
├── uninstall.sh     # 模块自定义卸载逻辑（可选）
├── icon.png         # 自定义图标（可选，见下节）
└── （任意资源：二进制、配置、策略文件...）
```

**运行时约定**：模块在自身目录内执行；`PATH` 隔离为 `/system/bin:/system/xbin`，`HOME`/`TMPDIR` 指向模块专属沙箱目录；`echo` 输出全部进入 `.out`。常驻模块建议自带 **end 文件退出机制**（参考 doze 示例）。

### 模块图标（可选）

想让模块在列表里一眼能认出来，两种方式，可同时用：

| 方式 | 写在哪 | 说明 |
|---|---|---|
| 语义图标 | `iwphone.prop` 里加一行 `icon="battery"` | 客户端内置图标表，跟随浅色/深色主题，零包体积 |
| 自定义图 | 包里放 `icon.png` | 优先于 `icon=`；192×192 透明底 PNG 效果最好，上限 256 KB |

可用语义名（与 `lib/widgets/module_icon.dart` 的 `ModuleIcons.table` 一一对应）：

```
app        battery   cloud      debug     display   dns
input      language  memory     module    motion    network
performance power    privacy    security  sound     storage
system     time      visual
```

> 键名一经发布不要再改，改名等于让已发布的模块丢失图标；新增键是安全的。

**两者都没有**时，客户端按模块名哈希挑一个兜底图标 —— 老模块不需要任何改动。

例：

```ini
name="BlurOff"
version="1.0.0"
description="关闭系统窗口模糊与（可选）降低界面透明度。"
icon="visual"
```

## 配置项速查（env.sh）

| 配置 | 默认值 | 说明 |
|---|---|---|
| `IWPHONE_ROOT` | `/data/local/tmp/iwphone` | 框架根目录 |
| `LOG_ROOT_DIR` | `/sdcard/iwphone/logs` | 日志根目录 |
| `POLL_SEC` | 15 | 守护轮询间隔（秒） |
| `MAX_RUNTIME_SEC` | 300 | 模块超时强杀（0=不限） |
| `MAX_PARALLEL` | 0 | 最大并发模块数（0=不限） |
| `AUTO_CLEAN` | 1 | 触发后自动清理触发文件 |
| `COMMAND_BLACKLIST` | 见 env.sh | 高危命令 ERE 黑名单（置空禁用） |
| `PATH_ISOLATION` / `SANDBOX_PATH` | 1 / `/system/bin:/system/xbin` | 模块环境隔离 |
| `SDCARD_DIR` | `/sdcard/iwphone` | 用户命令区 |
| `CONTROL_ADBSH` | 1 | readbsh 投递脚本通道开关 |
| `WEBUI_PORT` / `WEBUI_TOKEN` | 8537 / 空 | WebUI 端口 / 访问令牌 |

所有配置均可通过环境变量临时覆盖：`MAX_RUNTIME_SEC=10 sh mod_run.sh demo`

## 安全模型

- **命令黑名单**：对 `main.sh` 全文扫描（词边界匹配，`result`/`sum` 不会误杀），命中即拒绝执行。黑名单是防呆措施，不是安全边界——不要安装来历不明的模块。
- **原子锁**：`mkdir` 原子操作 + PID 存活检测，同一模块绝不并发双跑；持锁进程崩溃后锁自动回收。
- **看门狗不泄漏**：模块正常结束时超时看门狗被同步收割，无残留 `sleep` 进程。
- **WebUI**：仅绑定 127.0.0.1（外部网络无法直接访问），可选 token 鉴权。
- 旧版 v1 的**无鉴权 nc 远程终端**（niw.sh）已永久移除，由 WebUI 取代。

## 与 v2 的差异

- **恢复 `Main.sh` + `iwphone.sh` 经典组合**（基于 v2 修复后的 core.sh 重写）：Main.sh 综合守护（命令文件消费 + 周期调度），iwphone.sh 单轮运行器，框架可完全脱离 App 独立运行。
- **`modrunner.sh` 移除**：职责被 Main.sh 吸收（避免双守护并存）。
- **新增 WebUI**：`webview_shell` 实验（nc 手写 HTTP）正式重构为 Python 标准库后端 + 深色 WebUI，覆盖模块管理、日志查看、包安装、守护控制、状态同步。
- **`stop_runner.sh` 语义明确**：无参=停守护，`modules`=只停模块，`all`=全停。
- **状态镜像目录独立**：执行区同步到 `/sdcard/iwphone/state/` 子目录，不再与命令文件、adbsh 同层混放（修复旧版 sync 会误删投递目录的问题）。
- **`iwncsh` 通道移除**：nc 远程终端由 WebUI 取代。

## 已知限制

- **常驻模块的锁语义**：若模块 `main.sh` 内部自分离后台进程（如 doze 示例的 `( ... ) &`），main.sh 立即退出会导致锁随之释放。这类模块请使用守护轮询模式（触发文件 + 锁跳过）或模块自带 end 文件机制管理生命周期。
- **黑名单只扫描 main.sh**：模块附带脚本不在扫描范围。
- **内置运行时体积**：完整包含约 37MB 静态 Python（压缩后大幅减小）。只需要 shell 通道时可使用精简包，`webui/runtime/` 可随时删除，框架其余功能不受影响。
- **内置运行时的架构**：aarch64 版本无法在 x86 设备运行，此时请用系统 Python 或重新生成对应架构。

---

## 本仓库中的位置与打包

这个目录是框架的**源码**。它**不含** `webui/runtime/` —— 那是约 36 MB 的静态 Python 运行时，
体积大且与 CPU 架构绑定，因此不纳入版本控制。

### 运行时怎么来（二选一）

```sh
# 1) 在 Linux / macOS / Termux 上生成（需要 curl/wget + zstd + tar）
sh tools/build_runtime.sh --arch aarch64

# 2) 从已部署的设备拉一份
adb pull /data/local/tmp/iwphone/webui/runtime webui/runtime
```

### 重新打包 App 内置资产

改了框架之后，App 里那份 `assets/framework.bin` 需要重新生成：

```sh
sh tools/build_framework_bin.sh          # 输出到 android/app/src/main/assets/framework.bin
```

> ⚠️ **资产文件名必须是 `.bin`**：AAPT 打包资产时会**解压 `.gz` 并去掉后缀**
> （实测得到 `assets/framework.tar`），用 `.tar.gz` 会让 App 里 `assets.open()` 找不到文件。

### 只想要 shell 通道？

`webui/` 整个目录都可以删掉，框架其余功能不受影响 —— 触发文件与命令文件两条通道不依赖 Python。
