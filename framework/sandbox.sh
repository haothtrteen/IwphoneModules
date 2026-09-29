#!/system/bin/sh
# =====================================================
# iwphone sandbox v2 · 模块运行时记账沙箱（表驱动）
#
# 职责（只记账，不做拦截决策）：
#   把模块对系统配置的写操作，记录到
#     $IWPHONE_ROOT/state/writers/<资源名>
#   内容为一行一个写入者：<模块名>\t<时间戳>\t<原始命令>
#
# 设计约束：
#   - 不阻断任何命令，原样透传到 command 层执行（退出码/输出不变）
#   - 拦截失败（绝对路径/子进程/native）不影响主流程，
#     由 conflict.sh 的值快照做兜底
#   - 幂等：重复 source 只加载一次
#
# 本文件既可被 source，也可被内联进脚本顶层执行：
#   顶层语句里不能用裸 return，故用 if...else...fi 包裹。
#
# 扩展方式（加一个新命令）：
#   在 _SBX_SPECS 里加一行，并在 _sbx_res_of 里加一个分支即可。
#   规格格式：命令名:写动词正则
# =====================================================

if [ -n "$_IWPHONE_SANDBOX_LOADED" ]; then
    :
else
_IWPHONE_SANDBOX_LOADED=1

# ---- 定位框架根：优先用环境变量，其次推断 ----
if [ -z "$IWPHONE_ROOT" ]; then
    if [ -n "$IWPHONE_SANDBOX" ]; then
        IWPHONE_ROOT=$(dirname "$IWPHONE_SANDBOX")
    else
        IWPHONE_ROOT=/data/local/tmp/iwphone
    fi
fi

SBX_STATE="${IWPHONE_ROOT}/state"
SBX_WRITERS="${SBX_STATE}/writers"
SBX_OWNERS="${SBX_STATE}/owners"
SBX_MODULE="${IWPHONE_MODULE:-unknown}"
mkdir -p "$SBX_WRITERS" "$SBX_OWNERS" 2>/dev/null

# =====================================================
# 命令规格表（唯一的扩展点）
#   格式：<命令名>:<写动词正则>
#   正则匹配「命令之后的哪个参数」由 _sbx_verb_pos 决定：
#     verb_pos=1 → 看第 1 个参数（多数命令）
#     verb_pos=2 → 看第 2 个参数（如 dumpsys <svc> <verb>）
# =====================================================
_SBX_WRITE_RE='^(put|set|delete|remove|add|enable|disable|start|stop|force|reset|clear|create|destroy|step|unforce|force-idle|force-standby|set-.*|force-.*|unset|restore|override|reset-.*|grant|revoke|deny|allow|ignore|stayon|usb|nfc|airplane|data|gps|bluetooth|master)$'

# dumpsys 的写动词（第 2 参数）
_SBX_DUMPSYS_RE='^(enable|disable|force-idle|force-standby|unforce|step|set-.+|reset|clear|put|add|remove|ignore)$'

# cmd 的写动词（第 2 参数）
_SBX_CMD_RE='^(set-.+|force-.+|enable|disable|start|stop|reset|add|remove|clear|create|destroy|unset|restore|override|grant|revoke|put)$'

# =====================================================
# 资源名归一化：统一「域.对象」
# =====================================================
_sbx_norm_settings()      { [ -n "$1" ] && [ -n "$2" ] && printf '%s.%s' "$1" "$2"; }
_sbx_norm_prop()          { [ -n "$1" ] && printf 'prop.%s' "$1"; }
_sbx_norm_service()       { [ -n "$1" ] && printf 'service.%s' "$1"; }
_sbx_norm_config()        { [ -n "$1" ] && [ -n "$2" ] && printf 'config.%s.%s' "$1" "$2"; }
_sbx_norm_appops()        { [ -n "$1" ] && [ -n "$2" ] && printf 'appops.%s.%s' "$1" "$2"; }
_sbx_norm_svc()           {
    # svc <domain> <verb...>：把 domain + verb 组合成唯一资源名
    #   svc power stayon    -> svc.power.stayon
    #   svc wifi  disable   -> svc.wifi.disable
    #   svc data enable     -> svc.data.enable
    if [ -n "$1" ] && [ -n "$2" ]; then
        printf 'svc.%s.%s' "$1" "$2"
    elif [ -n "$1" ]; then
        printf 'svc.%s' "$1"
    fi
}
_sbx_norm_pkg()           { [ -n "$1" ] && printf 'pkg.%s' "$1"; }
_sbx_norm_wm()            { [ -n "$1" ] && printf 'display.%s' "$1"; }
_sbx_norm_net()           { [ -n "$1" ] && printf 'net.%s' "$(printf '%s' "$1" | tr '/:. ' '____')"; }

