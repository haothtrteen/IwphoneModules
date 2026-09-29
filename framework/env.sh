#!/system/bin/sh
# =====================================================
# iwphone modrunner v3 统一配置（全部脚本共享）
# 支持环境变量临时覆盖，便于测试/迁移：
#   IWPHONE_ROOT=/tmp/test sh mod_run.sh demo
# =====================================================

# ---- 路径配置 ----
IWPHONE_ROOT="${IWPHONE_ROOT:-/data/local/tmp/iwphone}"   # 框架根目录（原生文件系统，锁操作可靠）
WORK_DIR="${WORK_DIR:-$IWPHONE_ROOT/work}"                # 模块安装目录：work/{模块名}/main.sh
TMP_DIR="${TMP_DIR:-$IWPHONE_ROOT/tmp}"                   # 触发文件目录：tmp/{模块名}
LOCK_DIR="${LOCK_DIR:-$IWPHONE_ROOT/locks}"               # 模块锁目录：locks/{模块名}/
PID_FILE="${PID_FILE:-$IWPHONE_ROOT/modrunner.pid}"       # 守护进程（Main.sh）PID 文件
LOG_ROOT_DIR="${LOG_ROOT_DIR:-/sdcard/iwphone/logs}"      # 日志根目录（放 sdcard 方便直接查看）

# ★ 模块进程的 stdout/stderr 落盘目录 —— **必须在原生文件系统上**。
#
# 原因（实测踩到）：`cmd` 及其包装命令（settings / dumpsys 的部分用法、
# appops 等）会**通过 binder 传递 stdin/stdout/stderr 的文件描述符**。
# 若 stdout 指向 /sdcard（FUSE）上的文件，该 fd 无法经 binder 传递，
# 结果是 `cmd: Failure calling service settings: Failed transaction (2147483646)`，
# 命令静默失败、退出码 2，而设置根本没改。
#
# 实测对照（同一条 `cmd settings put`）：
#   stdout → 管道            ✅ rc=0
#   stdout → /data/local/tmp ✅ rc=0
#   stdout → /dev/null       ✅ rc=0
#   stdout → /sdcard 文件    ❌ rc=2 Failed transaction
#
# 注意：只有「进程级 stdout/stderr 重定向」受影响。用 `>>` 追加写
# /sdcard 上的 .log 是普通文件写，不涉及 binder，不受影响。
MODIO_DIR="${MODIO_DIR:-$IWPHONE_ROOT/modio}"             # 模块 stdout/stderr（勿放 /sdcard）
SNAPSHOT_DIR="${SNAPSHOT_DIR:-$IWPHONE_ROOT/modsnap}"  # 写前快照（勿与 L3 的 state/snapshots 混用）

# ---- 运行行为 ----
POLL_SEC="${POLL_SEC:-15}"                 # 守护模式轮询间隔（秒）
MAX_PARALLEL="${MAX_PARALLEL:-0}"          # 最大同时运行模块数（0=不限制）
MAX_RUNTIME_SEC="${MAX_RUNTIME_SEC:-300}"  # 单模块超时秒数，超时强杀（0=不限制）
AUTO_CLEAN="${AUTO_CLEAN:-1}"              # 1=模块启动后自动删除触发文件
VERBOSE="${VERBOSE:-1}"                    # 1=日志同时输出到终端

# ---- 安全配置 ----
# 高危命令黑名单（ERE 正则，对模块 main.sh 全文扫描；置空 = 禁用检查）
# 已做词边界处理：含 "result"、"sum" 等单词的正常脚本不会被误杀
COMMAND_BLACKLIST="${COMMAND_BLACKLIST:-rm[[:space:]]+-[rfR]+[[:space:]]+/([[:space:]]|$)|setenforce[[:space:]]+0|remount.*rw|(^|[[:space:];&|])su([[:space:]]|$)}"
PATH_ISOLATION="${PATH_ISOLATION:-1}"      # 1=模块执行时隔离 PATH/HOME/TMPDIR 环境变量
SANDBOX_PATH="${SANDBOX_PATH:-/system/bin:/system/xbin}"  # 模块沙箱内的 PATH
SBXBIN_DIR="${SBXBIN_DIR:-$IWPHONE_ROOT/sbxbin}"   # PATH 包装脚本目录（拦 env/sh -c/command）
SBX_REAL_DIR="${SBX_REAL_DIR:-/system/bin}"        # 真实命令所在目录（沙箱用绝对路径调用，避免递归）
SBX_SYS_PATH="${SBX_SYS_PATH:-/system/bin:/system/xbin}"  # 调真实命令时的收敛 PATH

# ---- 控制通道（无 App 场景：/sdcard 命令文件）----
SDCARD_DIR="${SDCARD_DIR:-/sdcard/iwphone}"        # 用户命令区（命令文件 / 投递脚本 / 状态镜像）
CONTROL_ADBSH="${CONTROL_ADBSH:-1}"                # 1=允许 readbsh 执行投递脚本
                                                   # 注意：任何有存储权限的 App 均可触发，介意请置 0

# ---- 日志轮转（防止日志无限增长吃满存储）----
LOGROTATE_ENABLE="${LOGROTATE_ENABLE:-1}"              # 1=启用日志轮转
LOGROTATE_MAX_BYTES="${LOGROTATE_MAX_BYTES:-2097152}"  # 单文件上限（字节，默认 2MB）
LOGROTATE_KEEP_BYTES="${LOGROTATE_KEEP_BYTES:-524288}" # 超限时保留尾部（字节，默认 512KB）
LOGROTATE_KEEP_DAYS="${LOGROTATE_KEEP_DAYS:-7}"        # 框架按天日志保留天数（0=不删）
LOGROTATE_ORPHAN_DAYS="${LOGROTATE_ORPHAN_DAYS:-0}"    # 清理孤儿日志目录（0=关闭）
LOGROTATE_INTERVAL_SEC="${LOGROTATE_INTERVAL_SEC:-600}" # 两次轮转检查的间隔（秒）

# ---- WebUI ----
WEBUI_PORT="${WEBUI_PORT:-8537}"                   # WebUI 监听端口（仅绑定 127.0.0.1）
WEBUI_TOKEN="${WEBUI_TOKEN:-}"                     # 访问令牌（非空则要求 ?token= 或 X-Token 头）

# ---- 目录初始化（勿改）----
mkdir -p "$WORK_DIR" "$TMP_DIR" "$LOCK_DIR" "$LOG_ROOT_DIR" "$SDCARD_DIR" "$MODIO_DIR" "$SNAPSHOT_DIR" "$SBXBIN_DIR" 2>/dev/null
