import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../i18n/app_strings.dart';

/// 底部导航栏 —— 1:1 还原设计稿
///
/// 高度 80，背景 #16161A，上内边距 8 / 下内边距 12，
/// 五个等宽 Tab（图标 22 + 间距 4 + 标签 10）。
/// 选中态：强调绿 + 实心图标；未选中态：#606068 + 描边图标。
class BottomNavBar extends StatelessWidget {
  const BottomNavBar({
    super.key,
    required this.currentIndex,
    required this.onChanged,
  });

  final int currentIndex;
  final ValueChanged<int> onChanged;

  /// 标签文案随语言变化，因此这里是 getter 而不是 const 列表
  /// （语言切换后由根组件重建整棵树，重新取一次即可）。
  static List<(IconData, IconData, String)> get _tabs => [
        (Icons.home, Icons.home_outlined, AppStrings.t('nav.home')),
        (Icons.extension, Icons.extension_outlined, AppStrings.t('nav.modules')),
        // Magisk 式「超级用户」位：应用授权页（AppAuthScreen, embedded=true）。
        // 放在模块与自动化之间，与 IndexedStack 的 index 2 对应。
        (Icons.verified_user, Icons.verified_user_outlined,
            AppStrings.t('nav.auth')),
        // 第 4 个 tab 是自动化（AutomationScreen）。
        // 这里原本是「日志」—— 日志属于「出事才看」的低频入口，
        // 已挪到首页卡片；自动化是天天要调的高频页，值得占一个固定位。
        (Icons.account_tree, Icons.account_tree_outlined,
            AppStrings.t('nav.automation')),
        (Icons.settings, Icons.settings_outlined, AppStrings.t('nav.settings')),
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
