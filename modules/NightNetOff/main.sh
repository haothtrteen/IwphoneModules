#!/system/bin/sh
# =====================================================
# 夜间断网
# 按时间段自动开关移动数据与 WiFi
#
# 配置由 App 的「模块配置页」写入 config.sh，这里直接 source 读取；
# 没有配置文件时回退到下面的默认值。
# =====================================================
cd "$(dirname "$0")" || exit 1

[ -f ./config.sh ] && . ./config.sh

START_H="${start_hour:-23}"
END_H="${end_hour:-7}"
DO_DATA="${disable_data:-1}"
DO_WIFI="${disable_wifi:-0}"
GUARD="${guard:-60}"
[ "$GUARD" -lt 10 ] 2>/dev/null && GUARD=10

# 判断当前小时是否落在 [start, end) 区间内。
# 支持跨零点：例如 23 点到 7 点，23/0/1/.../6 都算「在窗口内」。
in_window() {
    _h="$1"; _s="$2"; _e="$3"
    if [ "$_s" -le "$_e" ]; then
        [ "$_h" -ge "$_s" ] && [ "$_h" -lt "$_e" ] && return 0
    else
        # 跨零点
        [ "$_h" -ge "$_s" ] || [ "$_h" -lt "$_e" ] && return 0
    fi
    return 1
}

apply() {
    _hour=$(date +%H)
    # 去掉前导零，否则 08/09 在算术上下文里会被当成八进制而报错
    _hour=$((10#$_hour))
    if in_window "$_hour" "$START_H" "$END_H"; then
        [ "$DO_DATA" = "1" ] && svc data disable
        [ "$DO_WIFI" = "1" ] && svc wifi disable
        echo "[$(date '+%H:%M:%S')] 断网时段（${_hour} 点）→ 已关闭"
    else
        [ "$DO_DATA" = "1" ] && svc data enable
        [ "$DO_WIFI" = "1" ] && svc wifi enable
        echo "[$(date '+%H:%M:%S')] 正常时段（${_hour} 点）→ 已恢复"
    fi
}

# 退出时务必把网络恢复，否则「关掉模块后一直没网」
cleanup() {
    [ "$DO_DATA" = "1" ] && svc data enable
    [ "$DO_WIFI" = "1" ] && svc wifi enable
    echo "[$(date '+%H:%M:%S')] 已退出，网络恢复"
}
trap cleanup TERM INT EXIT

apply
while true; do
    [ -f ./end ] && { cleanup; exit 0; }
    sleep "$GUARD"
    # 每轮重新读配置：改完配置最迟下一轮生效，无需重启模块
    [ -f ./config.sh ] && . ./config.sh
    apply
done
