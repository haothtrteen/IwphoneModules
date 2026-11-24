#!/system/bin/sh
# =====================================================
# iwphone 应用管理 aapt 扩展 —— v3 兼容入口
#
# 说明：本模块原为 v1 框架编写，入口是 main.bat（且内容为空实现），
# v3 框架要求以 main.sh 为入口（见 mod_run.sh），故在此补齐。
#
# 该模块的实际价值是随包的 aapt 二进制，供「应用管理」读取 APK 信息使用。
# 因此这里把 aapt 部署到 /data/local/tmp/ 并赋可执行权限，然后退出。
# =====================================================
MOD_DIR=$(cd "$(dirname "$0")" && pwd)
TARGET=/data/local/tmp/aapt

if [ -f "$MOD_DIR/aapt" ]; then
    cp -f "$MOD_DIR/aapt" "$TARGET"
    chmod 755 "$TARGET"
    echo "aapt 已部署到 $TARGET"
else
    echo "未找到 aapt 二进制"
    exit 1
fi