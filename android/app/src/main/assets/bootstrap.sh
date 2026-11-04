#!/system/bin/sh
# =====================================================
# Shell Manager 框架激活脚本
#
# 由 App 导出到：
#   /sdcard/Android/data/com.shellmgr.shell_manager/files/bootstrap.sh
#
# 用法一（电脑，推荐）：
#   adb shell sh /sdcard/Android/data/com.shellmgr.shell_manager/files/bootstrap.sh
#
# 用法二（root）：
#   su -c "sh /sdcard/Android/data/com.shellmgr.shell_manager/files/bootstrap.sh"
#
# 作用：解压同目录的 framework.bin，补权限，以 shell 身份拉起守护进程。
# 不会修改系统分区，也不会改动 adb 授权列表。
# =====================================================

_SELF_DIR=$(cd "$(dirname "$0")" && pwd)
_SRC="$_SELF_DIR/framework.bin"
_ROOT="/data/local/tmp"
_DEST="$_ROOT/iwphone"

if [ ! -f "$_SRC" ]; then
    echo "❌ 找不到框架包：$_SRC"
    echo "   请先在 App 里点「电脑 adb 激活」，让它导出文件。"
    exit 1
fi

echo "⏳ 解压框架到 $_DEST …"
mkdir -p "$_ROOT" || { echo "❌ 无法创建 $_ROOT"; exit 1; }
tar xzf "$_SRC" -C "$_ROOT" || { echo "❌ 解压失败"; exit 1; }

# 框架以 shell 身份运行：属主与权限都要让 shell 能读写。
# root 执行时文件属主会是 root，必须改回来，否则 shell 启动时会写不了
# tmp/ 与 locks/。
if [ "$(id -u)" = "0" ]; then
    chown -R shell:shell "$_DEST" 2>/dev/null
fi
chmod -R 777 "$_DEST" 2>/dev/null
mkdir -p "$_DEST/state" "$_DEST/modsnap" 2>/dev/null

# busybox applet 链接
if [ -x "$_DEST/bin/busybox" ]; then
    cd "$_DEST/bin" || exit 1
    for _a in $(./busybox --list); do
        ln -sf busybox "$_a" 2>/dev/null
    done
    cd / || exit 1
fi

echo "🚀 启动守护进程 …"
if [ "$(id -u)" = "0" ]; then
    # 降回 shell 再启动，避免模块以 root 身份运行（沙箱与属主都按 shell 设计）
    su 2000 -c "nohup setsid -d sh '$_DEST/Main.sh' >/dev/null 2>&1 </dev/null &" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "⚠️  降权启动失败，改用当前身份启动"
        nohup setsid -d sh "$_DEST/Main.sh" >/dev/null 2>&1 </dev/null &
    fi
else
    nohup setsid -d sh "$_DEST/Main.sh" >/dev/null 2>&1 </dev/null &
fi

sleep 2
echo "✅ 已激活。回到 Shell Manager，下拉刷新即可看到框架状态。"
