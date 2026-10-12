# iwphone 模块开发指南（.iwp）

> 面向想给 iwphone modrunner v3 写模块的人。读完这篇就能写出
> 能被 Shell Manager 识别、启动、停止、配置的模块。
>
> 内置的四个参考实现：`AnimTuner` / `BlurOff` / `PrivateDNS` / `NightNetOff`。

---

## 1. 模块是什么

一个模块就是**一个目录**，里面至少有一个 `main.sh`，以 **shell 身份（uid 2000）**
在设备上运行。框架负责：加锁、隔离环境、记日志、超时保护、启停控制。

```
 IWPhone息屏深度doze/          ← 目录名就是模块名（唯一 id）
 ├── main.sh                   ← 入口，必须有才算「可执行模块」
 ├── iwphone.prop              ← 元信息 + 独占资源声明
 ├── config.prop               ← 可选：声明配置项，App 自动生成配置页
 ├── config.sh                 ← 可选：App 保存配置时生成，模块 source 读取
 ├── uninstall.sh              ← 可选：卸载时执行（清理现场）
 └── （你自己的其它文件）
```

打包成 `.iwp`：就是**普通 zip**，把上面这些文件放在 zip 根目录，
文件名 = 模块名（不能含空格 / `..` / `/`）。安装时解压到 `work/<模块名>/`。

---

## 2. 最小可用模块

```sh
#!/system/bin/sh
# main.sh
echo "hello from module"
```

就这些。打包成 `Hello.iwp`（zip 根目录放 main.sh 和 iwphone.prop）即可安装。

---

## 3. iwphone.prop

`Key="值"` 格式（值带引号，框架能容忍无引号）。常用字段：

| 字段 | 作用 | 必填 |
|---|---|---|
| `name` / `PackageName` | 显示名 | 建议 |
| `version` | 版本号 | 建议 |
| `author` | 作者 | 可选 |
| `description` | 描述（显示在卡片上） | 建议 |
| `exclusive` | **独占资源声明**，逗号分隔 | **强烈建议** |
| `runtime` | 运行时上限秒数，`0` = 不限制 | **常驻模块必须填 0** |

### 3.1 `exclusive=` —— 与其他模块和平共处

声明你的模块会**写**哪些系统资源。两个模块声明了同一资源时，
后启动的会被拒绝，避免互相覆盖（App 上会显示「资源冲突」角标）。

资源名格式（域.对象）：

| 前缀 | 对应命令 | 例子 |
|---|---|---|
| `global.` / `secure.` / `system.` | `settings put <ns> <key>` | `global.private_dns_mode` |
| `prop.` | `setprop <key>` | `prop.debug.force_opengl` |
| `service.` | `cmd <svc> <写动词>` / `dumpsys <svc> <写动词>` | `service.deviceidle` |
| `svc.` | `svc <domain> <verb>` | `svc.data.disable` |
| `appops.` | `appops set <pkg> <op>` | `appops.com.foo.RUN_IN_BACKGROUND` |
| `config.` | `device_config put <ns> <k>` | `config.activity_manager.max_cached` |
| `display.` | `wm size` / `wm density` | `display.size` |

不声明也能装（框架安装时会**自动从脚本里提取**写操作生成 `exclusive=`），
但自动提取不如手写准确 —— 涉及「模块 A 改这个、模块 B 也改这个」的场景请手写。

### 3.2 `runtime=` —— 常驻模块必须写 0

框架默认给每个模块 **300 秒**运行上限，超时强杀。
如果你的模块是 `while true` 常驻循环，**必须**在 prop 里写 `runtime="0"`，
否则 5 分钟后静默死亡（触发文件已被清掉，也不会自动重启）。

一次性脚本（跑完就退出）不用管这个字段。

---

## 4. main.sh 的三种写法

框架都能正确跟踪存活：

```sh
# A. 前台常驻（推荐，最直观）
while true; do
    ...你的逻辑...
    sleep 30
done
```

```sh
# B. 自我后台化
(
    while true; do ...; sleep 30; done
)&
```

```sh
# C. 一次性脚本：做完就退出
settings put global window_animation_scale 0.5
exit 0
```

> 写法 A/C 更好。B 依赖框架在入口脚本末尾补 `wait`，能用但没必要。
> 框架判「运行中」的依据是**进程还活着** —— 一次性脚本跑完就显示「未运行」。

