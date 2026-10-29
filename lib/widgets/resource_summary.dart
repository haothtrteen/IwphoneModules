import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
import '../models/iwphone_module.dart';
import '../theme/app_theme.dart';

/// 资源占用概览卡 —— 模块页与资源占用页共用。
///
/// 同一份视觉，两种用法：
///   · [ResourceSummaryCard] —— 资源占用页顶部的大卡（三个统计块）
///   · [ResourceSummaryBar]  —— 模块页顶部的窄条（一行状态 + 计数，可点跳转）
///
/// 冲突状态由 [ConflictReport] 决定：无可冲突资源时走绿色「无资源冲突」，
/// 否则走红色警示并给出冲突项数。
class ResourceSummaryCard extends StatelessWidget {
  const ResourceSummaryCard({super.key, required this.report});

  final ConflictReport report;

  @override
  Widget build(BuildContext context) {
    final total = report.resources.length;
    final bad = report.conflictResCount;
    final healthy = bad == 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                healthy ? Icons.verified_outlined : Icons.warning_amber_rounded,
                size: 20,
                color: healthy ? AppColors.accent : AppColors.iconRed,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  healthy
                      ? AppStrings.t('resourceSummary.noConflict')
                      : '${AppStrings.t('resourceSummary.detectedPrefix')}$bad'
                          '${AppStrings.t('resourceSummary.conflictCountSuffix')}',
                  style: AppText.cardTitle,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _StatChip(
                  label: AppStrings.t('resourceSummary.conflictResources'),
                  value: '$bad',
                  danger: bad > 0),
              const SizedBox(width: 8),
              _StatChip(
                  label: AppStrings.t('resourceSummary.usedResources'),
                  value: '$total'),
              const SizedBox(width: 8),
              _StatChip(
                label: AppStrings.t('resourceSummary.conflictLog'),
                value: '${report.entries.length}',
                danger: report.entries.isNotEmpty,
              ),
            ],
          ),
          if (!healthy) ...[
            const SizedBox(height: 12),
            Text(
              AppStrings.t('resourceSummary.conflictHint'),
              style: AppText.desc12,
            ),
          ],
        ],
      ),
    );
  }
}

/// 模块页用的紧凑条：一行状态 + 右侧进入箭头，整条可点。
///
/// 空白态（无冲突、也没有任何资源占用）显示中性文案；
/// 有冲突时整条转红色，提示「N 项资源冲突」。
class ResourceSummaryBar extends StatelessWidget {
  const ResourceSummaryBar({
    super.key,
    required this.report,
    required this.onTap,
    this.loading = false,
  });

  final ConflictReport report;
  final VoidCallback onTap;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final bad = report.conflictResCount;
    final total = report.resources.length;
    final healthy = bad == 0;

    final Color color = healthy ? AppColors.accent : AppColors.iconRed;
    final IconData icon = healthy
        ? Icons.verified_outlined
        : Icons.warning_amber_rounded;

    final String title;
    if (loading) {
      title = AppStrings.t('resourceSummary.checking');
    } else if (bad > 0) {
      title = '$bad${AppStrings.t('resourceSummary.conflictCountSuffix')}';
    } else if (total > 0) {
      title = AppStrings.t('resourceSummary.healthy');
    } else {
      title = AppStrings.t('resourceSummary.empty');
    }

    final String detail;
    if (loading) {
      detail = AppStrings.t('resourceSummary.detailLoading');
    } else if (bad > 0) {
      detail =
          '${AppStrings.t('resourceSummary.occupiedPrefix')}$total'
          '${AppStrings.t('resourceSummary.tapDetailsSuffix')}';
    } else if (total > 0) {
      detail =
          '${AppStrings.t('resourceSummary.occupiedPrefix')}$total'
          '${AppStrings.t('resourceSummary.noDuplicateSuffix')}';
    } else {
      detail = AppStrings.t('resourceSummary.emptyDetail');
    }

    return InkWell(
      onTap: loading ? null : onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: healthy
              ? null
              : Border.all(color: AppColors.iconRed.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: AppText.rowLabel.copyWith(
                      color: healthy ? null : AppColors.iconRed,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: AppText.desc12,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (bad > 0) ...[
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.iconRed.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  AppStrings.t('resourceSummary.conflictBadge'),
                  style: AppText.badge.copyWith(color: AppColors.iconRed),
                ),
              ),
              const SizedBox(width: 6),
            ],
            Icon(
              Icons.chevron_right,
              size: 20,
              color: AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.label,
    required this.value,
    this.danger = false,
  });

  final String label;
  final String value;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.iconRed : AppColors.accent;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: AppText.value14.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(label, style: AppText.desc12),
          ],
        ),
      ),
    );
  }
}
