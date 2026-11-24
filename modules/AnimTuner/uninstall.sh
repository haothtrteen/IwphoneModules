#!/system/bin/sh
# 卸载：把动画速度还原成系统默认
settings put global window_animation_scale 1.0
settings put global transition_animation_scale 1.0
settings put global animator_duration_scale 1.0
echo "✅ 动画速度已还原为系统默认"