# =====================================================
# 记账核心
# =====================================================
# _sbx_record <资源名> <原始命令>
_sbx_record() {
    _res="$1"; shift
    [ -z "$_res" ] && return 0
    case "$_res" in .*|*..*) return 0 ;; esac   # 防路径注入
    _f="${SBX_WRITERS}/${_res}"
    # 同一模块重复写同一个资源只记一行（避免长跑模块刷爆文件）
    if [ -f "$_f" ] && grep -q "^${SBX_MODULE}	" "$_f" 2>/dev/null; then
        return 0
    fi
    printf '%s\t%s\t%s\n' "$SBX_MODULE" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$_f" 2>/dev/null
    return 0
}

# _sbx_owner_touch <资源名>
_sbx_owner_touch() {
    _res="$1"
    [ -z "$_res" ] && return 0
    case "$_res" in .*|*..*) return 0 ;; esac
    _of="${SBX_OWNERS}/${_res}"
    if [ -f "$_of" ] && grep -qx "$SBX_MODULE" "$_of" 2>/dev/null; then
        return 0
    fi
    printf '%s\n' "$SBX_MODULE" >> "$_of" 2>/dev/null
    return 0
}

# 记账一站式：给资源名，落 writers + owners
_sbx_note() {
    [ -z "$1" ] && return 0
    _sbx_record "$1" "$2"
    _sbx_owner_touch "$1"
    return 0
}

# =====================================================
# 资源名提取（按命令分派）
# 参数：命令名，以及该命令的完整参数列表
# =====================================================
_sbx_res_of() {
    _c="$1"; shift
    case "$_c" in
        settings)
            # settings put|delete <ns> <key> [value]
            _sbx_norm_settings "$2" "$3"
            ;;
        setprop)
            _sbx_norm_prop "$1"
            ;;
        dumpsys)
            _sbx_norm_service "$1"
            ;;
        cmd)
            # cmd settings put|delete <ns> <key> 与 settings 等价
            # （/system/bin/settings 本身就是这么实现的）—— 归一化到同一资源，
            # 否则会多出一条无意义的 service.settings 记录
            if [ "$1" = "settings" ]; then
                case "$2" in
                    put|delete)
                        _sbx_norm_settings "$3" "$4"
                        return 0
                        ;;
                esac
            fi
            _sbx_norm_service "$1"
            ;;
        svc)
            # svc <domain> <verb>：domain=power/wifi/data/usb/nfc
            _sbx_norm_svc "$1" "$2"
            ;;
        device_config)
            # device_config put|delete <namespace> <key> [value]
            _sbx_norm_config "$2" "$3"
            ;;
        appops)
            # appops set|start|stop [--user X] <pkg> <op> [mode]
            # $1 是动词（set/start/stop），跳过它和 --user 之类的选项，
            # 然后取 <pkg> <op>
            _pkg=""; _op=""; _skip=0; _first=1
            for _a in "$@"; do
                if [ "$_first" = "1" ]; then _first=0; continue; fi   # 跳过动词
                case "$_a" in
                    --*) _skip=1; continue ;;
                esac
                [ "$_skip" = "1" ] && { _skip=0; continue; }
                if [ -z "$_pkg" ]; then _pkg="$_a"
                elif [ -z "$_op" ]; then _op="$_a"; break
                fi
            done
            # 统一格式 appops.<pkg>.<op>，与 mod_install.sh 提取规则一致
            _sbx_norm_appops "$_pkg" "$_op"
            ;;
        wm)
            # wm size|density [WxH|DPI]  —— 无参数时是查询，不记
            case "$1" in
                size|density)
                    [ -n "$2" ] && _sbx_norm_wm "$1"
                    ;;
            esac
            ;;
        pm)
            # pm disable|enable|disable-user|set-* <pkg>
            case "$1" in
                disable|disable-user|enable|set-.+|clear|install|uninstall)
                    _sbx_norm_pkg "$2"
                    ;;
            esac
            ;;
        am)
            # am force-stop|kill|set-* <pkg>
            case "$1" in
                force-stop|kill|set-.+|start|broadcast|stopservice)
                    [ -n "$2" ] && _sbx_norm_pkg "$2"
                    ;;
            esac
            ;;
        ip|iptables|ip6tables|tc|ndc|ifconfig)
            # 只记有副作用的调用，资源名取前两个参数做粗粒度归类
            _sbx_norm_net "$1"
            ;;
    esac
}

