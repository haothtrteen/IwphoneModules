#!/system/bin/sh
# =====================================================
# 停止 WebUI 服务
# 用法：sh webui_stop.sh
# =====================================================
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FRAME_DIR=$(dirname "$SCRIPT_DIR")
. "$FRAME_DIR/env.sh"

PIDF="$IWPHONE_ROOT/webui.pid"

if [ ! -f "$PIDF" ]; then
    echo "⚠️ WebUI 未在运行（PID 文件不存在）"
    exit 0
fi

PID=$(cat "$PIDF" 2>/dev/null)
if [ -n "$PID" ] && ps -A -o pid= 2>/dev/null | grep -q "^[[:space:]]*${PID}[[:space:]]*$"; then
    kill "$PID" 2>/dev/null
    sleep 0.5
    kill -9 "$PID" 2>/dev/null
    echo "✅ WebUI 已停止（PID $PID）"
else
    echo "⚠️ WebUI 进程已退出，清理残留 PID 文件"
fi
rm -f "$PIDF"
exit 0
