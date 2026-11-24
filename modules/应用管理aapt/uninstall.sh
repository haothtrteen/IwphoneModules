#!/system/bin/sh
# =====================================================
# 应用管理 aapt —— 卸载清理
#
# v3 框架的 module_uninstall() 会自己删掉 work/{模块名}/，
# 这个脚本只负责清理「部署到工作目录之外」的产物：
#   main.sh 把随包的 aapt 拷到了 /data/local/tmp/aapt
# =====================================================

pworkd="/data/local/tmp/iwphone"

# 模块目录名 = .iwp 文件名主名（见 mod_install.sh 里 NAME 的推导）
fileswork="$pworkd/work/应用管理aapt"
[ -d "$fileswork" ] && rm -rf "$fileswork"

# main.sh 部署出去的 aapt 二进制
[ -f /data/local/tmp/aapt ] && rm -f /data/local/tmp/aapt

exit 0
