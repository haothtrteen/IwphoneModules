#!/system/bin/sh
# 卸载时必须把网络恢复，否则会出现「模块没了但一直没网」
svc data enable
svc wifi enable
echo "✅ 网络已恢复"
