import 'package:flutter/material.dart';

import '../models/iwphone_module.dart';
import '../services/iwphone_service.dart';
import '../theme/app_theme.dart';
import '../widgets/back_icon_button.dart';
import '../widgets/resource_summary.dart';
import '../widgets/screen_app_bar.dart';

/// 资源占用 / 资源冲突页 —— 独立页面（自带 Scaffold）。
///
/// 数据来自框架的 `state/owners/` 与 `state/writers/` 记账目录，
/// 由 WebUI 的 `/api/conflicts` 汇总后返回：
///   · 上半部分：冲突记录（启动拦截 / 多模块写入 / 值被改动）
///   · 下半部分：资源占用清单，按资源域分组，冲突项高亮
///
/// 资源名归一化格式为「域.对象」，例如 `global.xxx` / `prop.persist.x.y` /
/// `service.deviceidle` / `appops.com.a.b.OP`。同一资源被 ≥2 个模块触碰
/// 即标记为冲突。
class ResourcesScreen extends StatefulWidget {
  const ResourcesScreen({super.key});

  @override
  State<ResourcesScreen> createState() => _ResourcesScreenState();
}

class _ResourcesScreenState extends State<ResourcesScreen> {
  ConflictReport _report = ConflictReport.empty;
  bool _loading = true;

  /// null = 全部；否则只看该域资源。
  String? _domainFilter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final report = await IwphoneService.instance.getConflicts(tail: 200);
    if (!mounted) return;
    setState(() {
      _report = report;
      _loading = false;
      // 过滤域在新数据里可能已不存在，回落为「全部」
      if (_domainFilter != null &&
          !_domainsOf(report.resources).contains(_domainFilter)) {
        _domainFilter = null;
      }
    });
  }

  /// 资源域 → 数量，按资源数降序（域名字升序兜底）。
  Map<String, int> _domainCounts(List<ResourceUsage> list) {
    final m = <String, int>{};
    for (final r in list) {
      m[r.domain] = (m[r.domain] ?? 0) + 1;
    }
    return Map.fromEntries(
      m.entries.toList()
        ..sort((a, b) {
          final c = b.value.compareTo(a.value);
          return c != 0 ? c : a.key.compareTo(b.key);
        }),
    );
  }

  List<String> _domainsOf(List<ResourceUsage> list) =>
      _domainCounts(list).keys.toList();

  List<ResourceUsage> get _visibleResources {
    final all = _report.resources;
    if (_domainFilter == null) return all;
    return all.where((r) => r.domain == _domainFilter).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 16, 8),
              child: Row(
                children: [
                  const BackIconButton(),
                  const SizedBox(width: 4),
                  const Expanded(
                    child: ScreenAppBar(title: '资源占用'),
                  ),
                  IconButton(
                    onPressed: _loading ? null : _load,
                    icon: Icon(Icons.refresh,
                        size: 20, color: AppColors.textSecondary),
                    tooltip: '刷新',
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      color: AppColors.accent,
                      backgroundColor: AppColors.surface,
                      child: _buildBody(),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    final resources = _visibleResources;
    final counts = _domainCounts(_report.resources);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        ResourceSummaryCard(report: _report),        const SizedBox(height: 12),
        if (_report.entries.isNotEmpty) ...[
          _SectionTitle(
            title: '冲突记录',
            trailing: '${_report.entries.length} 条',
          ),
          const SizedBox(height: 8),
          for (final e in _report.entries) ...[
            _ConflictEntryCard(entry: e),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 8),
        ],
        _SectionTitle(
          title: '资源占用',
          trailing: '${_report.resources.length} 项',
        ),
        const SizedBox(height: 8),
        if (_report.resources.isEmpty)
          const _EmptyHint(
            text: '暂无资源占用记录。\n模块通过沙箱写入系统设置后，会在这里留下归属。',
          )
        else ...[
          _DomainFilterBar(
            counts: counts,
            selected: _domainFilter,
            total: _report.resources.length,
            onSelect: (d) => setState(() => _domainFilter = d),
          ),
          const SizedBox(height: 10),
          for (final r in resources) ...[
            _ResourceCard(usage: r),
            const SizedBox(height: 8),
          ],
        ],
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.trailing});

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(title, style: AppText.sectionTitle)),
        if (trailing != null) Text(trailing!, style: AppText.desc12),
      ],
    );
  }
}

/// 域筛选条：横向滚动的胶囊按钮。
class _DomainFilterBar extends StatelessWidget {
  const _DomainFilterBar({
    required this.counts,
    required this.selected,
    required this.total,
    required this.onSelect,
  });

  final Map<String, int> counts;
  final String? selected;
  final int total;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final keys = counts.keys.toList();

    return SizedBox(
      height: 32,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _chip('全部', total, selected == null, () => onSelect(null)),
          for (final k in keys)
            _chip(
              k,
              counts[k] ?? 0,
              selected == k,
              () => onSelect(k),
            ),
        ],
      ),
    );
  }

  Widget _chip(String label, int n, bool active, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: active
                ? AppColors.accent.withValues(alpha: 0.16)
                : AppColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: active ? AppColors.accent : AppColors.divider,
              width: 1,
            ),
          ),
          child: Text(
            '$label $n',
            style: active ? AppText.filterActive : AppText.filterInactive,
          ),
        ),
      ),
    );
  }
}

/// 单条资源占用：资源名 + 冲突标记 + 占用模块列表。
class _ResourceCard extends StatelessWidget {
  const _ResourceCard({required this.usage});

  final ResourceUsage usage;

  @override
  Widget build(BuildContext context) {
    final bad = usage.conflict;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: bad
            ? Border.all(color: AppColors.iconRed.withValues(alpha: 0.5))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                bad ? Icons.error_outline : Icons.check_circle_outline,
                size: 16,
                color: bad ? AppColors.iconRed : AppColors.accent,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  usage.resource,
                  style: AppText.monoValue14,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (bad)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.iconRed.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${usage.modules.length} 个模块',
                    style: AppText.badge.copyWith(color: AppColors.iconRed),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final m in usage.modules)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.bg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.divider),
                  ),
                  child: Text(m, style: AppText.body13),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 一条冲突记录卡片。
class _ConflictEntryCard extends StatelessWidget {
  const _ConflictEntryCard({required this.entry});

  final ConflictEntry entry;

  Color get _color => switch (entry.type) {
    ConflictType.block => AppColors.iconRed,
    ConflictType.writer => AppColors.iconOrange,
    ConflictType.drift => AppColors.iconBlue,
  };

  IconData get _icon => switch (entry.type) {
    ConflictType.block => Icons.block,
    ConflictType.writer => Icons.edit_note,
    ConflictType.drift => Icons.sync_problem,
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_icon, size: 16, color: _color),
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  entry.typeLabel,
                  style: AppText.badge.copyWith(color: _color),
                ),
              ),
              const Spacer(),
              if (entry.time.isNotEmpty)
                Text(entry.time, style: AppText.desc12),
            ],
          ),
          const SizedBox(height: 8),
          Text(entry.message, style: AppText.body13),
          if (entry.resource.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              entry.resource,
              style: AppText.monoValue14.copyWith(fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(Icons.inbox_outlined,
              size: 28, color: AppColors.textInactive),
          const SizedBox(height: 10),
          Text(
            text,
            style: AppText.desc12,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
