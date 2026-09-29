#!/system/bin/sh
# =====================================================
# iwphone conflict v1.1 · 模块资源冲突仲裁库
#
# 三层机制：
#   L1 声明式拦截：模块 iwphone.prop 声明 exclusive=<资源名,...>
#                  启动前与已运行模块的声明比对，冲突则拒绝启动
#   L2 运行时记账：sandbox.sh 记录的 writers/<资源名>，
#                  每轮扫描时比对，发现同一资源被多个模块写入则告警
#   L3 值快照兜底：对已声明资源每轮取一次值，发现被外部改写则告警
#
# v1.1 起支持「域.对象」多域资源名（与 sandbox.sh v2 对齐）：
#   global.* / system.* / secure.*  → settings get
#   prop.*                          → getprop
#   config.*                        → device_config get
#   service.*                       → dumpsys <svc> enabled
#   svc.*                           → 按域近似取值
#   display.*                       → wm size / density
#   appops.* / pkg.* / net.*        → 近似取值
#
# 依赖：env.sh 已 source；core.sh 提供 log() / module_log() / is_locked()
# 若 core.sh 未加载（单独调试本文件），用类型探测提供降级实现

if ! type log >/dev/null 2>&1; then
    log() { echo "[conflict] $1"; }
fi
if ! type module_log >/dev/null 2>&1; then
    module_log() { shift; echo "[module] $1"; }
fi
if ! type is_locked >/dev/null 2>&1; then
    is_locked() {
        _lk="${LOCK_DIR:-/data/local/tmp/iwphone/locks}/$1"
        [ -d "$_lk" ] || return 1
        _p=$(cat "${_lk}/pid" 2>/dev/null)
        [ -z "$_p" ] && return 0
        [ "$_p" = "0" ] && return 0
        ps -A -o pid= 2>/dev/null | grep -q "^[[:space:]]*${_p}[[:space:]]*$"
    }
fi
#
# 资源名格式（统一「域.对象」）：
#   settings put global foo   -> global.foo
#   setprop ro.foo 1          -> prop.ro.foo
#   dumpsys deviceidle xxx    -> service.deviceidle
#   cmd power set-mode        -> service.power
# =====================================================

CONFLICT_STATE="${IWPHONE_ROOT}/state"
CONFLICT_WRITERS="${CONFLICT_STATE}/writers"
CONFLICT_OWNERS="${CONFLICT_STATE}/owners"
CONFLICT_SNAP="${CONFLICT_STATE}/snapshots"
CONFLICT_LOG="${CONFLICT_STATE}/conflicts.log"

mkdir -p "$CONFLICT_WRITERS" "$CONFLICT_OWNERS" "$CONFLICT_SNAP" 2>/dev/null

