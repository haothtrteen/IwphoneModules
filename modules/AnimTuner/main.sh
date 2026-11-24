#!/system/bin/sh
# =====================================================
# 动画调速
# 把三项系统动画缩放统一设为指定值
#
# 配置由 App 的「模块配置页」写入 config.sh，这里直接 source 读取；
# 没有配置文件时回退到下面的默认值。
# =====================================================
cd "$(dirname "$0")" || exit 1

[ -f ./config.sh ] && . ./config.sh

SCALE="${SCALE:-0.5}"
GUARD="${guard:-30}"
[ "$GUARD" -lt 5 ] 2>/dev/null && GUARD=5

apply() {
    settings put global window_animation_scale "$SCALE"
    settings put global transition_animation_scale "$SCALE"
    settings put global animator_duration_scale "$SCALE"
}

apply
echo "[$(date '+%H:%M:%S')] 动画速度已设为 ${SCALE}"

# ------------------------------------------------------------
# 守卫循环
#
# 只应用一次是不够的：实测有些设置会被系统自行改回
# （例如 adb_wifi_enabled 就观察过「写成功、过一会自己变回原值」）。
# 所以这里定期重新应用，让配置真正持续生效。
#
# ★ 本模块在 iwphone.prop 声明了 runtime=0。
#   否则会被全局 MAX_RUNTIME_SEC（默认 300 秒）当成「超时」强杀，
#   表现为：模块跑 5 分钟后静默失效，而 App 只显示「未运行」。
# ------------------------------------------------------------
while true; do
    # end 文件：手动退出通道（在模块目录里 touch end 即可）
    [ -f ./end ] && { echo "[$(date '+%H:%M:%S')] 检测到 end 文件，退出"; exit 0; }
    sleep "$GUARD"
    # 每轮重新读配置：App 里改完配置，最迟下一轮就生效，无需重启模块
    [ -f ./config.sh ] && . ./config.sh
    apply
done
