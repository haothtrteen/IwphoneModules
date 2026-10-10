import 'package:flutter/material.dart';

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
                  healthy ? '无资源冲突' : '检测到 $bad 项资源冲突',
                  style: AppText.cardTitle,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _StatChip(label: '冲突资源', value: '$bad', danger: bad > 0),
              const SizedBox(width: 8),
              _StatChip(label: '占用资源', value: '$total'),
              const SizedBox(width: 8),
              _StatChip(
                label: '冲突记录',
                value: '${report.entries.length}',
                danger: report.entries.isNotEmpty,
              ),
            ],
          ),
          if (!healthy) ...[
            const SizedBox(height: 12),
            Text(
              '同一资源被多个模块写入时，先启动的模块会赢，后写入的值可能被覆盖。'
              '如需长期稳定运行，建议只保留一个模块操作该资源。',
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
      title = '正在检查资源占用…';
    } else if (bad > 0) {
      title = '$bad 项资源冲突';
    } else if (total > 0) {
      title = '资源占用正常';
    } else {
      title = '暂无资源占用';
    }

    final String detail;
    if (loading) {
      detail = '读取模块的资源声明与运行记录';
    } else if (bad > 0) {
      detail = '共占用 $total 项资源，点击查看冲突详情';
    } else if (total > 0) {
      detail = '共占用 $total 项资源，无重复声明';
    } else {
      detail = '模块写入系统配置后，这里会显示归属';
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
                  '冲突',
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