# ---- 解析 iwphone.prop ----
# 格式：Key="值"（值可带引号），也兼容 Key=值
# 用法：read_prop <模块目录> <键名>
read_prop() {
    _dir="$1"; _key="$2"
    _prop="${_dir}/iwphone.prop"
    [ -f "$_prop" ] || return 1
    _v=$(grep -m1 "^${_key}=" "$_prop" 2>/dev/null | sed "s/^${_key}=//")
    [ -z "$_v" ] && return 1
    # 剥引号
    _v=$(printf '%s' "$_v" | sed 's/^"//; s/"[[:space:]]*$//')
    # 去首尾空白
    _v=$(printf '%s' "$_v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    printf '%s' "$_v"
}

# ---- 取模块声明的独占资源列表 ----
# 返回空格分隔的资源名（exclusive + exclusive.group 合并）
get_module_targets() {
    _dir="$1"
    _ex=$(read_prop "$_dir" exclusive)
    _grp=$(read_prop "$_dir" exclusive.group)
    _all=""
    for _t in $(printf '%s' "$_ex" | tr ',' ' '); do
        [ -n "$_t" ] && _all="${_all} ${_t}"
    done
    for _t in $(printf '%s' "$_grp" | tr ',' ' '); do
        [ -n "$_t" ] && _all="${_all} group:${_t}"
    done
    printf '%s' "$_all"
}

# ---- 运行中模块列表（有锁且进程活着）----
list_running_modules() {
    for _lock in "$LOCK_DIR"/*/; do
        [ -d "$_lock" ] || continue
        _m=$(basename "$_lock")
        [ -f "${WORK_DIR}/${_m}/main.sh" ] || continue
        is_locked "$_m" && printf '%s\n' "$_m"
    done
}

# ---- L1：启动前冲突检查 ----
# 用法：check_conflict <模块名>
# 返回 0 = 无冲突可启动；1 = 有冲突，已记日志
check_conflict() {
    _mod="$1"
    _mdir="${WORK_DIR}/${_mod}"
    _mine=$(get_module_targets "$_mdir")

    # 无声明 = 放行（向后兼容，不误伤老模块）
    if [ -z "$_mine" ]; then
        return 0
    fi

    for _t in $_mine; do
        # 遍历所有运行中的模块，看谁占了这个资源
        for _other in $(list_running_modules); do
            [ "$_other" = "$_mod" ] && continue
            _otheirs=$(get_module_targets "${WORK_DIR}/${_other}")
            [ -z "$_otheirs" ] && continue
            for _ot in $_otheirs; do
                if [ "$_ot" = "$_t" ]; then
                    _res="${_t#group:}"
                    log "⛔ 模块 $_mod 启动被拒绝：资源 '$_res' 已被 $_other 独占"
                    module_log "$_mod" "⛔ 启动被拒绝：资源 '$_res' 已被模块 '$_other' 占用"
                    module_log "$_mod" "   如需启动，请先停止 '$_other'，或修改本模块的 exclusive 声明"
                    printf '%s\t%s\t%s\t%s\n' \
                        "$(date '+%Y-%m-%d %H:%M:%S')" "$_mod" "$_other" "$_res" \
                        >> "$CONFLICT_LOG" 2>/dev/null
                    return 1
                fi
            done
        done
    done
    return 0
}

# ---- L2：运行时记账比对 ----
# 扫描 writers/ 目录，发现同一资源有多个模块写入则告警（去重）
audit_writers() {
    [ -d "$CONFLICT_WRITERS" ] || return 0
    for _f in "$CONFLICT_WRITERS"/*; do
        [ -f "$_f" ] || continue
        _res=$(basename "$_f")
        _n=$(cut -f1 "$_f" 2>/dev/null | sort -u | wc -l)
        [ "$_n" -le 1 ] && continue
        # 多模块写入 → 检查是否已告警过
        _seen="${CONFLICT_STATE}/.audited_${_res}"
        _sig=$(cut -f1 "$_f" 2>/dev/null | sort -u | tr '\n' ',')
        if [ -f "$_seen" ] && [ "$(cat "$_seen" 2>/dev/null)" = "$_sig" ]; then
            continue
        fi
        printf '%s' "$_sig" > "$_seen" 2>/dev/null
        _who=$(printf '%s' "$_sig" | sed 's/,$//')
        log "⚠️ 冲突告警：资源 '$_res' 被多个模块写入 → $_who"
        printf '%s\t%s\t%s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "WRITER_CONFLICT" "$_res:$_who" \
            >> "$CONFLICT_LOG" 2>/dev/null
    done
    return 0
}

# ---- L3：值快照兜底 ----
# 对已有 writers 记录的资源定期取值，发现值变化但无人记账 → 外部改动告警
# 只对「有模块声明/写入过」的资源做，避免全系统扫描
audit_snapshots() {
    [ -d "$CONFLICT_OWNERS" ] || return 0
    for _of in "$CONFLICT_OWNERS"/*; do
        [ -f "$_of" ] || continue
        _res=$(basename "$_of")
        _cur=$(_read_res_value "$_res")
        [ -z "$_cur" ] && continue
        _snapf="${CONFLICT_SNAP}/${_res}"
        _last=$(cat "$_snapf" 2>/dev/null)
        if [ -n "$_last" ] && [ "$_last" != "$_cur" ]; then
            _writers=$(tr '\n' ',' < "$_of" 2>/dev/null | sed 's/,$//')
            log "⚠️ 资源 '$_res' 值被外部改动：'$_last' → '$_cur'（已知写入者：$_writers）"
            printf '%s\t%s\t%s\t%s\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "VALUE_DRIFT" "$_res" "$_last->$_cur" \
                >> "$CONFLICT_LOG" 2>/dev/null
        fi
        printf '%s' "$_cur" > "$_snapf" 2>/dev/null
    done
    return 0
}

# ---- 读取资源当前值（按域分派）----
_read_res_value() {
    _res="$1"
    case "$_res" in
        global.*|system.*|secure.*)
            _ns="${_res%%.*}"; _k="${_res#*.}"
            settings get "$_ns" "$_k" 2>/dev/null
            ;;
        prop.*)
            getprop "${_res#prop.}" 2>/dev/null
            ;;
        config.*)
            # config.<namespace>.<key> → device_config get
            _ns=$(printf '%s' "${_res#config.}" | cut -d. -f1)
            _k=$(printf '%s' "${_res#config.}" | cut -d. -f2-)
            device_config get "$_ns" "$_k" 2>/dev/null | head -n1
            ;;
        service.*)
            # service 类资源取 enabled 状态作为"值"
            _svc="${_res#service.}"
            dumpsys "$_svc" enabled 2>/dev/null | head -n1
            ;;
        svc.*)
            # svc.<domain>.<verb> → 无稳定可读值，用 dumpsys 对应服务状态近似
            _dom=$(printf '%s' "${_res#svc.}" | cut -d. -f1)
            case "$_dom" in
                power) dumpsys power 2>/dev/null | grep -m1 -i 'mWakefulness\|mStayOn' ;;
                wifi)  dumpsys wifi 2>/dev/null | grep -m1 -i 'Wi-Fi is' ;;
                data)  dumpsys telephony.registry 2>/dev/null | grep -m1 -i 'mDataConnectionState' ;;
            esac
            ;;
        display.*)
            case "${_res#display.}" in
                size)    wm size 2>/dev/null | tail -n1 ;;
                density) wm density 2>/dev/null | tail -n1 ;;
            esac
            ;;
        appops.*)
            # appops.<pkg>.<op>：pkg 可能含 . 和 :，取第 2 段起、去掉最后一段
            _rest="${_res#appops.}"
            _pkg=$(printf '%s' "$_rest" | sed 's/\.[^.]*$//')
            [ -z "$_pkg" ] && _pkg="$_rest"
            appops get "$_pkg" 2>/dev/null | head -n1
            ;;
        pkg.*)
            _p="${_res#pkg.}"
            # 已启用状态（enabled/disabled）最易变化，作为快照值
            dumpsys package "$_p" 2>/dev/null | grep -m1 'enabled=' | sed 's/^[[:space:]]*//'
            ;;
        net.*)
            # 网络类资源粒度粗，取接口列表做快照
            _r="${_res#net.}"
            case "$_r" in
                link) ip -o link show 2>/dev/null | awk '{print $2}' | tr '\n' ',' ;;
                *)    ip -o addr show 2>/dev/null | awk '{print $4}' | tr '\n' ',' ;;
            esac
            ;;
    esac
}

# ---- 汇总入口：一轮扫描后调用 ----
conflict_audit() {
    audit_writers
    audit_snapshots
}

# ---- 查询：某资源被哪些模块声明（给 App / 终端用）----
# 用法：conflict_lookup <资源名>  → 输出模块名列表
conflict_lookup() {
    _res="$1"
    for _m in $(list_running_modules); do
        _targets=$(get_module_targets "${WORK_DIR}/${_m}")
        for _t in $_targets; do
            if [ "${_t#group:}" = "$_res" ]; then
                printf '%s\n' "$_m"
            fi
        done
    done
}

# ---- 列出所有声明的资源占用状态（给 App 用）----
# 输出：模块名<TAB>资源名 每行一条
conflict_list_all() {
    for _m in $(list_running_modules); do
        for _t in $(get_module_targets "${WORK_DIR}/${_m}"); do
            printf '%s\t%s\n' "$_m" "${_t#group:}"
        done
    done
}

return 0