---

## 5. 配置：让用户能调参数

### 5.1 声明（config.prop）

每行一个选项，竖线分隔 6 段：

```
键|类型|标签|默认值|可选值(逗号分隔)|说明
```

| 类型 | 控件 | 说明 |
|---|---|---|
| `bool`（或 `toggle`） | 开关 | 值为 `1` / `0` |
| `enum`（或 `select`） | 下拉单选 | 可选值段不能为空 |
| `int`（或 `number`） | 数字输入 | |
| `text` | 文本输入 | 最长 512 字符 |

两种拼法都接受（容易写混，索性都收），对外统一归一化为 `bool/enum/int/text`。

示例（AnimTuner）：

```
scale|enum|动画速度|0.5|0,0.5,1,1.5,2|0 完全关闭动画，1 为系统默认
guard|int|重新应用间隔|30||秒。部分系统会自行改回动画速度
```

### 5.2 读取（config.sh）

用户在 App 里保存后，框架生成 `<模块>/config.sh`，**键名统一大写**：

```sh
SCALE="0.5"
GUARD="30"
```

模块里这样读：

```sh
cd "$(dirname "$0")" || exit 1

[ -f ./config.sh ] && . ./config.sh

SCALE="${SCALE:-0.5}"     # 兜底默认值
GUARD="${GUARD:-30}"
```

> 键名会被转成大写写入，这是有意为之 —— 避免和 `PATH` / `HOME` / `IFS`
> 这类小写环境变量撞名。所以 config.prop 里写小写、脚本里读大写。

### 5.3 让改动即时生效

在守卫循环里**每轮重新 source**，用户改完配置最迟一个周期就生效：

```sh
while true; do
    [ -f ./end ] && exit 0
    sleep "$GUARD"
    [ -f ./config.sh ] && . ./config.sh    # ← 每轮重读
    apply
done
```

---

## 6. 生命周期

| 事件 | 框架行为 | 模块该做什么 |
|---|---|---|
| 启动 | 加锁 → 隔离环境 → 跑 main.sh | 正常跑 |
| 停止 | `kill -TERM` 进程及子进程 → 删锁 | 用 `trap` 做现场清理 |
| 手动退出 | 模块目录里 `touch end` | 循环里检查 `end` 文件后自行退出 |

**清理现场很重要**。比如 NightNetOff 停止时必须把网络恢复，
否则「模块停了但用户一直没网」：

```sh
cleanup() {
    svc data enable
    echo "已退出，网络恢复"
}
trap cleanup TERM INT EXIT
```

---

## 7. 日志

| 文件 | 谁写 | 位置 |
|---|---|---|
| `<名>.log` | 你自己（`module_log` / `>>` 追加） | `/sdcard/iwphone/logs/modules/<名>/` |
| `<名>.out` / `.err` | 框架（进程 stdout/stderr） | `/data/local/tmp/iwphone/modio/<名>/` |

`.log` 在 sdcard 上方便直接查看；`.out`/`.err` 在原生分区，原因见下。

---

## 8. ★ 必须知道的坑

### 8.1 stdout 不能是 /sdcard 上的文件

`cmd`（以及 `settings`、`appops` 等基于它的命令）会**通过 binder 传递
stdin/stdout/stderr 的 fd**。fd 指向 /sdcard（FUSE）上的文件时传不过去：

```
cmd: Failure calling service settings: Failed transaction (2147483646)
```

框架已经把模块 stdout/stderr 指到原生分区，**你不用管**。
但如果你自己在脚本里做重定向（`cmd ... > /sdcard/xxx.log`），就会踩中。
要么去掉重定向，要么写到 `/data/local/tmp` 下。

### 8.2 行尾必须 LF

CRLF 会让 mksh 报 `syntax error: unexpected 'fi'`。
打包前检查：`python -c "d=open('main.sh','rb').read(); print(d.count(b'\r'))"`（应为 0）。

### 8.3 不要用 `adb shell cat` 拉文件

它会把 `\n` 翻译成 `\r\n`。用 `adb pull`。

### 8.4 沙箱会包装部分命令

框架会包装 `settings` / `setprop` / `dumpsys` / `cmd` / `svc` / `appops` / `pm` / `am` 等，
**只做记账，不改变行为**。但意味着这些命令是以函数形式存在的 ——
别用 `command -v settings` 判断它是不是外部命令（会返回函数名而非路径）。

