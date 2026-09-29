# iwphone 模块冲突检测与拦截（方案 A）

> 目标：防止多个模块同时调优同一系统配置导致互相覆盖。
> 定位：**约定 + 记账 + 声明比对**，不是沙箱（不做恶意绕过防护）。

---

## 三层机制

| 层 | 名称 | 作用 | 时机 |
|---|---|---|---|
| L1 | **声明式拦截** | 模块声明独占资源，启动前比对，冲突拒绝启动 | `start_module()` 之前 |
| L2 | **运行时记账** | 沙箱记录每个模块实际写过哪些资源，发现多写入者则告警 | 每轮扫描结束 |
| L3 | **值快照兜底** | 对已声明资源定期取值，发现被外部改写则告警 | 每轮扫描结束 |

---

## 资源名格式（统一「域.对象」）

| 模块里的写法 | 归一化资源名 |
|---|---|
| `settings put global foo 1` | `global.foo` |
| `settings delete secure bar` | `secure.bar` |
| `setprop persist.x.y 1` | `prop.persist.x.y` |
| `dumpsys deviceidle enable` | `service.deviceidle` |
| `cmd power set-mode 1` | `service.power` |

**只记写操作**。`settings get` / `dumpsys xxx`（纯查询）不记账，避免噪音。

---

## 模块如何声明（L1）

在模块的 `iwphone.prop` 里加一行或多行：

```ini
# 精确资源：任何一个重合就拒绝启动
exclusive="service.deviceidle,global.low_power"

# 粗粒度分组：语义相关的调优域，防止"不同键但同类"的冲突
exclusive.group="power_management"
```

- **不声明 = 放行**（向后兼容，老模块不会被误拦）
- **人工声明优先**：`mod_install.sh` 只在没有 `exclusive=` 时才自动写入
- 想放行一个被拦的模块：停掉占用方，或删掉自己的 `exclusive` 行

### 现有模块的声明

`IWPhone息屏深度doze` 已自动识别为 `service.deviceidle`：

```
exclusive="service.deviceidle"
```

---

## 自动提取（安装时）

`mod_install.sh` 安装 `.iwp` 时，会扫描模块所有 `*.sh`，自动提取系统配置写操作并写入 `exclusive=`：

```sh
# 提取规则（正则）
settings (put|delete) <ns> <key>
setprop <key>
dumpsys <svc> (enable|disable|force-idle|unforce|step)
cmd <svc> (set-*|force-*|enable|disable)
```

- 纯二进制模块（无 `.sh`）不提取，不参与冲突检查
- 提取结果可在安装日志中看到：`🔒 已自动声明独占资源：...`

---

## 运行时记账（L2）

### 沙箱如何自动注入

框架启动模块时生成入口副本 `模块目录/.iwphone_entry.sh`：

```
1. 设置 IWPHONE_MODULE / IWPHONE_ROOT
2. 内联 sandbox.sh 全部内容（函数定义）
3. 内联 main.sh 全部内容
4. wait   ← 关键：保活自我后台化的模块
```

**为什么用「内联」而不是「source main.sh」**：
- shell 函数是进程内状态，不会通过环境变量传给子进程
- mksh 非交互式不读 `$ENV`
- `source` 会让 `main.sh` 结尾的 `( ... )&` 立即返回，框架误判模块已结束（历史 bug）
- 内联保持 `main.sh` 的执行语义，末尾 `wait` 兜住 `( )&` 的后台作业

生成失败会**自动回退到原 `main.sh`**，沙箱不可用不影响模块运行。

### 被包装的命令

`sandbox.sh` 在模块进程内定义以下函数（先记账 → 用 `command` 原样执行）：

| 函数 | 记录条件 |
|---|---|
| `settings` | `put` / `delete` |
| `setprop` | 总是 |
| `dumpsys` | 第 2 参数是写动作（`enable`/`disable`/`force-idle`/`unforce`/`step`/`set-*`/`reset`） |
| `cmd` | 第 2 参数是写动作（`set-*`/`enable`/`disable`/`start`/`stop`/`force-*`/`reset`/`add`/`remove`） |
| `eval` | 从字符串里静态提取上面的写调用后记账 |

**关键：不阻断任何命令**，退出码与输出完全不变。只有记账副作用。

### 记账文件

```
/data/local/tmp/iwphone/state/
├── writers/<资源名>       # 一行一个写入者：模块名 \t 时间 \t 原始命令
├── owners/<资源名>        # 去重的模块名列表
├── snapshots/<资源名>     # L3 用的上一次值
├── conflicts.log          # 冲突与告警汇总
└── .audited_<资源名>      # L2 去重标记
```

同一模块重复写同一资源**只记一行**，避免长跑模块刷爆文件。

---

## 已知拦不住的情况（≈5%）

| 绕过方式 | 原因 |
|---|---|
| 显式绝对路径 `/system/bin/settings put ...` | 绕过 shell 函数查找 |
| `busybox settings` / `toybox settings` | 同上 |
| 模块自带的 native 二进制直接调 binder | 完全跳过 shell |
| `sh -c "..."` 子进程 | 新进程不继承函数 |

**兜底**：L3 值快照能在不知道"谁改的"的情况下，发现"值被改了"，仍会告警。

> 这些缺口在本项目语境下可接受 —— 模块是自己/可信来源写的，
> 要防的是**无意冲突**，不是恶意绕过。

---

## conflicts.log 格式

```
# L1 启动拦截
<时间>\t<想启动的模块>\t<占用者>\t<资源名>

# L2 记账冲突
<时间>\tWRITER_CONFLICT\t<资源名>:<模块1>,<模块2>

# L3 值漂移
<时间>\tVALUE_DRIFT\t<资源名>\t<旧值>-><新值>
```

---

## 查询接口（供 App / 终端调用）

```sh
. /data/local/tmp/iwphone/conflict.sh

# 某资源被哪些运行中的模块声明
conflict_lookup service.deviceidle

# 列出所有模块的资源占用（模块名<TAB>资源名）
conflict_list_all

# 手动跑一次审计
conflict_audit
```

---

## 部署清单

| 文件 | 状态 |
|---|---|
| `sandbox.sh` | 新增（记账沙箱） |
| `conflict.sh` | 新增（冲突仲裁库） |
| `core.sh` | 改（entry 副本注入 + wait 保活） |
| `iwphone.sh` | 改（启动前 check_conflict + 轮末 conflict_audit） |
| `mod_run.sh` | 改（启动前 check_conflict） |
| `mod_install.sh` | 改（自动提取 exclusive 声明） |

沙箱与冲突库在框架目录和 `IWPHONE_ROOT` 各放一份（模块可固定路径引用）。

备份：`/data/local/tmp/iwphone_fw_backup_20260917_2031.tar.gz`（46MB）

---

## 验证记录

| 用例 | 结果 |
|---|---|
| 无声明模块启动 | 放行 ✅ |
| 同资源 + 占用者运行中 | 拦截 + 写 conflicts.log ✅ |
| 资源不重合 | 放行 ✅ |
| group 冲突 | 拦截 ✅ |
| `settings put global x` 记账 | 归一化为 `global.x` ✅ |
| `setprop a.b` 记账 | 归一化为 `prop.a.b` ✅ |
| `dumpsys deviceidle enable` 记账 | 归一化为 `service.deviceidle` ✅ |
| 命令透传（原命令仍执行） | 输出正确 ✅ |
| 多写入者告警 | 触发 + 去重 ✅ |
| doze 模块常驻性 | 进程树正常保活 ✅ |
| 对真实模块自动提取 | 命中 `service.deviceidle` ✅ |
