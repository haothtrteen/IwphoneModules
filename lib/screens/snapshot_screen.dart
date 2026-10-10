import 'package:flutter/material.dart';

import '../services/iwphone_service.dart';
import '../theme/app_theme.dart';
import '../widgets/back_icon_button.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/screen_app_bar.dart';
import '../widgets/snapshot_sheet.dart';

/// 历史快照页 —— 列出所有「写前快照」，含**已卸载模块留下的孤儿快照**。
///
/// 为什么单独一页：快照是这套免 root 框架的兜底底线。模块可以卸载，
/// 但它改过的系统设置仍然应该能还原 —— 前提是这些快照找得到。
/// 卸载时若没选「同时还原」，快照会保留在这里，随时可以补救。
class SnapshotScreen extends StatefulWidget {
  const SnapshotScreen({super.key});

  @override
  State<SnapshotScreen> createState() => _SnapshotScreenState();
}

class _SnapshotScreenState extends State<SnapshotScreen> {
  List<SnapshotInfo> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final res = await IwphoneService.instance.listSnapshots();
    if (!mounted) return;
    setState(() {
      _items = res.items;
      _loading = false;
    });
    if (!res.ok && res.msg.isNotEmpty) _toast(res.msg, ok: false);
  }

  void _toast(String text, {bool ok = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: ok ? null : AppColors.iconRed,
      ),
    );
  }

  /// 还原：先拉明细让用户看清会改什么，确认后再执行。
  Future<void> _restore(SnapshotInfo info) async {
    setState(() => _loading = true);
    final snap = await IwphoneService.instance.moduleSnapshot(info.name);
    if (!mounted) return;
    setState(() => _loading = false);
    if (!snap.ok) {
      _toast(snap.msg, ok: false);
      return;
    }

    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SnapshotSheet(
        title: info.name,
        items: snap.items,
        note: info.orphan ? '该模块已卸载，这里只还原它留下的系统设置改动。' : null,
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _loading = true);
    final res = await IwphoneService.instance.restoreModuleSnapshot(info.name);
    if (!mounted) return;
    setState(() => _loading = false);
    IwphoneService.instance.invalidate();
    await _load();
    if (!mounted) return;
    _toast(res.ok ? res.msg : '还原失败：${res.msg}', ok: res.ok);
  }

  Future<void> _delete(SnapshotInfo info) async {
    final ok = await showConfirmDialog(
      context,
      title: '删除快照',
      message: '删除「${info.name}」的快照后，它改过的 ${info.restorable} 项系统设置'
          '**将无法再一键还原**。\n\n'
          '如果你已经不需要回退（或打算一直保留当前状态），才建议删除。',
      danger: true,
      confirmText: '删除',
    );
    if (ok != true || !mounted) return;

    setState(() => _loading = true);
    final res = await IwphoneService.instance.deleteSnapshot(info.name);
    if (!mounted) return;
    setState(() => _loading = false);
    await _load();
    if (!mounted) return;
    _toast(res.msg, ok: res.ok);
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
                  const Expanded(child: ScreenAppBar(title: '历史快照')),
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
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      children: [
                        if (_items.isEmpty)
                          _EmptyCard()
                        else
                          for (final s in _items) ...[
                            _SnapshotCard(
                              info: s,
                              enabled: !_loading,
                              onRestore: () => _restore(s),
                              onDelete: () => _delete(s),
                            ),
                            const SizedBox(height: 8),
                          ],
                        const SizedBox(height: 12),
                        Text(
                          '· 快照在模块**首次写入**某系统资源时自动生成，记录写入前的原值。\n'
                          '· 模块卸载后快照会保留 —— 它改过的设置仍然可以还原。\n'
                          '· 还原会先停止该模块（避免守卫循环把值改回去），'
                          '成功后快照归档，模块重新启动会生成新快照。',
                          style: AppText.desc12,
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SnapshotCard extends StatelessWidget {
  const _SnapshotCard({
    required this.info,
    required this.enabled,
    required this.onRestore,
    required this.onDelete,
  });

  final SnapshotInfo info;
  final bool enabled;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(info.name, style: AppText.rowLabel),
              ),
              if (info.orphan)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.iconOrange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('模块已卸载',
                      style: AppText.desc12
                          .copyWith(color: AppColors.iconOrange)),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${info.restorable} 项可还原'
            '${info.skipped > 0 ? ' · ${info.skipped} 项需手动处理' : ''}',
            style: AppText.desc12,
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _MiniButton(
                icon: Icons.delete_outline,
                label: '删除',
                color: AppColors.iconRed,
                onTap: enabled ? onDelete : null,
              ),
              const SizedBox(width: 8),
              _MiniButton(
                icon: Icons.settings_backup_restore,
                label: '还原',
                color: AppColors.iconOrange,
                onTap: enabled && info.restorable > 0 ? onRestore : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  const _MiniButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final active = onTap != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? color.withValues(alpha: 0.4) : AppColors.divider,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 14,
                color: active ? color : AppColors.textInactive),
            const SizedBox(width: 5),
            Text(
              label,
              style: AppText.desc12.copyWith(
                color: active ? color : AppColors.textInactive,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '还没有任何快照。\n\n'
        '快照会在模块**首次修改系统设置**时自动生成 —— '
        '启动一个会改设置的模块（比如动画调速）之后回来就能看到。',
        style: AppText.desc12,
        textAlign: TextAlign.center,
      ),
    );
  }
}
