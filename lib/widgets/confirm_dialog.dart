import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
import '../theme/app_theme.dart';

/// 危险操作的二次确认对话框。
///
/// 用于框架级操作（停止 / 重启 / 同步）与模块级操作（重装 / 卸载）——
/// 这些动作会中断服务或删除数据，必须让用户明确确认后才执行。
///
/// 用法：
/// ```dart
/// final ok = await showConfirmDialog(
///   context,
///   title: '停止框架',
///   message: '将停止 iwphone 守护进程，运行中的模块不受影响。是否继续？',
///   confirmText: '停止',
/// );
/// if (!ok) return;
/// ```
///
/// 返回 true 表示用户点了确认；取消或返回手势一律视为 false。
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String? confirmText,
  String? cancelText,
  bool danger = true,
}) async {
  final result = await showDialog<bool>(
    context: context,
    // 禁止点外部关闭：危险操作必须显式选择「取消」或「确认」，
    // 避免误触空白处被当成默认同意。
    barrierDismissible: false,
    builder: (_) => _ConfirmDialog(
      title: title,
      message: message,
      confirmText: confirmText ?? AppStrings.t('common.confirm'),
      cancelText: cancelText ?? AppStrings.t('common.cancel'),
      danger: danger,
    ),
  );
  return result ?? false;
}

class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({
    required this.title,
    required this.message,
    required this.confirmText,
    required this.cancelText,
    required this.danger,
  });

  final String title;
  final String message;
  final String confirmText;
  final String cancelText;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final accent = danger ? AppColors.iconRed : AppColors.accent;

    return Dialog(
      backgroundColor: AppColors.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  danger ? Icons.warning_amber_rounded : Icons.info_outline,
                  size: 22,
                  color: accent,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(title, style: AppText.cardTitle)),
              ],
            ),
            const SizedBox(height: 14),
            Text(message, style: AppText.body13),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(
                    cancelText,
                    style: AppText.rowLabel
                        .copyWith(color: AppColors.textSecondary),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: TextButton.styleFrom(
                    backgroundColor: accent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 10,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    confirmText,
                    style: AppText.rowLabel
                        .copyWith(color: Colors.white),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
