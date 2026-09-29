#!/system/bin/sh
# =====================================================
# 安装模块包（.iwp = zip 格式）
# 用法：sh mod_install.sh <xxx.iwp路径 | 模块名>
#   传模块名时自动在本目录 module/ 下查找 <模块名>.iwp
# 安装后模块位于 work/{模块名}/，入口约定为 main.sh
# =====================================================
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/env.sh"

SRC="$1"
[ -z "$SRC" ] && { echo "用法：sh $0 <xxx.iwp路径|模块名>"; exit 1; }

# 定位 .iwp 文件
IPW=""
if [ -f "$SRC" ]; then
    IPW="$SRC"
elif [ -f "$SCRIPT_DIR/module/${SRC}.iwp" ]; then
    IPW="$SCRIPT_DIR/module/${SRC}.iwp"
elif [ -f "$SCRIPT_DIR/module/$SRC" ]; then
    IPW="$SCRIPT_DIR/module/$SRC"
else
    echo "❌ 找不到模块包：$SRC（也试过 $SCRIPT_DIR/module/${SRC}.iwp）"
    exit 1
fi

# 模块名 = 文件主名
NAME=$(basename "$IPW")
NAME="${NAME%.iwp}"

# 模块名校验（与运行器规则一致）
case "$NAME" in
    *..*|*/*) echo "❌ 非法模块名：$NAME"; exit 1 ;;
esac
if echo "$NAME" | grep -q '[[:space:]]'; then
    echo "❌ 模块名含空白字符，无法安装：$NAME"
    exit 1
fi

echo "📦 安装模块：$NAME ← $IPW"
unzip -o -q "$IPW" -d "${WORK_DIR}/${NAME}" || { echo "❌ 解压失败"; exit 1; }

echo "✅ 已安装到 ${WORK_DIR}/${NAME}/"

# ---- 兼容层：Magisk / KernelSU / AxManager 式模块适配 ----
# 这三类框架模块结构一致（module.prop + service.sh + action.sh + uninstall.sh）。
# 适配动作：由 module.prop 生成 iwphone.prop、生成兼容入口 main.sh、
#           给有 action.sh 的模块打标。见 compat.sh 里的说明。
. "$SCRIPT_DIR/compat.sh"
compat_adapt "${WORK_DIR}/${NAME}"

if [ -f "${WORK_DIR}/${NAME}/main.sh" ]; then
    echo "   入口 main.sh ✔  可通过 mod_run.sh 或触发文件启动"
else
    echo "   ⚠️ 未发现 main.sh（资源型模块：供其他脚本调用的工具/二进制）"
fi

# ---- 自动提取资源占用，写入 exclusive 声明（冲突检测用）----
# 从模块所有脚本中静态提取对系统配置的写操作，归一化为「域.对象」，
# 写进 iwphone.prop 的 exclusive=（仅在原文件未声明时写入，不覆盖人工声明）
#
# 提取规则与 sandbox.sh 的资源名归一化保持一致：
#   settings put|delete <ns> <key>   -> <ns>.<key>
#   setprop <key>                    -> prop.<key>
#   dumpsys <svc> <写动词>            -> service.<svc>
#   cmd <svc> <写动词>                -> service.<svc>
#   svc <domain> <verb>              -> svc.<domain>.<verb>
#   device_config put|delete <ns> <k> -> config.<ns>.<k>
#   appops set|start|stop            -> appops.<op>.<pkg>
#   wm size|density <val>            -> display.<sub>
#   pm disable|enable|... <pkg>      -> pkg.<pkg>
#   am force-stop|kill|start <pkg>   -> pkg.<pkg>
#
# 注意：只做静态文本提取，模块用变量拼的命令抓不到（漏报而非误报，可接受）
extract_targets() {
    _d="$1"
    grep -rhoE \
      'settings[[:space:]]+(put|delete)[[:space:]]+[a-z]+[[:space:]]+[A-Za-z0-9_.-]+'\
'|setprop[[:space:]]+[A-Za-z0-9_.-]+'\
'|dumpsys[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]+(enable|disable|force-idle|force-standby|unforce|step)'\
'|cmd[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]+(set-|force-|enable|disable|start|stop|reset)'\
'|svc[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]+(enable|disable|stayon|usb|nfc)'\
'|device_config[[:space:]]+(put|delete)[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]+[A-Za-z0-9_.-]+'\
'|appops[[:space:]]+(set|start|stop)[[:space:]]+[A-Za-z0-9_.:/-]+[[:space:]]+[A-Za-z0-9_.:-]+'\
'|wm[[:space:]]+(size|density)[[:space:]]+[A-Za-z0-9x]+'\
'|(pm|am)[[:space:]]+(disable-user|disable|enable|force-stop|kill|clear)[[:space:]]+[A-Za-z0-9_.]+' \
      "$_d"/*.sh 2>/dev/null | sort -u | while IFS= read -r _line; do
        _c=$(printf '%s' "$_line" | awk '{print $1}')
        case "$_c" in
            settings)
                printf '%s.%s\n' "$(printf '%s' "$_line" | awk '{print $3}')" \
                                 "$(printf '%s' "$_line" | awk '{print $4}')" ;;
            setprop)
                printf 'prop.%s\n' "$(printf '%s' "$_line" | awk '{print $2}')" ;;
            dumpsys|cmd)
                printf 'service.%s\n' "$(printf '%s' "$_line" | awk '{print $2}')" ;;
            svc)
                printf 'svc.%s.%s\n' "$(printf '%s' "$_line" | awk '{print $2}')" \
                                     "$(printf '%s' "$_line" | awk '{print $3}')" ;;
            device_config)
                printf 'config.%s.%s\n' "$(printf '%s' "$_line" | awk '{print $3}')" \
                                        "$(printf '%s' "$_line" | awk '{print $4}')" ;;
            appops)
                # 与 sandbox.sh 的 _sbx_norm_appops 保持一致：appops.<pkg>.<op>
                # _line = "appops set <pkg> <op>" → $3=pkg, $2=verb
                # 注意：sandbox 用 <pkg>.<op>，此处同样
                printf 'appops.%s.%s\n' "$(printf '%s' "$_line" | awk '{print $3}')" \
                                        "$(printf '%s' "$_line" | awk '{print $4}')" ;;
            wm)
                printf 'display.%s\n' "$(printf '%s' "$_line" | awk '{print $2}')" ;;
            pm|am)
                printf 'pkg.%s\n' "$(printf '%s' "$_line" | awk '{print $3}')" ;;
        esac
    done | grep -v '\.$' | grep -v '^\.' | sort -u
}

PROP="${WORK_DIR}/${NAME}/iwphone.prop"
# 只在该模块有脚本时提取
_has_script=0
for _f in "${WORK_DIR}/${NAME}"/*.sh; do
    [ -f "$_f" ] && _has_script=1 && break
done

if [ "$_has_script" -eq 1 ]; then
    _targets=$(extract_targets "${WORK_DIR}/${NAME}" | grep -v '^\.' | tr '\n' ',' | sed 's/,$//')
    if [ -n "$_targets" ]; then
        # 已有 exclusive= 声明则不覆盖（尊重人工声明）
        _existing=""
        [ -f "$PROP" ] && _existing=$(grep -m1 '^exclusive=' "$PROP" 2>/dev/null | sed 's/^exclusive=//' | tr -d '"')
        if [ -z "$_existing" ]; then
            if [ -f "$PROP" ]; then
                printf '\nexclusive="%s"\n' "$_targets" >> "$PROP"
            else
                printf 'exclusive="%s"\n' "$_targets" > "$PROP"
            fi
            echo "   🔒 已自动声明独占资源：$_targets"
        else
            echo "   🔒 独占资源（沿用已有声明）：$_existing"
        fi
    else
        echo "   🔓 未检测到系统配置写操作，无独占声明（不参与冲突检查）"
    fi
fi

# 打印模块元信息
if [ -f "$PROP" ]; then
    echo "   元信息："
    grep -E '^(PackageName|version|author|description|exclusive)=' "$PROP" | sed 's/^/     /'
fi
exit 0
