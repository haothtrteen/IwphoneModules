import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
import '../services/autostart_service.dart';
import '../services/iwphone_service.dart';
import '../theme/app_theme.dart';
import 'confirm_dialog.dart';

/// 「完全卸载框架」的统一入口：二次确认 → 调用 → 结果弹窗。
///
/// 两条通道按顺序尝试：
/// 1. **WebUI**：正常路径。后端延迟 3 秒执行 —— 因为 uninstall.sh 会把 WebUI
///    自己停掉，同步执行的话响应根本发不回来，所以拿到 ok 只代表「任务已排队」。
/// 2. **ADB 直连**：守护进程已停 / WebUI 没起来时 HTTP 不可用，改由原生侧
///    以 shell 身份执行框架自带的 uninstall.sh（先停进程再删目录），行为一致。
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

  final http = await IwphoneService.instance.uninstallFramework();
  if (!context.mounted) return;

  String title;
  String body;
  if (http.ok) {
    title = AppStrings.t('settings.uninstallQueued');
    body = http.msg;
  } else {
    // WebUI 不可达（或被拒）→ 走 adb 直连备用通道
    final adb = await AutostartService.instance.uninstallFrameworkAdb();
    if (!context.mounted) return;
    if (adb.ok) {
      title = AppStrings.t('settings.uninstallDoneAdb');
      body = AppStrings.t('settings.uninstallDoneAdbHint');
    } else {
      title = AppStrings.t('settings.uninstallFailedTitle');
      body = '${http.msg}\n\n'
          '${AppStrings.t('settings.uninstallAdbFailedPrefix')}${adb.msg}';
    }
  }

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(title, style: AppText.cardTitle),
      content: Text(body, style: AppText.body13),
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
