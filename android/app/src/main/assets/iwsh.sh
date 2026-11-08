#!/system/bin/sh
# iwphone · iwsh 终端入口
# 用法： sh iwsh.sh [命令...]      例： sh iwsh.sh id
# 需要同目录有 iwsh.dex（由 Shell Manager「接入说明 → 导出工具包」生成）
BASEDIR=$(dirname "$0")
DEX="$BASEDIR/iwsh.dex"

# 终端应用包名：导出工具包时会生成同目录的 iwsh.env（对齐 Shizuku 的
# application id 做法）。也可改这个文件，或用环境变量覆盖。
if [ -f "$BASEDIR/iwsh.env" ]; then
  . "$BASEDIR/iwsh.env"
fi
: "${IWPHONE_APPLICATION_ID:=com.termux}"
export IWPHONE_APPLICATION_ID
export IWPHONE_DIR="$BASEDIR"

if [ ! -f "$DEX" ]; then
  echo "找不到 $DEX，请先在 Shell Manager 里导出 iwsh 工具包" >&2
  exit 1
fi

# Android 14+：app_process 不能加载可写的 dex
if [ "$(getprop ro.build.version.sdk)" -ge 34 ] && [ -w "$DEX" ]; then
  chmod 400 "$DEX" 2>/dev/null
fi

exec /system/bin/app_process -Djava.class.path="$DEX" /system/bin \
     --nice-name=iwsh com.shellmgr.shell.ShellLoader "$@"