### 8.5 黑名单命令会被拒启

含 `rm -rf /`、`setenforce 0`、`su` 等高危命令的 main.sh 会被拒绝启动。

### 8.6 算术里的前导零

`date +%H` 返回 `08`，直接放进 `$(( ))` 会被当成八进制报错：

```sh
h=$(date +%H)
h=$((10#$h))     # ← 强制按十进制
```

---

## 9. 调试清单

模块「跑不起来 / 没效果」时按这个顺序查：

1. `sh -n main.sh` —— 语法对不对
2. `sh mod_run.sh <模块名>` 手动跑一次，看输出
3. 看 `/sdcard/iwphone/logs/modules/<名>/<名>.out` —— 有没有报错
4. 看模块自己的日志（如果你有写）
5. `ls /data/local/tmp/iwphone/locks/` —— 锁在 = 进程活着
6. 设置没变？→ 检查是不是踩了 8.1 的 FUSE 坑
7. 5 分钟后进程没了？→ prop 里没写 `runtime="0"`
8. 冲突被拒？→ 看冲突日志，或把 `exclusive` 改准确

---

## 10. 完整示例

见内置模块（`module/*.iwp` 或解包后的 `work/`）：

- **AnimTuner** —— 最小完整示例：声明 + 读取配置 + 守卫循环
- **NightNetOff** —— 进阶：时间判断、跨零点区间、退出清理
- **IWPhone息屏深度doze** —— 老模块改造：兼容旧的策略文件机制，同时接入新配置

---


---

## 11. 兼容层：Magisk / KernelSU / AxManager 式模块

这三类框架的模块结构高度一致（AxManager 明确兼容前两者的模块格式），
框架内置了适配层（`compat.sh`），安装时自动启用。

### 11.1 识别与适配

安装包里若存在 `module.prop`（而非 iwphone.prop）即判定为该类模块：

| Magisk/KernelSU/AxManager | 本框架的处理 |
|---|---|
| `module.prop`（id/name/version/author/description） | 自动生成 `iwphone.prop`（补 `runtime="0"`、`compat="magisk,ksu,axmanager"` 标记） |
| `service.sh`（常驻服务） | 生成兼容入口 `main.sh` → `exec sh service.sh` |
| `post-fs-data.sh` | 启动时同步跑一次（**语义差异**：免 root 无挂载前阶段，仅尽力执行） |
| `action.sh` | App 卡片出现「动作」按钮，点击执行并展示输出 |
| `uninstall.sh` | 原样支持 |
| `disable` 旗标文件 | 兼容入口启动时检查，存在即停用 |
| `MODDIR` 环境变量 | 兼容入口自动 export |
| `AXERONDIR`（AxManager） | export 到本框架的 compat 目录（尽力而为） |
| `webroot/` 每模块 WebUI | **支持** —— 框架 WebUI 在 `/mod/<模块名>/` 下提供服务，App 内 WebView 打开并注入 `ksu` 桥（exec/toast），KernelSU 规范的模块页面可直接用 |
| BusyBox applet 假设 | **支持** —— 框架自带 Magisk 构建的 BusyBox（358 个 applet），部署时在 `bin/` 铺好符号链接，模块脚本运行时 PATH 优先指向它 |
| systemless 挂载 / system/bin 链接 | **不支持**（无 root 无挂载能力） |

### 11.2 环境变量与运行环境

兼容入口会 export：`MODDIR`（模块目录）、`IWPHONE_ROOT`、`AXERONDIR`（尽力兼容）；
并把框架自带的 `bin/`（busybox applet 链接）放到 `PATH` 最前。

模块自带 WebUI 的地址：`http://127.0.0.1:8537/mod/<模块名>/`，
在 App 内打开时已注入 `ksu.exec(cmd)` / `ksu.toast(msg)` 桥。

### 11.3 限制（务必告知用户）

- Magisk 模块里最常见的「systemless 替换系统文件」类模块**根本不可能**在免 root
  环境工作 —— 能工作的是纯脚本类（省电、性能调度、隐私开关等）
- 引用 `"$MODDIR"` 之外的框架专属路径（如 `$KSU`、`$MAGISKTMP`）的模块不兼容

### 11.4 打包

