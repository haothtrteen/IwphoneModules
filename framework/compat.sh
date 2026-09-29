#!/system/bin/sh
# =====================================================
# 兼容层：Magisk / KernelSU / AxManager 式模块的适配
#
# 这三类框架的模块结构高度一致（AxManager 明确兼容前两者的模块格式）：
#   module.prop      元信息（id=/name=/version=/author=/description=）
#   service.sh       常驻服务脚本（≈ 我们的 main.sh）
#   post-fs-data.sh  开机早期脚本（免 root 下没有这个阶段，开机时顺带跑）
#   action.sh        用户手动触发的动作（App 卡片上给个「动作」按钮）
#   uninstall.sh     卸载清理（我们本来就支持）
#   disable 旗标文件  存在则模块停用
#
# 适配方式（安装时一次性完成）：
#   1. module.prop 存在且没有 iwphone.prop → 由它生成 iwphone.prop
#   2. 没有 main.sh 但有 service.sh → 生成一个兼容入口 main.sh：
#      设好兼容环境变量（MODDIR 等）→ 顺带跑 post-fs-data.sh → exec service.sh
#   3. 其余交给现有流水线（exclusive 自动提取、配置、启停、日志）不受影响
#
# 明确不兼容（写进文档，不做假承诺）：
#   - Magisk 的 systemless 挂载（无 root 无 from-fs 阶段，根本做不到）
#   - webroot/ 每模块独立 WebUI（框架级 WebUI 只有一个，暂不挂载子路径）
#   - BusyBox standalone applet 假设：脚本里用到 busybox 特有 applet 会失败
# =====================================================

# 从 module.prop 读一个字段（去引号/空白/行内注释）
compat_prop() {
    _cp_file="$1"; _cp_key="$2"
    [ -f "$_cp_file" ] || return 0
    sed -n "s/^[[:space:]]*${_cp_key}[[:space:]]*=[[:space:]]*\"\{0,1\}\([^\"\n]*\)\"\{0,1\}[[:space:]]*\$/\1/p" \
        "$_cp_file" 2>/dev/null | head -n 1
}