# =====================================================
# 写动词判定：该调用是否为写操作
# =====================================================
_sbx_is_write() {
    _c="$1"; shift
    case "$_c" in
        settings)
            case "$1" in put|delete) return 0 ;; esac
            return 1
            ;;
        setprop)
            return 0   # setprop 永远是写
            ;;
        dumpsys)
            # 第 2 参数是动词
            _v="$2"
            # 带 -h/--help 或没有动词 → 查询
            [ -z "$_v" ] && return 1
            case "$_v" in -*) return 1 ;; esac
            printf '%s' "$_v" | grep -qE "$_SBX_DUMPSYS_RE" && return 0
            return 1
            ;;
        cmd)
            _v="$2"
            [ -z "$_v" ] && return 1
            printf '%s' "$_v" | grep -qE "$_SBX_CMD_RE" && return 0
            return 1
            ;;
        svc)
            # svc <name> <verb>；无 verb = 查询
            [ -z "$2" ] && return 1
            printf '%s' "$2" | grep -qE "$_SBX_WRITE_RE" && return 0
            return 1
            ;;
        device_config)
            case "$1" in put|delete|reset) return 0 ;; esac
            return 1
            ;;
        appops)
            case "$1" in set|start|stop|reset|write) return 0 ;; esac
            return 1
            ;;
        wm)
            case "$1" in size|density) [ -n "$2" ] && return 0 ;; esac
            return 1
            ;;
        pm)
            case "$1" in
                disable|disable-user|enable|clear|install|uninstall|set-*) return 0 ;;
            esac
            return 1
            ;;
        am)
            case "$1" in
                force-stop|kill|start|broadcast|stopservice|set-*) return 0 ;;
            esac
            return 1
            ;;
        ip)
            case "$1" in
                link|addr|route|rule|neigh)
                    # 只有带 set/add/del 才是写
                    printf '%s %s' "$2" "$3" | grep -qE '(set|add|del|change|replace)' && return 0
                    ;;
            esac
            return 1
            ;;
        iptables|ip6tables)
            # 默认是写；带 -L/-S/-C/--list 才是查询
            case "$1" in -L|-S|-C|--list|--check) return 1 ;; esac
            return 0
            ;;
        tc|ndc|ifconfig)
            return 0
            ;;
    esac
    return 1
}

# =====================================================
# 通用包装器生成
# 用法：_sbx_wrap <命令名>
# 定义同名 shell 函数：先记账判定 → 原样 command 执行
# =====================================================
_sbx_wrap() {
    eval "$1() { _sbx_dispatch '$1' \"\$@\"; }"
}

_sbx_dispatch() {
    _c="$1"; shift
    if _sbx_is_write "$_c" "$@"; then
        _r=$(_sbx_res_of "$_c" "$@")
        _sbx_note "$_r" "$_c $*"
        # ★ 写前快照：首次写某资源前记录原值/还原命令（App 可一键还原）。
        #   在"执行之前"读 —— 保证拿到的是写入前的状态。
        _sb_snap_maybe "$_r" "$_c" "$@"
    fi
    # ---- 执行真实命令 ----
    # 必须用**绝对路径**：PATH 里已有 sbxbin 包装脚本，用裸命令名会再命中
    # 包装脚本，重复记账甚至递归。执行时把 PATH 收敛为系统值，
    # 顺带避免真实命令（如 /system/bin/settings 内部调 cmd）被二次记账。
    _real="${SBX_REAL_DIR:-/system/bin}/$_c"
    if [ -x "$_real" ]; then
        if [ -n "$SBX_WRAPPER" ]; then
            # 包装脚本模式：本级没有后续逻辑，直接 exec 省一层进程
            PATH="${SBX_SYS_PATH:-/system/bin:/system/xbin}" exec "$_real" "$@"
        fi
        PATH="${SBX_SYS_PATH:-/system/bin:/system/xbin}" "$_real" "$@"
        return $?
    fi
    command "$_c" "$@"
}

# =====================================================
# 命令包装层（表驱动，逐个生成）
#
# SBX_NO_WRAP=1 时跳过 —— 那是「PATH 包装脚本」模式：包装脚本
# source 本文件只为拿函数，若这里再生成函数包装，函数会遮蔽真实命令。
# =====================================================
if [ -z "$SBX_NO_WRAP" ]; then