zip 根目录直接放 `module.prop` + `service.sh`（+ action.sh / uninstall.sh），
无需改成 .iwp —— 安装器按内容自动识别。


---

## 12. 写前快照与一键还原

**免 root 玩机最怕的不是"没效果"，而是"改坏了回不去"。** 框架因此内置了写前快照。

### 12.1 怎么工作

沙箱本来就拦下了模块的所有写操作（`settings` / `setprop` / `svc` / `pm` / `appops` /
`cmd` / `dumpsys`）。现在在这些写操作的**执行之前**多一步：
**首次写某资源时，把该资源的原值记进快照文件**。

```
$IWPHONE_ROOT/modsnap/<模块名>.snap
```

文件里每行是一条可直接执行的还原命令，行尾 `[...]` 是资源标记（用于去重，同一资源只记一次）：

```
settings put global window_animation_scale '1.0'   # [global.window_animation_scale]
```

- 只在**首次**写该资源时记录 → 几乎零开销
- 快照目录是 `modsnap/`，**与冲突检测 L3 的值快照目录 `state/snapshots/` 完全分开**

### 12.2 支持还原到什么程度

| 写操作 | 还原方式 |
|---|---|
| `settings put/delete <ns> <k>` | 完整（原值为空则 `settings delete`） |
| `appops set <pkg> <op> <mode>` | 按旧 mode 写回 |
| `svc wifi/data enable\|disable` | 查 `wifi_on`/`mobile_data` 决定方向 |
| `pm disable-user/disable <pkg>` | `pm enable` 回去（原本即禁用的则跳过） |
| `cmd deviceidle force-idle / disable / enable` | 映射反向动词 |
| `setprop` | 尽力（`ro.` 属性写不回去，属系统限制） |
| `am force-stop` 等 | **不可还原**（无意义），快照里如实记为注释行 |

### 12.3 用户怎么用

模块卡片 → `<>` 展开 → **「还原」**（仅当该模块有快照时出现）。

点击后先弹出**快照清单**（这是"还原"的日志界面），逐项列出：

```
global.window_animation_scale
   当前 0  →  还原为 1.0
```

看清了再点「还原 N 项」。**不做盲还原** —— 用户始终知道到底会改什么。

> ★ 还原会**先停止该模块**再执行 —— 常驻模块的守卫循环会周期性把值改回去，
> 不停模块就还原等于白还原。

还原成功后快照归档为 `.snap.done.<时间戳>`，防止二次误还原
（二次还原会把模块改过的值当成"原值"写回去）。模块重新启动会生成新快照。

### 12.4 沙箱覆盖面（实测）

记账与快照靠两层拦截：模块 shell 里的**函数包装** + PATH 最前面的**包装脚本**
（`$IWPHONE_ROOT/sbxbin/`）。实测各种写法的覆盖情况：

| 写法 | 记账/快照 |
|---|---|
| `settings put …`（裸命令名） | ✅ |
| `\settings put …`（反斜杠） | ✅ |
| `env settings put …` | ✅（PATH 包装） |
| `sh -c 'settings put …'` | ✅（PATH 包装） |
| `command settings put …` | ✅（PATH 包装） |
| `busybox sh -c 'settings …'` | ✅（PATH 包装） |
| `/system/bin/settings put …`（绝对路径） | ❌ **拦不到** |
| `$P/settings put …`（变量拼绝对路径） | ❌ **拦不到** |
| native 二进制 / `service call` 直接 binder | ❌ **拦不到** |

拦不到的写法**不会记账、也没有写前快照**，所以：安装时预检会静态扫描绝对路径与
binder 调用，在报告里明确标出 `⚠ 沙箱拦不到，不会记账、也没有写前快照`。

### 12.5 卸载模块后的快照（孤儿快照）

**卸载模块不会删除它的快照**。这是刻意的：模块可以卸载，但它改过的系统设置
仍然应该能还原 —— 否则「装了个模块把手机搞乱 → 卸载 → 却发现改动留在系统里」
就无解了。

两条补救路径：

1. **卸载时勾选「同时还原系统设置」**（有快照的模块默认勾选）——
   先停模块再还原，然后卸载，一步到位
2. **设置 → 历史快照** —— 列出所有快照，含已卸载模块留下的「孤儿快照」，
   随时可以还原或删除

> 勾选与否快照都会保留，所以「先卸载、后悔了再还原」这条路始终通。

