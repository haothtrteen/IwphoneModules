#!/system/bin/sh
# =====================================================
# 卸载框架：停止全部进程并删除所有目录
# 用法：sh uninstall.sh [y]   （带 y 跳过确认）
# =====================================================
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/env.sh"

if [ "$1" != "y" ]; then
    echo "将删除以下目录："
    echo "  $IWPHONE_ROOT （模块 / 锁 / 触发文件）"
    echo "  $LOG_ROOT_DIR （全部日志）"
    printf "确认卸载？(y/N) "
    read _ans
    [ "$_ans" = "y" ] || [ "$_ans" = "Y" ] || { echo "已取消"; exit 0; }
fi

# 先停止 WebUI、守护进程与所有模块
sh "$SCRIPT_DIR/webui/webui_stop.sh" >/dev/null 2>&1
sh "$SCRIPT_DIR/stop_runner.sh" all >/dev/null 2>&1

rm -rf "$IWPHONE_ROOT"
rm -rf "$LOG_ROOT_DIR"
rm -rf "$SDCARD_DIR/state"
echo "✅ 卸载完成"
exit 0
