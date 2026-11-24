#!/system/bin/sh
# Magisk/KernelSU 式常驻服务脚本（假设 MODDIR 存在 —— 兼容层会提供）
MODDIR=${0%}

while true; do
    echo "$(date '+%H:%M:%S') service.sh 心跳，MODDIR=$MODDIR"
    sleep 20
done