### 12.6 安装时的包内容审计

`mod_install.sh` 在解压**之前**会审计包内条目，挡住 zip 的路径穿越：

| 危险条目 | 处理 |
|---|---|
| `../../x`（相对逃逸） | 拒绝安装 |
| `/abs/path`（绝对路径） | 拒绝安装 |
| 指向外部的**符号链接** | 拒绝安装 |
| 树内的相对软链（`helper -> main.sh`） | 放行 |

实现有三层退路：框架自带 Python（能读到 ZIP 里的软链目标，最准）→ `unzip -Z1`
+grep → 两者都不可用时**明确警告后放行**（不假装校验过）。

### 12.7 给模块作者的建议

- 想让用户能回退，就**老实通过标准命令写资源**（`settings`/`svc`/`pm` 等）——
  沙箱能看到才能快照
- **绝对路径**调用（`/system/bin/settings …`）、native 二进制、`service call`
  这类写法沙箱拦不到 → 没有快照。想支持还原就**别用绝对路径**
- 需要临时改设置时，优先用 `settings` / `svc` / `pm` 这些标准命令的**裸命令名**

---

## 13. 访问密钥（WebUI 鉴权）

### 13.1 为什么必须有

框架的 WebUI 上挂着 `/api/shell` —— 以 **shell 身份**执行任意命令（等价 ADB 权限），
而它监听在 `127.0.0.1:8537`。**同设备上任何有网络权限的应用都能访问回环口**。

所以「没设密钥 = 全部放行」在安全上是个真实的提权漏洞：别的 App 只要
`curl 127.0.0.1:8537/api/shell?cmd=...` 就拿到了 ADB 权限。

**当前策略是「可选但要说清代价」**（产品决策：密钥不作为强制依赖）：

- **不设密钥** → 服务端放行，框架照常可用；日志里记一条 WARN。
  代价：同设备任何有网络权限的应用都能调用 `/api/shell`。
- **设了密钥** → 未携带正确 `token`/`X-Token` 的请求一律 403。
- 首次启动给一次建议性提示，用户可点「暂不设置」关掉（状态持久化）。
- 之后随时能在「设置 → 访问密钥」补上，不需要重新部署框架

### 13.2 怎么做的（APatch 式：用户自己设）

密钥由**用户自己想**，而不是随机生成 —— 好处是用户能拿它直接在浏览器里打开
WebUI，也省掉了「App 经 adb 取随机 token」那条链路。

```
主页「先设置访问密钥」卡片 → 用户输入（≥8 位）
   → App 写进缓存文件 → adb push 到 state/webui_token → chmod 600
   → App 本地也存一份（每次请求带 X-Token 头）
```

- 服务端按 **mtime** 读取密钥文件 → **改密钥不用重启 WebUI**，下个请求就生效
- 密钥两处存放：设备侧 `state/webui_token`（600、shell 属主）+ App 私有存储
- App 进程**读不到**设备侧那个文件（600），只能经 adb 读写 ——
  「拿到密钥」因此天然依赖「已完成配对」，符合最小权限原则
- 密钥走 **push 文件内容**，不经过命令行参数（`adb shell echo '…'` 会出现在 `ps` 里）

### 13.3 配套改动

| 场景 | 处理 |
|---|---|
| App 自身请求 | 启动时读本地密钥 → 装进 HTTP 客户端（`X-Token` 头） |
| 模块自带 WebUI（App 内 WebView） | 页面 URL 带 `?token=`，桥里的特权调用带 `X-Token` 头 |
| 浏览器直开 WebUI | 用带 `?token=xxx` 的地址；改动密钥在「设置 → 访问密钥」 |
| 未设密钥时 | 主页显示引导卡片；App 的接口调用会 403 |

### 13.4 强度与边界

- 强制 **≥8 位**、禁止空白字符（密钥强度取决于用户，这是 APatch 式方案的固有代价）
- 密钥泄露面：App 私有存储 + 设备侧 600 文件。有 root 的进程能读，
  但那种情况下它本来就能 `adb shell`，不构成新的暴露面
- 尚未做：失败次数节流（本地回环口暴力尝试的实际风险低，暂不引入复杂度）

*文档对应框架版本：modrunner v3（2026-09）modrunner v3（2026-09）。有出入以 `core.sh` / `mod_install.sh` 实际行为为准。*
