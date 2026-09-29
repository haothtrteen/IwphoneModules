#!/system/bin/sh
# =====================================================
# 停止守护进程 / 模块
# 用法：
#   sh stop_runner.sh           只停守护进程 Main.sh（模块继续运行）
#   sh stop_runner.sh modules   只停所有运行中的模块（守护继续运行）
#   sh stop_runner.sh all       停守护进程 + 所有模块
# =====================================================
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/env.sh"
. "$SCRIPT_DIR/core.sh"

# 判断进程是否仍存在（用 /proc，免受 ps 输出格式影响）
alive() {
    [ -d "/proc/$1" ]
}

stop_daemon() {
    if [ ! -f "$PID_FILE" ]; then
        echo "⚠️ 未发现守护进程（PID 文件不存在）"
        return 0
    fi
    PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$PID" ] && ps -A -o pid= 2>/dev/null | grep -q "^[[:space:]]*${PID}[[:space:]]*$"; then
        kill "$PID" 2>/dev/null
        # Main.sh 的循环末尾是 sleep POLL_SEC（默认 15s）。
        # shell 要等当前这条外部命令结束后才会处理 trap，
        # 所以发完信号必须等进程真正退出，否则会出现"显示已停止、实际还在跑"。
        # 这里最多等 4 秒，仍不退则强制终止。
        _n=0
        while [ "$_n" -lt 8 ] && alive "$PID"; do
            sleep 0.5
            _n=$((_n + 1))
        done
        if alive "$PID"; then
            kill -9 "$PID" 2>/dev/null
            # SIGKILL 之后进程不会立刻从 /proc 消失，需轮询确认，
            # 否则会误报"无法停止"（其实已经停掉了）。
            _n=0
            while [ "$_n" -lt 15 ] && alive "$PID"; do
                sleep 0.2
                _n=$((_n + 1))
            done
            if alive "$PID"; then
                echo "❌ 无法停止守护进程（PID $PID，已尝试强制终止）"
            else
                echo "✅ 已强制停止守护进程（PID $PID）"
            fi
        else
            echo "✅ 已停止守护进程（PID $PID）"
        fi
    else
        echo "⚠️ 守护进程未在运行，清理残留 PID 文件"
    fi
    rm -f "$PID_FILE"
    return 0
}

stop_modules() {
    echo "🔄 停止所有运行中的模块..."
    for _lock in "$LOCK_DIR"/*; do
        [ -d "$_lock" ] || continue
        _m=$(basename "$_lock")
        sh "$SCRIPT_DIR/mod_stop.sh" "$_m"
    done
    return 0
}

case "$1" in
    "")      stop_daemon ;;
    modules) stop_modules ;;
    all)     stop_daemon; stop_modules ;;
    *)       echo "用法：sh $0 [modules|all]"; exit 1 ;;
esac
exit 0
