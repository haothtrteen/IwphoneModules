import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 独立页面用的返回按钮。
///
/// 项目的自绘顶栏 [ScreenAppBar] 只有标题与右侧动作、不带 leading，
/// 而通过 `Navigator.push` 打开的页面既没有系统 AppBar 也没有手势提示，
/// 因此需要自行在标题左侧放一个返回入口。
class BackIconButton extends StatelessWidget {
  const BackIconButton({super.key, this.onTap});

  /// 不传时默认 pop 当前路由。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap ?? () => Navigator.of(context).maybePop(),
      behavior: HitTestBehavior.opaque,
      child: const Padding(
        padding: EdgeInsets.only(right: 12, top: 2, bottom: 2),
        child: Icon(
          Icons.arrow_back_ios_new,
          size: 20,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}
