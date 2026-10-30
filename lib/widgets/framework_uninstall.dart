import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
import '../services/iwphone_service.dart';
import '../theme/app_theme.dart';
import 'confirm_dialog.dart';

/// 「完全卸载框架」的统一入口：二次确认 → 调用 → 结果弹窗。
///
/// 后端是**延迟 3 秒**执行的 —— 因为 uninstall.sh 会把 WebUI 自己停掉，
/// 同步执行的话响应根本发不回来。所以这里拿到 ok 只代表「任务已排队」。
///
/// 首页与设置页共用，避免两处确认文案与调用链分叉。
Future<void> confirmFrameworkUninstall(BuildContext context) async {
  final ok = await showConfirmDialog(
    context,
    title: AppStrings.t('settings.uninstallTitle'),
    message: AppStrings.t('settings.uninstallMessage'),
    confirmText: AppStrings.t('settings.uninstallFramework'),
  );
  if (!ok || !context.mounted) return;

  final res = await IwphoneService.instance.uninstallFramework();
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(
          res.ok
              ? AppStrings.t('settings.uninstallQueued')
              : AppStrings.t('settings.uninstallFailedTitle'),
          style: AppText.cardTitle),
      content: Text(res.msg, style: AppText.body13),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(AppStrings.t('common.gotIt'),
              style: AppText.rowLabel.copyWith(color: AppColors.accent)),
        ),
      ],
    ),
  );
}
