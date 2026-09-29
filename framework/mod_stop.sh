#!/system/bin/sh
# =====================================================
# 停止单个模块
# 用法：sh mod_stop.sh <模块名>
# =====================================================
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/env.sh"
. "$SCRIPT_DIR/core.sh"

MODULE_ID="$1"
if [ -z "$MODULE_ID" ]; then
    echo "用法：sh $0 <模块名>"
    exit 1
fi

LOCK="${LOCK_DIR}/${MODULE_ID}"
if [ ! -d "$LOCK" ]; then
    echo "⚠️ 模块 $MODULE_ID 未在运行"
    echo "   （常驻型模块若已脱离锁管理，可在其工作目录创建 end 文件使其自行退出）"
    exit 0
fi

PID=$(cat "$LOCK/pid" 2>/dev/null)
if [ -n "$PID" ] && [ "$PID" != "0" ]; then
    # 连带终止子进程（模块内启动的 sleep/循环等；pgrep -P 不可用时静默跳过）
    _children=$(pgrep -P "$PID" 2>/dev/null)
    kill -TERM "$PID" $_children 2>/dev/null
    sleep 1
    kill -KILL "$PID" $_children 2>/dev/null
    module_log "$MODULE_ID" "⏹️ 被手动停止（PID $PID）"
fi
rm -rf "$LOCK"
rm -f "${TMP_DIR}/${MODULE_ID}"
echo "✅ 模块 $MODULE_ID 已停止"
exit 0
