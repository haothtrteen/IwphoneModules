import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 页面标题栏 —— 1:1 还原设计稿
///
/// 高度 48，左侧标题 22/Bold，右侧动作图标（24×24，间距 16，颜色 #A0A0A8）。
class ScreenAppBar extends StatelessWidget {
  const ScreenAppBar({
    super.key,
    required this.title,
    this.actions = const [],
    this.leading,
  });

  final String title;
  final List<Widget> actions;

  /// 可选的左侧入口（返回按钮）。
  ///
  /// 底栏 tab 页不需要；用 `Navigator.push` 打开、又自带自定义顶栏的页面需要，
  /// 否则既没有系统 AppBar 的返回箭头，也没有任何返回提示。
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          if (leading != null) leading!,
          Expanded(child: Text(title, style: AppText.appTitle)),
          if (actions.isNotEmpty)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 16),
                  actions[i],
                ],
              ],
            ),
        ],
      ),
    );
  }
}

/// 标题栏动作图标按钮
class AppBarActionIcon extends StatelessWidget {
  const AppBarActionIcon({super.key, required this.icon, this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 24,
        height: 24,
        child: Icon(icon, size: 24, color: AppColors.textSecondary),
      ),
    );
  }
}
