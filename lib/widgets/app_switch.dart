import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 开关 —— 1:1 还原设计稿尺寸
///
/// 整体 44×24；轨道 42×22 圆角 11；
/// 开启：轨道 #00C853 + 白色滑块（右侧）；关闭：轨道 #3A3A3E + #808088 滑块（左侧）。
class AppSwitch extends StatelessWidget {
  const AppSwitch({super.key, required this.value, this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: SizedBox(
        width: 44,
        height: 24,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // 轨道
            Positioned(
              left: 1,
              top: 1,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                width: 42,
                height: 22,
                decoration: BoxDecoration(
                  color: value ? AppColors.accent : AppColors.switchTrackOff,
                  borderRadius: BorderRadius.circular(11),
                ),
              ),
            ),
            // 滑块
            AnimatedPositioned(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              left: value ? 24 : 2,
              top: 3,
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: value ? Colors.white : AppColors.switchKnobOff,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