# 判断并适配
compat_adapt() {
    _ca_dir="$1"
    _ca_mprop="${_ca_dir}/module.prop"
    _ca_iprop="${_ca_dir}/iwphone.prop"

    # 不是 Magisk/KernelSU/AxManager 式模块（没有 module.prop）→ 无事可做
    [ -f "$_ca_mprop" ] || return 0

    echo "   🔎 检测到 module.prop（Magisk/KernelSU/AxManager 式模块），启用兼容层"

    # ---- 1) 生成 iwphone.prop（保留模块自带字段，缺失的从 module.prop 补）----
    if [ ! -f "$_ca_iprop" ]; then
        _n=$(compat_prop "$_ca_mprop" name)
        _v=$(compat_prop "$_ca_mprop" version)
        _a=$(compat_prop "$_ca_mprop" author)
        _d=$(compat_prop "$_ca_mprop" description)
        {
            echo "name=\"${_n:-未命名}\""
            echo "version=\"${_v:-1.0}\""
            echo "author=\"${_a:-unknown}\""
            # description 可能很长/带引号，压成单行再写
            _d=$(printf '%s' "$_d" | tr -d '"\n\r')
            echo "description=\"${_d:-Magisk/KernelSU/AxManager 兼容模块}\""
            echo "compat=\"magisk,ksu,axmanager\""
            # 有 service.sh 即常驻型 → 不设运行时上限（见 core.sh 的 runtime= 语义）
            [ -f "${_ca_dir}/service.sh" ] && echo 'runtime="0"'
        } > "$_ca_iprop"
        echo "   ✍️  已由 module.prop 生成 iwphone.prop"
    fi

    # ---- 2) 没有入口脚本时生成兼容入口 ----
    if [ ! -f "${_ca_dir}/main.sh" ] && [ -f "${_ca_dir}/service.sh" ]; then
        cat > "${_ca_dir}/main.sh" <<'EOS'
#!/system/bin/sh
# =====================================================
# 兼容入口 —— 由 iwphone 兼容层在安装时自动生成
# 作用：把 Magisk/KernelSU/AxManager 式模块的 service.sh
#       接到本框架的启动流程上，并补齐它们假设存在的环境。
# 不要手工编辑本文件；重装模块时会重新生成。
# =====================================================
cd "$(dirname "$0")" || exit 1

# ---- 兼容环境 ----
# MODDIR：Magisk/KernelSU 式脚本普遍用它定位自己
MODDIR="$PWD"; export MODDIR
# AXERONDIR / AWK 等：AxManager 插件可能引用；指向本框架等价位置（尽力而为）
IWPHONE_ROOT="${IWPHONE_ROOT:-/data/local/tmp/iwphone}"
AXERONDIR="${IWPHONE_ROOT}/compat"; export AXERONDIR
mkdir -p "$AXERONDIR" 2>/dev/null

# ---- BusyBox applets ----
# Magisk/KernelSU/AxManager 式脚本的命令行为普遍假设 busybox 语义。
# 框架部署时已在 bin/ 下为全部 applet 建好符号链接，这里把 bin 放到 PATH
# 最前，让脚本优先拿到 busybox 版命令 —— 等效于 Magisk 的 standalone 效果。
# （只影响本模块进程；框架自身的脚本不受影响）
if [ -x "./bin/busybox" ]; then
    export PATH="$PWD/bin:$PATH"
fi

# disable 旗标：Magisk/KernelSU/AxManager 通用的停用机制
if [ -f "./disable" ]; then
    echo "[compat] disable 旗标存在，模块停用"
    exit 0
fi

# post-fs-data.sh：原语义是「开机挂载前」，免 root 下没有这个阶段。
# 折衷：启动时同步跑一次（失败不阻断），并明确告知语义差异。
if [ -f "./post-fs-data.sh" ]; then
    echo "[compat] 运行 post-fs-data.sh（注意：免 root 下无挂载前阶段，仅尽力执行）"
    sh ./post-fs-data.sh >/dev/null 2>&1
fi

# service.sh：模块主体（常驻服务）
if [ -f "./service.sh" ]; then
    exec sh ./service.sh
fi

echo "[compat] 模块没有 service.sh，无事可做"
exit 0
EOS
        chmod 755 "${_ca_dir}/main.sh"
        echo "   ✍️  已生成兼容入口 main.sh（service.sh → 本框架启动流程）"
    fi

    # ---- 3) 有 action.sh 的模块打标（App 卡片据此显示「动作」按钮）----
    if [ -f "${_ca_dir}/action.sh" ] && [ ! -f "${_ca_dir}/.has_action" ]; then
        : > "${_ca_dir}/.has_action"
        echo "   ✍️  检测到 action.sh —— App 卡片上将出现「动作」按钮"
    fi

    # ---- 4) 兼容性预检（结果给 App 展示；重装时覆盖重算）----
    compat_preflight "${_ca_dir}"
    if [ -f "${_ca_dir}/.compat_report" ]; then
        _pf_v=$(sed -n 's/^VERDICT=//p' "${_ca_dir}/.compat_report")
        echo "   🧪 兼容性预检：$_pf_v"
    fi

    return 0
}

