#!/system/bin/sh
#
# Android 工具：文件 → 所有者 UID → 应用包名
# 用法：sh uid2pkg.sh <文件路径>
# 示例：sh uid2pkg.sh /sdcard/Android/data/com.tencent.mm/files/test.txt
#

# -------------------------- 参数与文件检查 --------------------------
if [ $# -lt 1 ]; then
    echo "❌ 用法：$0 <文件路径>"
    echo "   示例：$0 /sdcard/Android/data/com.tencent.mm/files/test.txt"
    exit 1
fi

FILE="$1"

if [ ! -e "$FILE" ]; then
    echo "❌ 文件不存在：$FILE"
    exit 1
fi

# -------------------------- 获取文件所有者 --------------------------
# 优先 stat -c %U（不依赖 ls 列对齐），失败再回退 ls -ld
OWNER=""
if command -v stat >/dev/null 2>&1; then
    OWNER=$(stat -c '%U' "$FILE" 2>/dev/null)
fi
if [ -z "$OWNER" ] || [ "$OWNER" = "?" ]; then
    OWNER=$(ls -ld "$FILE" 2>/dev/null | awk '{print $3}')
fi

if [ -z "$OWNER" ]; then
    echo "❌ 无法获取文件所有者（权限不足？请用 su 提权后重试）"
    exit 1
fi

echo "🔍 文件所有者：$OWNER"

# 交叉校验用：stat 直接给出的数字 UID
RAW_UID=""
if command -v stat >/dev/null 2>&1; then
    RAW_UID=$(stat -c '%u' "$FILE" 2>/dev/null)
    [ -n "$RAW_UID" ] && echo "   (stat 数字 UID：$RAW_UID)"
fi

# -------------------------- 所有者 → 数字 UID --------------------------
UID_VAL=""

# uX_aY 格式：Android 应用用户（含多用户 / 工作资料）
# 公式：uid = userId * 100000 + (10000 + appId)
#   u0_a302  → 0*100000 + 10000 + 302 = 10302
#   u10_a302 → 10*100000 + 10000 + 302 = 1010302
if echo "$OWNER" | grep -qE '^u[0-9]+_a[0-9]+$'; then
    USER_ID=$(echo "$OWNER" | sed -E 's/^u([0-9]+)_a[0-9]+$/\1/')
    APP_ID=$(echo "$OWNER" | sed -E 's/^u[0-9]+_a([0-9]+)$/\1/')
    UID_VAL=$(( USER_ID * 100000 + 10000 + APP_ID ))
    echo "🔢 转换后的 UID：$UID_VAL  (用户 $USER_ID，应用 ID $APP_ID)"

# 纯数字：直接使用
elif echo "$OWNER" | grep -qE '^[0-9]+$'; then
    UID_VAL="$OWNER"
    echo "🔢 转换后的 UID：$UID_VAL  (直接使用数字)"

# 系统内置用户：root/system/shell 等，无对应应用
elif echo "$OWNER" | grep -qE '^(root|system|shell|radio|bluetooth|nfc|gps|media|wifi|vpn|dhcp|graphics|audio|camera|input|account|fsync|kvm|nobody)$'; then
    echo "ℹ️ 所有者 [$OWNER] 是系统用户，无对应应用包名"
    exit 0

else
    echo "❌ 未知的所有者格式：$OWNER"
    exit 1
fi

# 与 stat 数字 UID 交叉校验，不一致则采用 stat 的（更权威）
if [ -n "$RAW_UID" ] && [ "$RAW_UID" != "$UID_VAL" ]; then
    echo "⚠️ 转换 UID($UID_VAL) 与 stat 数字 UID($RAW_UID) 不一致，改用 stat 的值"
    UID_VAL="$RAW_UID"
fi

# -------------------------- UID → 包名（多方法兜底） --------------------------
PACKAGE=""
METHOD=""

# 方法1：pm list packages --uid（最直接，Android 6+ 支持）
if [ -z "$PACKAGE" ]; then
    RAW=$(pm list packages --uid "$UID_VAL" 2>/dev/null)
    PKG=$(echo "$RAW" | sed -E 's/^package:([^ ]+)( uid:[0-9]+)?$/\1/' | grep -v '^$')
    if [ -n "$PKG" ]; then
        PACKAGE="$PKG"
        METHOD="pm list packages --uid"
    fi
fi

# 方法2：pm list packages -U 全量带 UID，再 grep（兼容性最好）
if [ -z "$PACKAGE" ]; then
    # 新版输出 "package:NAME uid:UID"，旧版输出 "package:NAME:UID"
    LINE=$(pm list packages -U 2>/dev/null | grep "uid:$UID_VAL")
    [ -z "$LINE" ] && LINE=$(pm list packages -U 2>/dev/null | grep ":$UID_VAL\$")
    if [ -n "$LINE" ]; then
        PKG=$(echo "$LINE" | sed -E 's/^package:([^ ]+)( uid:[0-9]+|:[0-9]+)$/\1/')
        if [ -n "$PKG" ]; then
            PACKAGE="$PKG"
            METHOD="pm list packages -U"
        fi
    fi
fi

# 方法3：dumpsys package 解析 userId=（最稳，但较慢）
if [ -z "$PACKAGE" ]; then
    PKG=$(dumpsys package packages 2>/dev/null | awk -v uid="$UID_VAL" '
        /Package \[/ {
            line=$0; sub(/.*Package \[/,"",line); sub(/\].*/,"",line); pkg=line
        }
        $0 ~ "userId=" uid "([^0-9]|$)" { if (pkg!="") { print pkg; exit } }
    ')
    if [ -n "$PKG" ]; then
        PACKAGE="$PKG"
        METHOD="dumpsys package"
    fi
fi

# -------------------------- 结果输出 --------------------------
if [ -z "$PACKAGE" ]; then
    echo "❌ 未找到 UID $UID_VAL 对应的应用包名"
    echo "   可能原因："
    echo "   1. 该 UID 不是应用 UID（如共享系统 UID、已卸载残留）"
    echo "   2. 设备策略限制 pm/dumpsys 查询（需 root/su）"
    echo "   3. 多用户/工作资料下 UID 换算异常"
    echo "   4. 应用已卸载但文件残留"
    exit 1
fi

echo "===================================="
echo "📄 目标文件：     $FILE"
echo "👤 文件所有者：   $OWNER (UID: $UID_VAL)"
echo "📦 对应应用：     $PACKAGE"
echo "🛠️  查询方式：    $METHOD"
echo "===================================="
