#!/system/bin/sh
# =====================================================
# IWPhone 息屏深度doze —— 卸载清理
# 模块目录名 = .iwp 文件名主名（见 mod_install.sh 里 NAME 的推导）
# =====================================================

pworkd="/data/local/tmp/iwphone"
fileswork="$pworkd/work/IWPhone息屏深度doze"
[ -d "$fileswork" ] && rm -rf "$fileswork"

exit 0
