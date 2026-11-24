#!/system/bin/sh
# =====================================================
# 私有 DNS
# 设置系统私有 DNS（DoT）
#
# 配置由 App 的「模块配置页」写入 config.sh，这里直接 source 读取；
# 没有配置文件时回退到下面的默认值。
# =====================================================
cd "$(dirname "$0")" || exit 1

[ -f ./config.sh ] && . ./config.sh

MODE="${mode:-hostname}"
HOST="${host:-dns.adguard.com}"
GUARD="${guard:-30}"
[ "$GUARD" -lt 5 ] 2>/dev/null && GUARD=5

apply() {
    case "$MODE" in
        off)
            settings put global private_dns_mode off
            ;;
        opportunistic)
            settings put global private_dns_mode opportunistic
            ;;
        hostname)
            # 主机名为空就退回 off，避免写进一个无效的 specifier
            if [ -z "$HOST" ]; then
                settings put global private_dns_mode off
            else
                settings put global private_dns_specifier "$HOST"
                settings put global private_dns_mode hostname
            fi
            ;;
    esac
}

apply
echo "[$(date '+%H:%M:%S')] 私有 DNS 模式=${MODE} 主机=${HOST}"

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
