import 'package:flutter/material.dart';

import '../models/iwphone_module.dart';
import '../services/iwphone_service.dart';
import '../theme/app_theme.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/screen_app_bar.dart';

/// 日志页 —— 替代「超级用户」。
///
/// 数据源（与 [IwphoneService] 一致）：
/// - WebUI `GET /api/module/{name}/log?type={log,out,err}&tail=200` 拉取
/// - 不可达时直接 tail `/sdcard/iwphone/logs/modules/{name}/{name}.{type}`
///
/// 左列模块列表 + 右侧（同一屏内）输出/错误/执行概览 三种日志。
/// 设计语言沿用深色主题与圆角 12。
class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key, required this.reloadToken});

  final int reloadToken;

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  bool _loading = true;
  bool _available = false;
  List<IwphoneModule> _modules = const [];
  String? _selectedId;
  IwphoneLogKind _kind = IwphoneLogKind.log;
  String _text = '';

  /// 日志来源：false = 某模块的日志；true = 框架自身运行日志。
  bool _frameworkSource = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant LogsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadToken != widget.reloadToken) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    _available = await IwphoneService.instance.checkAvailable();
    _modules = await IwphoneService.instance.listModules();
    if (_selectedId == null && _modules.isNotEmpty) {
      _selectedId = _modules.first.id;
    }
    if (_selectedId != null && !mounted) return;
    setState(() => _loading = false);
    if (_selectedId != null) {
      _refreshLog();
    }
  }

  Future<void> _refreshLog() async {
    // 框架运行日志：不针对具体模块，也没有 log/out/err 之分
    if (_frameworkSource) {
      final txt = await IwphoneService.instance.runnerLog(tail: 300);
      if (!mounted) return;
      setState(() => _text = txt);
      return;
    }
    final id = _selectedId;
    if (id == null) {
      setState(() => _text = '');
      return;
    }
    final txt = await IwphoneService.instance.moduleLog(id, _kind, tail: 200);
    if (!mounted) return;
    setState(() => _text = txt);
  }

  Future<void> _onSourceChanged(bool framework) async {
    setState(() {
      _frameworkSource = framework;
      _text = '';
    });
    await _refreshLog();
  }

  Future<void> _onSelect(String id) async {
    setState(() {
      _selectedId = id;
      _text = '';
    });
    await _refreshLog();
  }

  Future<void> _onKindChanged(IwphoneLogKind k) async {
    setState(() => _kind = k);
    await _refreshLog();
  }

  /// 当前视图对应的日志归属描述，用于确认弹窗与结果提示。
  String get _scopeLabel {
    if (_frameworkSource) return '框架守护日志';
    final id = _selectedId;
    if (id == null) return '';
    return '模块「$id」的日志';
  }

  /// 清空当前视图对应的日志。
  ///
  /// 模块日志会一次清掉 log/out/err 与 launcher.log —— 只清一种的话
  /// 另外几个还在占盘，用户会以为没清干净。
  /// 后端是**截断**而非删除，所以正在运行的模块继续写日志不受影响。
  Future<void> _clearLogs() async {
    if (!_frameworkSource && _selectedId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择要清空的模块')),
      );
      return;
    }

    final what = _frameworkSource
        ? '· 框架守护日志（modrunner_*.log）'
        : '· $_selectedId.log / .out / .err\n· $_selectedId/launcher.log';

    final ok = await showConfirmDialog(
      context,
      title: '清空日志',
      message: '将清空 $_scopeLabel：\n\n$what\n\n'
          '文件本身会保留（内容置空），正在运行的模块继续正常写日志。\n'
          '历史记录一旦清空无法找回。\n\n确定要清空吗？',
      confirmText: '清空',
    );
    if (!ok || !mounted) return;

    final res = await IwphoneService.instance.clearLogs(
      framework: _frameworkSource,
      moduleId: _selectedId,
    );
    if (!mounted) return;

    await _refreshLog();
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(res.ok ? res.msg : '清空失败：${res.msg}')),
    );
  }

  /// 导出当前视图对应的日志到设备 Download 目录。
  ///
  /// 框架日志没有 log/out/err 之分，只导出守护日志本身；
  /// 模块日志导出的是**当前选中的类型**（与屏幕上看到的一致）。
  Future<void> _exportLog() async {
    if (!_frameworkSource && _selectedId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择要导出的模块')),
      );
      return;
    }

    final kindLabel = switch (_kind) {
      IwphoneLogKind.log => '执行概览',
      IwphoneLogKind.out => 'stdout',
      IwphoneLogKind.err => 'stderr',
    };
    // 弹窗标题保持短句，来源描述放到正文第一行，避免长句尾巴接「成功」
    final what = _frameworkSource
        ? '$_scopeLabel'
        : '$_scopeLabel · $kindLabel';

    final res = await IwphoneService.instance.exportLog(
      framework: _frameworkSource,
      moduleId: _selectedId,
      kind: _kind,
    );
    if (!mounted) return;

    if (!res.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：${res.msg}')),
      );
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('导出成功', style: AppText.cardTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(what, style: AppText.body13),
            const SizedBox(height: 10),
            SelectableText(res.path, style: AppText.monoValue14),
            const SizedBox(height: 12),
            Text(
              '可在「文件管理器 → 内部存储 → Download → iwphone_logs」中找到，'
              '方便发给别人或转存到电脑。',
              style: AppText.desc12,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('知道了',
                style: AppText.rowLabel.copyWith(color: AppColors.accent)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: AppColors.accent,
      backgroundColor: AppColors.surface,
      onRefresh: () async {
        await _load();
        await _refreshLog();
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ScreenAppBar(
              title: '日志',
              actions: [
                AppBarActionIcon(
                  icon: Icons.download_outlined,
                  onTap: _exportLog,
                ),
                AppBarActionIcon(
                  icon: Icons.delete_sweep_outlined,
                  onTap: _clearLogs,
                ),
                AppBarActionIcon(icon: Icons.refresh, onTap: _refreshLog),
              ],
            ),
            const SizedBox(height: 16),
            _SourceTabs(
              framework: _frameworkSource,
              onChanged: _onSourceChanged,
            ),
            const SizedBox(height: 12),
            // 框架日志没有模块维度，也不需要 log/out/err 之分
            if (!_frameworkSource) ...[
              _KindTabs(kind: _kind, onChanged: _onKindChanged),
              const SizedBox(height: 12),
              _ModuleSelectorCard(
                loading: _loading,
                available: _available,
                modules: _modules,
                selectedId: _selectedId,
                onSelect: _onSelect,
              ),
              const SizedBox(height: 16),
            ],
            _LogCard(
              text: _text,
              kind: _kind,
              hasModule: _frameworkSource || _selectedId != null,
            ),
          ],
        ),
      ),
    );
  }
}

