#!/system/bin/sh
# =====================================================
# iwphone modrunner v2 公共函数库
# 用法：各入口脚本先 source env.sh 再 source 本文件
# =====================================================

RUN_LOG="${LOG_ROOT_DIR}/modrunner_$(date +%Y%m%d).log"

# 框架运行日志（按天切割）
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$RUN_LOG"
    [ "$VERBOSE" -eq 1 ] && echo "$1"
    return 0
}

# 模块专属日志
module_log() {  # module_log <模块名> <消息>
    _m="$1"; shift
    _f="${LOG_ROOT_DIR}/modules/${_m}/${_m}.log"
    mkdir -p "$(dirname "$_f")" 2>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$_m] $1" >> "$_f"
    return 0
}

# 模块名合法性校验（防路径注入/空白注入）
validate_module() {
    _name="$1"
    [ -n "$_name" ] || { log "❌ 拒绝空模块名"; return 1; }
    [ "${#_name}" -le 64 ] || { log "❌ 拒绝超长模块名（>64字符）：$_name"; return 1; }
    case "$_name" in
        *..*|*/*) log "❌ 拒绝非法模块名：$_name（含路径符）"; return 1 ;;
    esac
    if echo "$_name" | grep -q '[[:space:]]'; then
        log "❌ 拒绝非法模块名：$_name（含空白字符）"
        return 1
    fi
    return 0
}

# 模块是否运行中（锁 = locks/{模块名} 目录，mkdir 原子操作，无竞态）
is_locked() {
    _lock="${LOCK_DIR}/$1"
    [ -d "$_lock" ] || return 1
    _pid=$(cat "${_lock}/pid" 2>/dev/null)
    # pid 文件为空 = 正在启动的瞬间，视为已锁定
    [ -z "$_pid" ] && return 0
    [ "$_pid" = "0" ] && return 0
    if ps -A -o pid= 2>/dev/null | grep -q "^[[:space:]]*${_pid}[[:space:]]*$"; then
        return 0
    fi
    # 持锁进程已退出 → 清理残留锁（崩溃自愈）
    rm -rf "$_lock"
    log "🧹 清理残留锁：$1"
    return 1
}

# 高危命令黑名单检查（含高危命令返回 1）
check_blacklist() {
    [ -n "$COMMAND_BLACKLIST" ] || return 0
    if grep -qE "$COMMAND_BLACKLIST" "$1" 2>/dev/null; then
        return 1
    fi
    return 0
}

# 后台启动模块（加锁 → 隔离环境 → 执行 → 记日志 → 超时保护 → 解锁）
#
# ★ 单模块运行时上限的三层优先级（由高到低）：
#   1. 模块 iwphone.prop 里的 `runtime=<秒>`   ← 模块自己说了算
#   2. 全局 env.sh 的 MAX_RUNTIME_SEC
#   3. 兜底 300
#
# 为什么需要模块级覆盖：全局 MAX_RUNTIME_SEC 默认 300 秒，
# 而**常驻型模块（while true 循环）会被它在 5 分钟时强杀** ——
# 更糟的是触发文件因 AUTO_CLEAN=1 已被删除，不会自动重启，
# 于是「模块静默失效、App 显示未运行」，用户完全无感知。
# 常驻模块应在 iwphone.prop 里声明 `runtime=0`（不限制）。
read_runtime_limit() {
    _rt_module="$1"
    _rt_prop="${WORK_DIR}/${_rt_module}/iwphone.prop"
    _rt_val=""

    if [ -f "$_rt_prop" ]; then
        # 只取第一次出现的 runtime=，并剥掉可能存在的引号
        _rt_val=$(
            sed -n 's/^[[:space:]]*runtime[[:space:]]*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' \
                "$_rt_prop" 2>/dev/null | head -n 1
        )
    fi

    # 声明了且是合法非负整数 → 用它
    case "$_rt_val" in
        ''|*[!0-9]*) ;;
        *) echo "$_rt_val"; return 0 ;;
    esac

    # 否则沿用全局（同样要求是非负整数，避免被污染成其它值）
    case "$MAX_RUNTIME_SEC" in
        ''|*[!0-9]*) echo 300 ;;
        *) echo "$MAX_RUNTIME_SEC" ;;
    esac
}


# =====================================================
# sbxbin：PATH 包装脚本（补函数包装的漏）
#
# 函数包装只拦得住「裸命令名」的调用；env / sh -c / command / 变量拼路径
# 这些走 PATH 解析的写法会绕过去（实测能绕过 4 种）。所以在 PATH 最前面
# 放一层真可执行的包装脚本，让它们也落到沙箱里（记账 + 写前快照）。
#
# 仍然拦不住的：绝对路径（/system/bin/settings）、native 二进制、直接 binder
# —— 这几类由兼容性预检在安装时明确提示。
# 幂等：首行版本戳一致就跳过，不重复写盘。
# =====================================================
ensure_sbxbin() {
    _dir="$SBXBIN_DIR"
    mkdir -p "$_dir" 2>/dev/null || return 0
    _script_dir=$(cd "$(dirname "$0")" && pwd)
    for _c in settings setprop dumpsys cmd svc device_config appops wm pm am; do
        _f="$_dir/$_c"
        if [ -f "$_f" ] && head -n1 "$_f" 2>/dev/null | grep -q "iwphone-sbxbin v1"; then
            continue
        fi
        {
            printf '%s\n' '#!/system/bin/sh'
            printf '%s\n' '# iwphone-sbxbin v1 —— 沙箱 PATH 包装（自动生成，勿手工编辑）'
            printf '%s\n' '# 拦下 env / sh -c / command / 变量拼路径等绕过函数包装的调用'
            printf 'IWPHONE_ROOT="%s"; export IWPHONE_ROOT\n' "$IWPHONE_ROOT"
            printf 'IWPHONE_SANDBOX="%s/sandbox.sh"; export IWPHONE_SANDBOX\n' "$_script_dir"
            printf '%s\n' 'SBX_NO_WRAP=1; export SBX_NO_WRAP'
            printf '%s\n' 'SBX_WRAPPER=1; export SBX_WRAPPER'
            printf '%s\n' 'SBX_REAL_DIR=/system/bin; export SBX_REAL_DIR'
            printf '%s\n' 'SBX_SYS_PATH=/system/bin:/system/xbin; export SBX_SYS_PATH'
            printf '%s\n' '. "$IWPHONE_SANDBOX"'
            printf '_sbx_dispatch %s "$@"\n' "$_c"
        } > "$_f" 2>/dev/null
        chmod 755 "$_f" 2>/dev/null
    done
    return 0
}

start_module() {
    _module="$1"
    # 执行器子 shell 的输出重定向到独立日志，stdin 接 /dev/null：
    # 避免执行器继承调用方的 stdout/stderr 管道，导致调用方（如 WebUI
    # 的 subprocess）在模块长跑期间一直被挂起
    _launch_log="${LOG_ROOT_DIR}/modules/${_module}/launcher.log"
    mkdir -p "${LOG_ROOT_DIR}/modules/${_module}" 2>/dev/null

    # ★ 模块进程的 stdout/stderr 必须落在原生文件系统（$MODIO_DIR）。
    #   若指向 LOG_ROOT_DIR（/sdcard，FUSE），cmd/settings 会因
    #   「fd 无法经 binder 传递」而报 Failed transaction 并静默失败。
    #   详见 env.sh 里 MODIO_DIR 的注释。
    _iodir="${MODIO_DIR}/${_module}"
    mkdir -p "$_iodir" 2>/dev/null
    # 保险：MODIO_DIR 万一被指到 /sdcard 上，退回 IWPHONE_ROOT 下的原生目录
    case "$_iodir" in
        /sdcard/*|/storage/*) _iodir="${IWPHONE_ROOT}/modio/${_module}"; mkdir -p "$_iodir" 2>/dev/null ;;
    esac
    _stdout_log="${_iodir}/${_module}.out"
    _stderr_log="${_iodir}/${_module}.err"
    : > "$_stdout_log" 2>/dev/null
    : > "$_stderr_log" 2>/dev/null

    # 本次执行的超时上限（模块级 runtime= 优先于全局）
    _runtime_limit=$(read_runtime_limit "$_module")
    (
        _lock="${LOCK_DIR}/${_module}"
        # 原子加锁：mkdir 成功 = 抢到锁，失败 = 已被占用
        mkdir "$_lock" 2>/dev/null || exit 1
        echo 0 > "${_lock}/pid"
        trap 'rm -rf "${_lock}"' EXIT

        _logdir="${LOG_ROOT_DIR}/modules/${_module}"
        mkdir -p "$_logdir" 2>/dev/null

        # 沙箱目录（模块专属 HOME / TMPDIR）
        _home="${TMP_DIR}/home_${_module}"
        _sbx="${TMP_DIR}/sb_${_module}"
        mkdir -p "$_home" "$_sbx" 2>/dev/null

        cd "${WORK_DIR}/${_module}" || exit 1

        module_log "$_module" "===== 执行开始 ====="

        # 启动模块；环境隔离通过 env 传递——只作用于 main.sh 进程，
        # 不污染执行器自身的环境（框架后续的日志/清理命令不受影响）
        #
        # IWPHONE_SANDBOX / IWPHONE_MODULE：模块身份与沙箱脚本路径
        _sbx_sh="${SCRIPT_DIR}/sandbox.sh"
        [ -f "$_sbx_sh" ] || _sbx_sh="${IWPHONE_ROOT}/sandbox.sh"

        # 生成注入沙箱的入口副本（不改模块原文件）：
        # 把 sandbox.sh 内容内联到 main.sh 之前，沙箱函数对模块可见。
        #
        # 两种模块写法都要正确跟踪存活：
        #   A. 前台常驻（while true 直接跑）→ entry 随 main.sh 一起活着
        #   B. 自我后台化（( ... )& 收尾）→ main.sh 部分立刻返回，
        #      若不 wait，entry 会立即退出，框架轮询误判"执行成功"
        #      （历史 bug 复发点）。故末尾必须 wait 住后台作业。
        # 确保 PATH 包装脚本就位（拦 env/sh -c/command 等绕过写法）
        ensure_sbxbin 2>/dev/null

        _entry="./.iwphone_entry.sh"
        if [ -f "$_sbx_sh" ] && [ -f "./main.sh" ]; then
            {
                printf 'IWPHONE_MODULE="%s"; export IWPHONE_MODULE\n' "$_module"
                printf 'IWPHONE_ROOT="%s"; export IWPHONE_ROOT\n' "$IWPHONE_ROOT"
                cat "$_sbx_sh" 2>/dev/null
                cat "./main.sh" 2>/dev/null
                printf '\n# 等待模块内部的后台作业（自我 daemon 化的模块依赖此行保活）\n'
                printf 'wait\n'
            } > "$_entry" 2>/dev/null
            # 生成失败/为空则回退原入口
            [ -s "$_entry" ] || { rm -f "$_entry" 2>/dev/null; _entry="./main.sh"; }
        else
            _entry="./main.sh"
        fi

        if [ "$PATH_ISOLATION" -eq 1 ]; then
            nohup env ANDROID_ROOT= LD_LIBRARY_PATH= \
                PATH="$SBXBIN_DIR:$SANDBOX_PATH" HOME="$_home" TMPDIR="$_sbx" \
                IWPHONE_ROOT="$IWPHONE_ROOT" \
                IWPHONE_MODULE="$_module" \
                IWPHONE_SANDBOX="$_sbx_sh" \
                sh "$_entry" >> "$_stdout_log" 2> "$_stderr_log" &
        else
            nohup env IWPHONE_ROOT="$IWPHONE_ROOT" \
                IWPHONE_MODULE="$_module" \
                IWPHONE_SANDBOX="$_sbx_sh" \
                sh "$_entry" >> "$_stdout_log" 2> "$_stderr_log" &
        fi
        _mpid=$!
        echo "$_mpid" > "${_lock}/pid"

        # 轮询等待 + 超时控制（在执行器自身进程内完成，不启动独立看门狗，
        # 避免看门狗的 sleep 子进程成为孤儿并长期持有 stdout 管道/进程表项）
        _elapsed=0
        _timed_out=0
        # 常驻模块声明 runtime=0 时不设上限，常驻到被手动停止为止
        while kill -0 "$_mpid" 2>/dev/null; do
            if [ "$_runtime_limit" -gt 0 ] && [ "$_elapsed" -ge "$_runtime_limit" ]; then
                _timed_out=1
                module_log "$_module" "⚠️ 执行超时（上限 ${_runtime_limit}s），强制终止"
                module_log "$_module" "   （常驻型模块请在 iwphone.prop 里声明 runtime=0）"
                kill -TERM "$_mpid" 2>/dev/null
                sleep 2
                kill -KILL "$_mpid" 2>/dev/null
                break
            fi
            sleep 1
            _elapsed=$((_elapsed + 1))
        done

        wait "$_mpid" 2>/dev/null
        _rc=$?

        if [ "$_timed_out" -eq 1 ]; then
            module_log "$_module" "❌ 执行失败（超时强杀）"
        elif [ "$_rc" -eq 0 ]; then
            module_log "$_module" "✅ 执行成功"
        else
            module_log "$_module" "❌ 执行失败（退出码 $_rc）"
            _errtail=$(tail -n 5 "$_stderr_log" 2>/dev/null)
            [ -n "$_errtail" ] && module_log "$_module" "错误尾部：${_errtail}"
        fi
        module_log "$_module" "===== 执行结束 ====="

        # 清理沙箱入口副本（模块已结束，副本无用了）
        [ "$_entry" = "./.iwphone_entry.sh" ] && rm -f "$_entry" 2>/dev/null

        rm -rf "$_lock"
        trap - EXIT
        exit "$_rc"
    ) >> "$_launch_log" 2>&1 < /dev/null &
    return 0
}