for _sbx_c in \
    settings setprop dumpsys cmd svc device_config appops \
    wm pm am \
    ip iptables ip6tables tc ndc
do
    _sbx_wrap "$_sbx_c"
done

# ---- eval：拦住 eval 字符串里藏的命令 ----
# 不阻止执行，只从字符串里静态提取可疑调用后记账
eval() {
    _s="$*"
    _hits=$(printf '%s\n' "$_s" | grep -oE '(settings[[:space:]]+(put|delete)[[:space:]]+[a-z]+[[:space:]]+[A-Za-z0-9_.-]+|setprop[[:space:]]+[A-Za-z0-9_.-]+|dumpsys[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]+(enable|disable|force-idle|force-standby|unforce|step)|cmd[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]+(set-|force-|enable|disable)|svc[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]+(enable|disable)|device_config[[:space:]]+(put|delete)[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]+[A-Za-z0-9_.-]+|appops[[:space:]]+(set|start|stop))' 2>/dev/null)
    if [ -n "$_hits" ]; then
        while IFS= read -r _h; do
            [ -z "$_h" ] && continue
            _r=$(_sbx_res_from_cmd "$_h")
            [ -n "$_r" ] && _sbx_note "$_r" "eval>$_h"
        done <<EOF
$_hits
EOF
    fi
    command eval "$@"
}

fi   # SBX_NO_WRAP 守卫结束

# 从命令行文本反推资源名（供 eval 使用）
# 参数是个完整命令字符串，需要拆词
_sbx_res_from_cmd() {
    _line="$1"
    # 用 set -- 拆词（值里有空格的场景在 eval 提取里本就不可靠，接受此局限）
    set -- $_line
    _c1="$1"; shift
    _sbx_res_of "$_c1" "$@"
}

# =====================================================
# 自检：可选打印加载信息
# =====================================================
if [ -n "$IWPHONE_SANDBOX_VERBOSE" ] && [ "$IWPHONE_SANDBOX_VERBOSE" -eq 1 ]; then
    echo "[sandbox] v2 已加载，模块=$SBX_MODULE，记账目录=$SBX_WRITERS" >&2
fi

fi
# 内联模式下到此结束；函数定义对后续模块脚本可见


# =====================================================
# ★ 写前快照（高价值兜底）
#
# 模块首次写入某资源前，把该资源的"原值/还原命令"记进
# $SNAPSHOT_DIR/<模块>.snap —— 之后 App 一键重放即可把系统资源
# 还原到模块动手之前的状态。模块改坏设置不再是不可逆的。
#
# 只在「首次写该资源」时记录（[资源名] 标记去重），因此几乎零开销。
# 支持：settings（完整还原）、appops（按旧 mode）、svc wifi/data（查
# wifi_on/mobile_data 决定方向）、pm disable（enable 回去）、
# deviceidle 的 force-idle/disable/enable（映射反向动词）。
# 其余（am force-stop、cmd 未知动词等）如实记为"不可自动还原"。
# =====================================================




# 生成一条可直接执行的"还原命令"；无法自动还原的输出注释行（如实记录）



# =====================================================
# ★ 写前快照（高价值兜底）
#
# 模块首次写入某资源前，把该资源的"原值/还原命令"记进
# $SNAPSHOT_DIR/<模块>.snap —— 之后 App 一键重放即可把系统资源
# 还原到模块动手之前的状态。模块改坏设置不再是不可逆的。
#
# 只在「首次写该资源」时记录（[资源名] 标记去重），因此几乎零开销。
# 支持：settings（完整还原）、appops（按旧 mode）、svc wifi/data（查
# wifi_on/mobile_data 决定方向）、pm disable（enable 回去）、
# deviceidle 的 force-idle/disable/enable（映射反向动词）。
# 其余（am force-stop、cmd 未知动词等）如实记为"不可自动还原"。
# 注意：目录是 $SNAPSHOT_DIR（modsnap）——不要用 state/snapshots，
# 那是冲突检测 L3 的值快照目录，语义完全不同。
# =====================================================




# 生成一条可直接执行的"还原命令"；无法自动还原的输出注释行（如实记录）


# =====================================================
# ★ 写前快照：模块首次写某资源前记录原值，App 可一键重放还原。
# 目录 $SNAPSHOT_DIR（modsnap）—— 与 L3 冲突检测的 state/snapshots 无关。
# =====================================================
_sb_snap_dir() {
    printf '%s' "${SNAPSHOT_DIR:-$IWPHONE_ROOT/modsnap}"
}