/// 日志来源切换：模块日志 / 框架日志。
class _SourceTabs extends StatelessWidget {
  const _SourceTabs({required this.framework, required this.onChanged});

  final bool framework;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _SourceTab(
          label: '模块日志',
          selected: !framework,
          onTap: () => onChanged(false),
        ),
        const SizedBox(width: 8),
        _SourceTab(
          label: '框架日志',
          selected: framework,
          onTap: () => onChanged(true),
        ),
      ],
    );
  }
}

class _SourceTab extends StatelessWidget {
  const _SourceTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (!selected) {
      return GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
          child: Text(label, style: AppText.filterInactive),
        ),
      );
    }
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.accentDim,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(label, style: AppText.filterActive),
      ),
    );
  }
}

/// 日志类型切换：log / out / err。
class _KindTabs extends StatelessWidget {
  const _KindTabs({required this.kind, required this.onChanged});

  final IwphoneLogKind kind;
  final ValueChanged<IwphoneLogKind> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget tab(IwphoneLogKind k, String label) {
      final selected = k == kind;
      return GestureDetector(
        onTap: () => onChanged(k),
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: selected
              ? BoxDecoration(
                  color: AppColors.accentDim,
                  borderRadius: BorderRadius.circular(16),
                )
              : null,
          child: Text(
            label,
            style: selected ? AppText.filterActive : AppText.filterInactive,
          ),
        ),
      );
    }

    return Row(
      children: [
        tab(IwphoneLogKind.log, '执行概览'),
        const SizedBox(width: 8),
        tab(IwphoneLogKind.out, 'stdout'),
        const SizedBox(width: 8),
        tab(IwphoneLogKind.err, 'stderr'),
      ],
    );
  }
}

/// 模块下拉选择器（轻量；为复用设计系统的 chip，用胶囊弹出）。
class _ModuleSelectorCard extends StatelessWidget {
  const _ModuleSelectorCard({
    required this.loading,
    required this.available,
    required this.modules,
    required this.selectedId,
    required this.onSelect,
  });

  final bool loading;
  final bool available;
  final List<IwphoneModule> modules;
  final String? selectedId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return _container('正在加载模块列表…');
    }
    if (!available && modules.isEmpty) {
      return _container('未连接到 WebUI：无法读取模块元数据');
    }
    if (modules.isEmpty) {
      return _container('框架中暂无已安装模块');
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final m in modules)
            GestureDetector(
              onTap: () => onSelect(m.id),
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: m.id == selectedId
                      ? AppColors.accentDim
                      : const Color(0xFF202024),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  m.title.isEmpty ? m.id : m.title,
                  style: m.id == selectedId
                      ? AppText.filterActive
                      : AppText.body13,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _container(String text) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text, style: AppText.body13),
      );
}

/// 日志输出卡片：等宽风格，深色嵌入背景。
class _LogCard extends StatelessWidget {
  const _LogCard({required this.text, required this.kind, required this.hasModule});

  final String text;
  final IwphoneLogKind kind;
  final bool hasModule;

  @override
  Widget build(BuildContext context) {
    final color = switch (kind) {
      IwphoneLogKind.err => const Color(0xFFFF8A80),
      _ => AppColors.textSecondary,
    };
    final display = hasModule
        ? (text.isEmpty ? '（暂无日志）' : text)
        : '请选择模块查看日志';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF050507),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: SelectableText(
        display,
        style: TextStyle(
          fontFamily: AppText.mono,
          fontSize: 12,
          height: 1.4,
          color: color,
        ),
      ),
    );
  }
}
