import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 底部导航栏 —— 1:1 还原设计稿
///
/// 高度 80，背景 #16161A，上内边距 8 / 下内边距 12，
/// 四个等宽 Tab（图标 22 + 间距 4 + 标签 10）。
/// 选中态：强调绿 + 实心图标；未选中态：#606068 + 描边图标。
class BottomNavBar extends StatelessWidget {
  const BottomNavBar({
    super.key,
    required this.currentIndex,
    required this.onChanged,
  });

  final int currentIndex;
  final ValueChanged<int> onChanged;

  static const List<(IconData, IconData, String)> _tabs = [
    (Icons.home, Icons.home_outlined, '主页'),
    (Icons.extension, Icons.extension_outlined, '模块'),
    // 第 3 个 tab 的内容是 LogsScreen（见 main.dart 的 IndexedStack）。
    // 这里曾长期写着「权限」+ security 图标 —— 那是设计稿早期的「权限/超级用户」页，
    // 后来该位置改成日志页，标签忘了跟着改：点「权限」出来的是日志，很误导。
    (Icons.article, Icons.article_outlined, '日志'),
    (Icons.settings, Icons.settings_outlined, '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 80,
      color: AppColors.navBar,
      padding: const EdgeInsets.only(top: 8, bottom: 12),
      child: Row(
        children: [
          for (var i = 0; i < _tabs.length; i++)
            _NavItem(
              icon: currentIndex == i ? _tabs[i].$1 : _tabs[i].$2,
              label: _tabs[i].$3,
              active: currentIndex == i,
              onTap: () => onChanged(i),
            ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.accent : AppColors.textInactive;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: AppText.navLabel.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