_sb_snap_file() {
    [ -n "$IWPHONE_MODULE" ] || return 1
    printf '%s/%s.snap' "$(_sb_snap_dir)" "$IWPHONE_MODULE"
}

_sb_snap_done() {
    _sf="$1"
    _snapf=$(_sb_snap_file) || return 1
    [ -f "$_snapf" ] && grep -Fq "[$_sf]" "$_snapf" 2>/dev/null
}

_sb_snap_put() {
    _sf="$1"; _line="$2"
    _snapf=$(_sb_snap_file) || return 0
    mkdir -p "$(_sb_snap_dir)" 2>/dev/null
    printf '%s\n' "$_line" >> "$_snapf" 2>/dev/null
}

_sb_snap_restore_cmd() {
    _r="$1"; _c="$2"; shift 2
    case "$_c" in
        settings)
            shift            # 跳过 put / delete 动词
            _ns="$1"; _key="$2"
            _old=$(command settings get "$_ns" "$_key" 2>/dev/null | tr -d '\r')
            if [ -z "$_old" ] || [ "$_old" = "null" ]; then
                printf "settings delete %s %s" "$_ns" "$_key"
            else
                _esc=$(printf '%s' "$_old" | sed "s/'/'\\''/g")
                printf "settings put %s %s '%s'" "$_ns" "$_key" "$_esc"
            fi
            ;;
        setprop)
            _key="$1"
            _old=$(getprop "$_key" 2>/dev/null | tr -d '\r')
            printf "setprop %s '%s'" "$_key" "$_old"
            ;;
        svc)
            _d="$1"; _v="$2"
            case "$_d" in
                wifi)
                    _w=$(command settings get global wifi_on 2>/dev/null | tr -d '\r')
                    if [ "$_w" = "0" ]; then printf "svc wifi disable"; else printf "svc wifi enable"; fi ;;
                data)
                    _m=$(command settings get global mobile_data 2>/dev/null | tr -d '\r')
                    if [ "$_m" = "0" ]; then printf "svc data disable"; else printf "svc data enable"; fi ;;
                *)
                    printf "# 不可自动还原: svc %s %s" "$_d" "$_v" ;;
            esac
            ;;
        pm)
            _v="$1"; _pkg="$2"
            case "$_v" in
                disable|disable-user)
                    if command pm list packages -d 2>/dev/null | grep -Fq "package:$_pkg"; then
                        printf "# 原本即禁用: pm %s %s" "$_v" "$_pkg"
                    else
                        printf "pm enable %s" "$_pkg"
                    fi ;;
                enable)
                    printf "# 原本即启用: pm enable %s" "$_pkg" ;;
                *)
                    printf "# 不可自动还原: pm %s %s" "$_v" "$_pkg" ;;
            esac
            ;;
        appops)
            shift            # 跳过 set 动词
            _pkg="$1"; _op="$2"
            _old=$(appops get "$_pkg" "$_op" 2>/dev/null | grep -m1 ': ' | sed 's/.*: *//' | tr -d '\r')
            if [ -n "$_old" ]; then
                printf "appops set %s %s %s" "$_pkg" "$_op" "$_old"
            else
                printf "# 不可自动还原: appops %s %s" "$_pkg" "$_op"
            fi
            ;;
        cmd)
            _svc="$1"; _verb="$2"
            case "$_svc" in
                deviceidle)
                    case "$_verb" in
                        force-idle) printf "dumpsys deviceidle unforce" ;;
                        disable)    printf "cmd deviceidle enable" ;;
                        enable)     printf "cmd deviceidle disable" ;;
                        *)          printf "# 不可自动还原: cmd deviceidle %s" "$_verb" ;;
                    esac
                    ;;
                *)
                    printf "# 不可自动还原: cmd %s %s" "$_svc" "$_verb" ;;
            esac
            ;;
        *)
            printf "# 不可自动还原: %s %s" "$_c" "$*" ;;
    esac
}

_sb_snap_maybe() {
    _r="$1"; _c="$2"; shift 2
    _snapf=$(_sb_snap_file) || return 0
    _sb_snap_done "$_r" && return 0
    _line=$(_sb_snap_restore_cmd "$_r" "$_c" "$@" 2>/dev/null)
    # 标记放在行尾注释里 —— 这样整行本身就是可直接执行的还原命令，
    # 同时 [资源名] 仍可用于去重（早期放在行首导致该行无法执行，是个设计错误）
    [ -n "$_line" ] && _sb_snap_put "$_r" "$_line   # [$_r]"
    return 0
}
