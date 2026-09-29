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

# =====================================================
# 包内容审计（解压前）：挡住 zip 里的路径穿越
#
# zip 条目名可以是 `../../x`、`/abs/path`，甚至是指向外部目录的符号链接 ——
# 直接 `unzip -d 目标目录` 会写到目标之外。模块名本身有校验，但**包内条目**
# 之前完全没扫，这是个真实缺口。
#
# 三层策略（尽量准，环境不全也不至于装不上）：
#   1) 框架自带的 Python —— 能拿到原始条目名 + ZIP 里的符号链接目标，最可靠
#   2) `unzip -Z1` 列条目 + grep 危险模式
#   3) 两者都没有 → 明确警告后放行（不假装校验过）
# 判定：有危险条目 → **拒绝安装**（这是明显的恶意/损坏包信号）
# =====================================================
audit_zip() {
    _z="$1"
    _py="$SCRIPT_DIR/webui/runtime/bin/python3.12"

    if [ -x "$_py" ]; then
        _out=$("$_py" -c 'import sys,zipfile,stat
bad=[]
try:
    z=zipfile.ZipFile(sys.argv[1])
except Exception as e:
    print("AUDIT_ERROR:"+str(e)); sys.exit(2)
for n in z.namelist():
    if n.startswith("/") or "\\" in n or ".." in n.split("/"):
        bad.append("path: "+n); continue
    try:
        info=z.getinfo(n)
    except Exception:
        continue
    mode=info.external_attr >> 16
    if stat.S_ISLNK(mode):
        try:
            tgt=z.read(n).decode("utf-8","replace").strip()
        except Exception:
            tgt=""
        if tgt.startswith("/") or ".." in tgt.split("/"):
            bad.append("link: "+n+" -> "+tgt)
for b in bad[:8]:
    print(b)
sys.exit(1 if bad else 0)' "$_z" 2>/dev/null)
        _rc=$?
        if [ "$_rc" -eq 0 ]; then
            return 0
        elif [ "$_rc" -eq 1 ]; then
            echo "❌ 模块包内含非法条目，已拒绝安装："
            printf '   %s\n' "$_out"
            echo "   （合法模块包不应含绝对路径、.. 逃逸或指向外部的符号链接）"
            return 1
        fi
        # 2/3 的情况：Python 读不了这个包，往下走退路
    fi

    _list=$(unzip -Z1 "$_z" 2>/dev/null)
    if [ -z "$_list" ]; then
        _list=$(unzip -l "$_z" 2>/dev/null | awk 'NR>3 && NF>=4 {print $NF}')
    fi
    if [ -z "$_list" ]; then
        echo "⚠️ 无法读取包内清单，跳过条目审计（请自行确认包来源可信）"
        return 0
    fi
    _bad=$(printf '%s\n' "$_list" | grep -E '(^/)|(^|/)\.\.(/|$)|\\' | head -5)
    if [ -n "$_bad" ]; then
        echo "❌ 模块包内含非法条目，已拒绝安装："
        printf '   %s\n' "$_bad"
        return 1
    fi
    return 0
}

echo "📦 安装模块：$NAME ← $IPW"

# 解压前审计包内条目（挡路径穿越 / 逃逸符号链接）
audit_zip "$IPW" || exit 1

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
