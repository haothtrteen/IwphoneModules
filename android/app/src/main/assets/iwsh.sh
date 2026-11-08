#!/system/bin/sh
# iwphone · iwsh 终端入口
#
# 用法：
#   sh iwsh.sh            进入交互式 shell（连续敲命令，exit / Ctrl-D 退出）
#   sh iwsh.sh id         执行一条命令后退出
#
# 同目录需要 iwsh.dex（由 Shell Manager「接入说明 → 导出工具包」生成）。
#
# ★ 改这里：把 com.termux 换成你使用的终端 App 包名（如 bin.mt.termex）。
#   授权按「整个应用」生效；也可用同名环境变量覆盖，无需改脚本。
: "${IWPHONE_APPLICATION_ID:=com.termux}"
export IWPHONE_APPLICATION_ID

# 部署建议：把工具包放进终端 App 自己的私有目录（如 /data/data/<包名>/files/）。
# Android 14+ 的 app_process 会拒绝加载「可写」的 dex；公共 /sdcard(FUSE) 上
# chmod 往往无效，私有目录才能成功收紧权限。

# 用绝对路径定位工具包，避免终端 App 的包装脚本改了工作目录后
# app_process 按相对路径找不到 dex → ClassNotFoundException → Aborted。
BASEDIR=$(cd "$(dirname "$0")" && pwd) || {
  echo "[iwsh] 无法定位工具包目录" >&2
  exit 1
}
DEX="$BASEDIR/iwsh.dex"
export IWPHONE_DIR="$BASEDIR"

if [ ! -f "$DEX" ]; then
  echo "[iwsh] 找不到 $DEX" >&2
  echo "请把 iwsh.sh 与 iwsh.dex 放在同一目录" >&2
  exit 1
fi

# 完整性预检：dex 被文本方式复制/截断时，ART 会 Abort 且只吐一堆栈。
_sz=$(wc -c < "$DEX" 2>/dev/null)
if [ -z "$_sz" ] || [ "$_sz" -lt 1000 ]; then
  echo "[iwsh] iwsh.dex 不完整（$_sz 字节），请重新导出工具包" >&2
  exit 1
fi

# Android 14+ 要求 dex 不可写。getprop 在部分终端取不到值，取不到就不提示，
# 避免 Android 13 上出现误导性的「仍可写」警告。
chmod 400 "$DEX" 2>/dev/null
_sdk=$(getprop ro.build.version.sdk 2>/dev/null)
case "$_sdk" in ''|*[!0-9]*) _sdk=0 ;; esac
if [ "$_sdk" -ge 34 ] && [ -w "$DEX" ]; then
  echo "[iwsh] 提示：$DEX 仍可写，Android 14+ 会拒绝加载。请把工具包放到终端 App 私有目录" >&2
fi

exec /system/bin/app_process -Djava.class.path="$DEX" /system/bin \
     --nice-name=iwsh com.shellmgr.shell.ShellLoader "$@"
