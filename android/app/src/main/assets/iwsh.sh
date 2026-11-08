#!/system/bin/sh
# iwphone · rish 式终端入口
# 用法： sh iwsh.sh [命令...]      例： sh iwsh.sh id
# 需要同目录有 iwsh.dex（由 Shell Manager「接入说明 → 导出工具包」生成）
BASEDIR=$(dirname "$0")
DEX="$BASEDIR/iwsh.dex"

if [ ! -f "$DEX" ]; then
  echo "找不到 $DEX，请先在 Shell Manager 里导出 rish 工具包" >&2
  exit 1
fi

# Android 14+：app_process 不能加载可写的 dex
if [ "$(getprop ro.build.version.sdk)" -ge 34 ] && [ -w "$DEX" ]; then
  chmod 400 "$DEX" 2>/dev/null
fi

exec /system/bin/app_process -Djava.class.path="$DEX" /system/bin \
     --nice-name=iwsh com.shellmgr.shell.ShellLoader "$@"
