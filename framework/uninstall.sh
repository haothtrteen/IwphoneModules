#!/system/bin/sh
# =====================================================
# 卸载框架：停止全部进程并删除所有目录
# 用法：sh uninstall.sh [y]   （带 y 跳过确认）
# =====================================================
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/env.sh"

if [ "$1" != "y" ]; then
    echo "将删除以下目录："
    echo "  $IWPHONE_ROOT （框架代码 / 运行时 / 模块 / 锁 / 触发文件 / 快照）"
    echo "  $LOG_ROOT_DIR （全部日志）"
    printf "确认卸载？(y/N) "
    read _ans
    [ "$_ans" = "y" ] || [ "$_ans" = "Y" ] || { echo "已取消"; exit 0; }
fi

# 先停止 WebUI、守护进程与所有模块（这一步必须在本目录还存在时做完）
sh "$SCRIPT_DIR/webui/webui_stop.sh" >/dev/null 2>&1
sh "$SCRIPT_DIR/stop_runner.sh" all >/dev/null 2>&1

# ★ 本脚本就住在 $IWPHONE_ROOT 里面（代码与运行时同目录），直接 rm -rf
#   会把正在执行的自己删掉，之后 mksh 读不到下一行，后续清理全部失效。
#   所以交给一个脱离会话的进程延迟删除，本脚本立即正常退出。
nohup setsid -d sh -c "sleep 2; rm -rf '$IWPHONE_ROOT' '$LOG_ROOT_DIR' '$SDCARD_DIR/state'" \
    >/dev/null 2>&1 </dev/null &

echo "✅ 卸载已启动（约 2 秒后完成）"
echo "   删除：$IWPHONE_ROOT"
exit 0
