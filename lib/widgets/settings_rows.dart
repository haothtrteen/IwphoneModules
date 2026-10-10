import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_switch.dart';

/// 设置类页面的通用行组件。
///
/// 从 settings_screen.dart 抽出来，因为「框架工具」子页也要用同一套行样式 ——
/// 复制一份会导致两处样式慢慢分叉。

/// 设置分组卡片：圆角 16 / 内边距 16 / 内部间距 12
class SettingsSection extends StatelessWidget {
  const SettingsSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppText.sectionTitle),
          const SizedBox(height: 12),
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// 开关行：左侧标签（15 / 白）+ 右侧开关
class ToggleRow extends StatelessWidget {
  const ToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label, style: AppText.rowLabel)),
        AppSwitch(value: value, onChanged: onChanged),
      ],
    );
  }
}

/// 数值行：左侧标签（15 / 白）+ 右侧值（14 / 灰，可等宽）
class ValueRow extends StatelessWidget {
  const ValueRow({required this.label, required this.value, this.mono = false});

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label, style: AppText.rowLabel)),
        Text(value, style: mono ? AppText.monoValue14 : AppText.value14),
      ],
    );
  }
}

/// 可跳转的设置行：标签 + 副标题提示 + 右箭头。
///
/// [danger] 为 true 时标签用警示色（用于卸载这类不可撤销操作）。
class NavRow extends StatelessWidget {
  const NavRow({
    required this.label,
    required this.hint,
    required this.onTap,
    this.danger = false,
  });

  final String label;
  final String hint;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final labelColor = danger ? AppColors.iconRed : null;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: labelColor == null
                        ? AppText.rowLabel
                        : AppText.rowLabel.copyWith(color: labelColor),
                  ),
                  const SizedBox(height: 2),
                  Text(hint, style: AppText.desc12),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                size: 20, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}
