#!/system/bin/sh
# iwphone · iwsh 终端入口
# 用法： sh iwsh.sh [命令...]      例： sh iwsh.sh id
# 同目录需要 iwsh.dex（由 Shell Manager「接入说明 → 导出工具包」生成）
#
# 部署建议：把整个工具包放进终端 App 自己的私有目录（如 /data/data/<包名>/files/）。
# 放在 /sdcard 等 FUSE 路径上时，Android 14+ 的 app_process 会拒绝加载「可写」的
# dex 并直接 Aborted；私有目录才能成功收紧权限。

# ★ 用绝对路径定位工具包，避免终端 App 的包装脚本（bash "$@" 之类）改变
#   工作目录后，app_process 按相对路径找不到 dex → ClassNotFoundException → Aborted。
BASEDIR=$(cd "$(dirname "$0")" && pwd) || {
  echo "[iwsh] 无法定位工具包目录" >&2
  exit 1
}
DEX="$BASEDIR/iwsh.dex"

# 终端应用包名：见同目录 iwsh.env，直接改文件即可，无需在 App 里预先指定。
if [ -f "$BASEDIR/iwsh.env" ]; then
  . "$BASEDIR/iwsh.env"
fi
: "${IWPHONE_APPLICATION_ID:=com.termux}"
export IWPHONE_APPLICATION_ID
export IWPHONE_DIR="$BASEDIR"

if [ ! -f "$DEX" ]; then
  echo "[iwsh] 找不到 $DEX" >&2
  echo "请把 iwsh.sh / iwsh.dex / iwsh.env 三个文件放在同一目录" >&2
  exit 1
fi

# 完整性预检：dex 被文本方式复制/截断时，ART 会 Abort 且只吐一堆栈，
# 这里提前给出可读的错误。
_sz=$(wc -c < "$DEX" 2>/dev/null)
if [ -z "$_sz" ] || [ "$_sz" -lt 1000 ]; then
  echo "[iwsh] iwsh.dex 不完整（$_sz 字节），请重新导出工具包" >&2
  exit 1
fi

# Android 14+ 要求 dex 不可写。不依赖 getprop（部分终端 App 里取不到值），
# 直接尝试收紧权限；失败则明确提示，而不是让 app_process 静默 Abort。
chmod 400 "$DEX" 2>/dev/null
if [ -w "$DEX" ]; then
  echo "[iwsh] 警告：$DEX 仍可写。Android 14+ 会拒绝加载，请把工具包放到终端 App 私有目录后重试" >&2
fi

exec /system/bin/app_process -Djava.class.path="$DEX" /system/bin \
     --nice-name=iwsh com.shellmgr.shell.ShellLoader "$@"
