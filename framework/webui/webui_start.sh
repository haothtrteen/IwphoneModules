#!/system/bin/sh
# =====================================================
# 启动 WebUI 服务（Python3 标准库，零第三方依赖）
#
# 用法：sh webui/webui_start.sh
#
# 解释器选择优先级：
#   1) $PYTHON_BIN        —— 用户手动指定（调试/自定义路径）
#   2) webui/runtime/     —— 内置静态 Python（离线可用，推荐）
#   3) 系统 python3       —— Termux 等已安装 Python 的环境
# 若 2 存在但与本机 CPU 架构不符（或文件损坏），自动降级到 3。
#
# 可选环境变量：
#   PYTHON_BIN=<路径>     强制指定解释器
#   WEBUI_PORT=8537       监听端口
#   WEBUI_TOKEN=xxx       访问令牌
# =====================================================
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FRAME_DIR=$(dirname "$SCRIPT_DIR")
. "$FRAME_DIR/env.sh"

PIDF="$IWPHONE_ROOT/webui.pid"
RTDIR="$SCRIPT_DIR/runtime"

# -----------------------------------------------------
# 选择可用的 Python 解释器
# 输出：解释器绝对路径；找不到则输出空
# -----------------------------------------------------
pick_python() {
    # 1) 用户指定
    if [ -n "$PYTHON_BIN" ]; then
        if [ -x "$PYTHON_BIN" ] && "$PYTHON_BIN" -c '' >/dev/null 2>&1; then
            echo "$PYTHON_BIN"
            return 0
        fi
        echo "⚠️  指定的 PYTHON_BIN 不可用：$PYTHON_BIN" >&2
    fi

    # 2) 内置运行时（首次使用时补执行权限；zip 解压可能丢失权限或软链接）
    for _name in python3 python3.12 python; do
        _rt="$RTDIR/bin/$_name"
        [ -f "$_rt" ] || continue
        [ -x "$_rt" ] || chmod 755 "$_rt" 2>/dev/null
        if [ -x "$_rt" ] && "$_rt" -c '' >/dev/null 2>&1; then
            echo "$_rt"
            return 0
        fi
    done
    if [ -d "$RTDIR/bin" ]; then
        echo "⚠️  内置运行时不可用（CPU 架构不匹配或文件损坏），尝试系统 python3" >&2
    fi

    # 3) 系统 python3
    if command -v python3 >/dev/null 2>&1; then
        if python3 -c '' >/dev/null 2>&1; then
            command -v python3
            return 0
        fi
    fi
    return 1
}

PY=$(pick_python)

if [ -z "$PY" ]; then
    echo "❌ 未找到可用的 Python3 解释器"
    echo "   方案 A：使用内置运行时的分发包（webui/runtime 目录）"
    echo "   方案 B：Termux 中执行 pkg install python"
    echo "   方案 C：在电脑/Termux 上执行 sh tools/build_runtime.sh 生成运行时后拷入"
    exit 1
fi

# 已在运行则直接提示
if [ -f "$PIDF" ]; then
    _old=$(cat "$PIDF" 2>/dev/null)
    if [ -n "$_old" ] && ps -A -o pid= 2>/dev/null | grep -q "^[[:space:]]*${_old}[[:space:]]*$"; then
        echo "⚠️  WebUI 已在运行（PID $_old）：http://127.0.0.1:${WEBUI_PORT}"
        exit 0
    fi
    rm -f "$PIDF"
fi

LOGF="$LOG_ROOT_DIR/webui.log"
mkdir -p "$LOG_ROOT_DIR" 2>/dev/null

# 解释器来源标注（便于排障）
case "$PY" in
    "$RTDIR"/*) _src="内置运行时" ;;
    "$PYTHON_BIN") _src="PYTHON_BIN 指定" ;;
    *) _src="系统 python3" ;;
esac

nohup "$PY" "$SCRIPT_DIR/webui_server.py" >> "$LOGF" 2>&1 &
echo $! > "$PIDF"
sleep 1

if ! ps -A -o pid= 2>/dev/null | grep -q "^[[:space:]]*$(cat "$PIDF")[[:space:]]*$"; then
    echo "❌ WebUI 启动失败（$_src），日志：$LOGF"
    tail -n 5 "$LOGF" 2>/dev/null
    rm -f "$PIDF"
    exit 1
fi

_pyver=$("$PY" -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null)

echo "✅ WebUI 已启动（PID $(cat "$PIDF")）"
echo "   解释器：    $_src  Python $_pyver"
echo "   设备浏览器：http://127.0.0.1:${WEBUI_PORT}"
echo "   电脑访问：  adb forward tcp:${WEBUI_PORT} tcp:${WEBUI_PORT} 后打开 http://127.0.0.1:${WEBUI_PORT}"
[ -n "$WEBUI_TOKEN" ] && echo "   访问令牌：  ?token=${WEBUI_TOKEN}"
exit 0