# ------------------------------------------------------------
# 安装时预检：静态扫描脚本，给出兼容性判定与原因
#
# 结果写进 <模块>/.compat_report（KEY=VALUE），WebUI 与 App 读取展示。
# 这是兜底的核心：免 root 框架跑不了需要 root 的模块是客观事实，
# 与其让用户装完之后面对「显示运行中但没效果」，不如装完就给出明确的
# 「能/部分/不能」与原因 —— 失败至少要可见、可解释。
#
# 判定规则（保守，宁可误报为部分，不漏报）：
#   blocked  命中 root/Magisk 环境信号（mount、magisk、resetprop、setenforce、
#            su、nsenter、/data/adb/、$MAGISKTMP、$KSU）
#   ok       命中 shell 可执行信号（settings/dumpsys/cmd/svc/appops/pm/am）
#   unknown  两类都没命中 —— 看不出模块要干什么，需要用户自行确认
# 注意：只做静态文本扫描，注释里的词也会命中（误报方向安全）；漏报可能存在。
# ------------------------------------------------------------
compat_preflight() {
    _pf_dir="$1"
    _pf_report="${_pf_dir}/.compat_report"

    # 逐个脚本扫（不含我们生成的兼容入口 main.sh，避免自我命中）
    _pf_all=""
    for _pf_f in "$_pf_dir"/*.sh; do
        [ -f "$_pf_f" ] || continue
        case "$(basename "$_pf_f")" in
            main.sh) continue ;;   # 兼容入口是我们生成的
        esac
        # 剔除整行注释后再扫 —— 注释里的示例/说明词（如 "Magisk 式"）不该影响判定
        _pf_all="$_pf_all$(grep -v '^[[:space:]]*#' "$_pf_f" 2>/dev/null)\n"
    done

    _pf_cap=""
    [ -f "${_pf_dir}/service.sh" ]      && _pf_cap="${_pf_cap}service,"
    [ -f "${_pf_dir}/action.sh" ]       && _pf_cap="${_pf_cap}action,"
    [ -d  "${_pf_dir}/webroot" ]        && _pf_cap="${_pf_cap}webui,"
    [ -f "${_pf_dir}/post-fs-data.sh" ] && _pf_cap="${_pf_cap}post-fs-data,"
    _pf_cap=${_pf_cap%,}

    _pf_reasons=""

    # ---- root / Magisk 环境信号 ----
    _pf_hits=$(printf '%b' "$_pf_all" | grep -ioE \
      'mount[[:space:]]+(-[a-z]+[[:space:]]+)*(/|dev|proc|sys)|magisk|resetprop|setenforce|nsenter|/data/adb/|MAGISKTMP|\$KSU' \
      2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//')
    if [ -n "$_pf_hits" ]; then
        _pf_reasons="$_pf_reasons• 引用了 root/Magisk 环境（$_pf_hits）：免 root 无法执行\n"
        _pf_block="1"
    fi

    # ---- 独立的 su 调用（单独查，词边界避免误伤其它单词）----
    _pf_su=$(printf '%b' "$_pf_all" | grep -cE '(^|[;&|[:space:]])su([[:space:]]|\$)' 2>/dev/null)
    if [ "${_pf_su:-0}" -gt 0 ] 2>/dev/null; then
        _pf_reasons="$_pf_reasons• 有 $_pf_su 处调用 su：免 root 下会失败\n"
        _pf_block="1"
    fi

    # ---- shell 可执行信号（正面证据）----
    _pf_shell=$(printf '%b' "$_pf_all" | grep -icE \
      'settings[[:space:]]+(put|delete)|dumpsys[[:space:]]|cmd[[:space:]]|svc[[:space:]]|appops[[:space:]]|pm[[:space:]]+(disable|enable|clear|uninstall|install)|am[[:space:]]+(force-stop|kill|start)' \
      2>/dev/null)

    # ---- 沙箱覆盖度：静态扫描"沙箱拦不住"的写法 ----
    # 函数包装 + sbxbin PATH 包装能拦住裸命令名 / env / sh -c / command，
    # 但绝对路径与直接 binder 调用拦不住 —— 这类写法不会记账、也没有写前快照，
    # 打包时明确告知，别让用户以为"没效果"或"能还原"。
    _pf_bypass=$(printf '%b' "$_pf_all" | grep -oE '/(system|vendor|product)/bin/(settings|cmd|svc|pm|am|appops|dumpsys|setprop|device_config|wm)' 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//')
    if [ -n "$_pf_bypass" ]; then
        _pf_reasons="$_pf_reasons⚠ 有绝对路径调用（$_pf_bypass）：沙箱拦不到，不会记账、也没有写前快照\n"
    fi
    _pf_binder=$(printf '%b' "$_pf_all" | grep -cE 'service[[:space:]]+call|content[[:space:]]+(insert|update|call)' 2>/dev/null)
    [ "${_pf_binder:-0}" -gt 0 ] 2>/dev/null && \
        _pf_reasons="$_pf_reasons⚠ 有 $_pf_binder 处直接 binder/content 调用：同样绕过沙箱\n"

    if [ -n "$_pf_block" ]; then
        _pf_verdict="blocked"
    elif [ "${_pf_shell:-0}" -gt 0 ]; then
        _pf_verdict="ok"
        _pf_reasons="检测到 $_pf_shell 处 shell 级系统操作，均为免 root 可执行\n"
    else
        _pf_verdict="unknown"
        _pf_reasons="没有扫到已知的系统操作，无法自动判断（请结合模块说明确认）\n"
    fi

    {
        echo "VERDICT=$_pf_verdict"
        echo "CAP=$_pf_cap"
        printf '%b' "$_pf_reasons"
    } > "$_pf_report" 2>/dev/null
    return 0
}
