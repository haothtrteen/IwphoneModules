import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
import '../services/iwphone_service.dart';
import '../theme/app_theme.dart';

/// 快照清单弹层：还原前让用户看清「到底会改什么」。
///
/// 这是「还原」的日志界面 —— 不盲还原是这套兜底能被信任的前提。
/// 模块页（单个模块的还原）与「历史快照」页（含孤儿快照）共用本组件。
///
/// 返回 true 表示用户确认还原，false / null 表示取消。
class SnapshotSheet extends StatelessWidget {
  const SnapshotSheet({
    super.key,
    required this.title,
    required this.items,
    this.note,
  });

  /// 标题里的主体（模块名）。
  final String title;

  /// 快照条目。
  final List<SnapshotItem> items;

  /// 可选的补充说明（如「该模块已卸载」）。
  final String? note;

  @override
  Widget build(BuildContext context) {
    final restorable = items.where((e) => e.restorable).length;
    final skipped = items.length - restorable;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${AppStrings.t('snapshotSheet.title')} · $title',
                style: AppText.cardTitle),
            const SizedBox(height: 4),
            Text(
              '${AppStrings.t('snapshotSheet.restorePrefix')}$restorable'
              '${AppStrings.t('snapshotSheet.restoreMid')}'
              '${skipped > 0 ? '${AppStrings.t('snapshotSheet.alsoPrefix')}$skipped'
                  '${AppStrings.t('snapshotSheet.alsoSuffix')}' : ''}'
              '${AppStrings.t('snapshotSheet.restoreEnd')}'
              '${note == null ? '' : '\n$note'}',
              style: AppText.desc12,
            ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final it in items) SnapshotRow(item: it),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(AppStrings.t('common.cancel'),
                        style: AppText.rowLabel
                            .copyWith(color: AppColors.textSecondary)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextButton(
                    onPressed: restorable == 0
                        ? null
                        : () => Navigator.of(context).pop(true),
                    style: TextButton.styleFrom(
                      backgroundColor: restorable == 0
                          ? AppColors.bg
                          : AppColors.iconOrange.withValues(alpha: 0.15),
                    ),
                    child: Text(
                      restorable == 0
                          ? AppStrings.t('snapshotSheet.noRestorable')
                          : '${AppStrings.t('snapshotSheet.restoreButtonPrefix')}'
                              '$restorable${AppStrings.t('snapshotSheet.restoreButtonSuffix')}',
                      style: AppText.rowLabel.copyWith(
                        color: restorable == 0
                            ? AppColors.textInactive
                            : AppColors.iconOrange,
                      ),
                    ),
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

/// 清单里的一行：资源名 + 「当前 x → 还原为 y」。
class SnapshotRow extends StatelessWidget {
  const SnapshotRow({super.key, required this.item});

  final SnapshotItem item;

  @override
  Widget build(BuildContext context) {
    final ok = item.restorable;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                ok ? Icons.settings_backup_restore : Icons.warning_amber_rounded,
                size: 14,
                color: ok ? AppColors.accent : AppColors.iconOrange,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  item.resource.isEmpty
                      ? AppStrings.t('snapshotSheet.unknownResource')
                      : item.resource,
                  style: AppText.desc12.copyWith(color: AppColors.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            ok
                ? '${AppStrings.t('snapshotSheet.currentPrefix')}'
                    '${item.current.isEmpty ? AppStrings.t('snapshotSheet.emptyValue') : item.current}'
                    '${AppStrings.t('snapshotSheet.arrowRestore')}'
                    '${item.targetValue.isEmpty ? AppStrings.t('snapshotSheet.emptyValue') : item.targetValue}'
                : AppStrings.t('snapshotSheet.manualNeeded'),
            style: AppText.desc12.copyWith(
              color: ok ? AppColors.textSecondary : AppColors.iconOrange,
            ),
          ),
        ],
      ),
    );
  }
}
