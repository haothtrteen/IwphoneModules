import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
import '../models/iwphone_module.dart';
import '../services/iwphone_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_switch.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/resource_summary.dart';
import '../widgets/screen_app_bar.dart';
import '../widgets/snapshot_sheet.dart';
import 'module_config_screen.dart';
import 'module_install_screen.dart';
import 'resources_screen.dart';

/// 模块卡片的视图模型。
///
/// 用模块 id 稳定映射图标/颜色（同 Modules 原设计）。
class IwphoneModuleItem {
  const IwphoneModuleItem({
    required this.module,
    required this.icon,
    required this.iconColor,
  });

  final IwphoneModule module;
  final IconData icon;
  final Color iconColor;

  String get id => module.id;
  String get name => module.title;
  String get description => module.description;
  bool get running => module.running;
  bool get hasMain => module.hasMain;

  /// 是否有 action.sh（显示「动作」按钮）。
  bool get hasAction => module.hasAction;

  /// 是否有 webroot/（显示「WebUI」入口）。
  bool get hasWebroot => module.hasWebroot;

  /// 兼容预检判定（原生模块为空）。
  String get compatVerdict => module.compatVerdict;

  String get compatReasons => module.compatReasons;

  /// 是否有写前快照（显示「还原」按钮）。
  bool get hasSnapshot => module.hasSnapshot;
  String get version => module.displayVersion;

  /// 模块是否声明了可配置项（有 config.prop 才显示「配置」入口）。
  bool get hasConfig => module.hasConfig;

  /// 运行中 = 强调绿，未启动但 has_main = 灰白，没有 main.sh = 未激活灰。
  Color get versionColor {
    if (running) return AppColors.accent;
    if (hasMain) return AppColors.textSecondary;
    return AppColors.textInactive;
  }

  String get stateLabel => running
      ? '${AppStrings.t('modules.running')} (PID ${module.pid ?? '?'})'
      : hasMain
          ? AppStrings.t('modules.installed')
          : AppStrings.t('modules.resourceModule');

  /// 是否存在资源冲突（与其他模块声明了同一资源）。
  bool get hasConflict => module.hasConflict;

  /// 冲突对方列表。
  List<String> get blockedBy => module.blockedBy;

  /// 该模块碰过的资源（用于详情展示）。
  List<String> get resources => module.resources;

  /// 冲突提示文本。
  String get conflictLabel {
    if (!hasConflict) return '';
    final who = blockedBy.join(AppStrings.t('modules.conflictSeparator'));
    return '${AppStrings.t('modules.conflictPrefix')}$who'
        '${AppStrings.t('modules.conflictSuffix')}';
  }
}

// ⚠ 不能是 const：调色板现在是运行时值（AppColors 是 getter，主题会切换），
// const 会在编译期烘死深色值。顶层 final 是惰性初始化，够用。
final List<Color> _iconPalette = [
  AppColors.iconPurple,
  AppColors.iconGreen,
  AppColors.iconOrange,
  AppColors.iconRed,
  AppColors.iconBlue,
  AppColors.iconDeepOrange,
];

const List<IconData> _iconSet = [
  Icons.extension,
  Icons.memory,
  Icons.tune,
  Icons.graphic_eq,
  Icons.text_fields,
  Icons.speed,
];

int _stableHash(String value) {
  var hash = 0;
  for (final unit in value.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return hash;
}

IwphoneModuleItem _toItem(IwphoneModule m) {
  final hash = _stableHash(m.id);
  return IwphoneModuleItem(
    module: m,
    icon: _iconSet[hash % _iconSet.length],
    iconColor: _iconPalette[hash % _iconPalette.length],
  );
}

/// 模块页 —— 1:1 还原设计稿「Modules Screen」
///
/// 数据源切到 [IwphoneService]：
/// - WebUI 在时：拉取含 running 状态的真实列表
/// - WebUI 不可达：回退读 `/sdcard/iwphone/state/work/*/iwphone.prop`
///
/// 启动 / 停止走 WebUI POST；权限拒绝或不可达时回滚 + SnackBar。
class ModulesScreen extends StatefulWidget {
  const ModulesScreen({super.key, required this.reloadToken});

  final int reloadToken;

  @override
  State<ModulesScreen> createState() => _ModulesScreenState();
}

class _ModulesScreenState extends State<ModulesScreen> {
  int _filter = 0; // 0 全部 / 1 运行中 / 2 已停止
  bool _loading = true;
  bool _available = false;
  String? _error;
  List<IwphoneModuleItem> _items = const [];

  /// 资源占用概览（顶部窄条用）。与模块列表一起刷新。
  ConflictReport _report = ConflictReport.empty;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ModulesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadToken != widget.reloadToken) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final avail = await IwphoneService.instance.checkAvailable();
    final list = await IwphoneService.instance.listModules();
    // 资源概览只做展示，失败就保持空白态，不阻断模块列表
    final report = avail
        ? await IwphoneService.instance.getConflicts(tail: 50)
        : ConflictReport.empty;
    if (!mounted) return;
    setState(() {
      _available = avail;
      _items = list.map(_toItem).toList();
      _report = report;
      _loading = false;
    });
  }

  /// 进入完整的资源占用页，回来后重新拉一次（用户可能在里面处理了冲突）。
  Future<void> _openResources() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ResourcesScreen()),
    );
    if (!mounted) return;
    await _load();
  }

  Future<void> _onToggle(int index, bool wantRun) async {
    final previous = _items[index];
    setState(() {
      _items[index] = IwphoneModuleItem(
        module: previous.module.copyWith(
          running: wantRun,
          pid: wantRun ? previous.module.pid : null,
        ),
        icon: previous.icon,
        iconColor: previous.iconColor,
      );
    });

    final ok = wantRun
        ? await IwphoneService.instance.moduleStart(previous.id)
        : await IwphoneService.instance.moduleStop(previous.id);

    if (!mounted) return;
    if (!ok) {
      // 回滚
      setState(() => _items[index] = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            wantRun
                ? AppStrings.t('modules.startFailed')
                : AppStrings.t('modules.stopFailed'),
          ),
        ),
      );
      return;
    }
    // 成功后后台再拉一次，刷新 running/pid
    Future.delayed(const Duration(milliseconds: 800), _load);
  }

  /// 打开模块安装页（本地导入 + 框架包列表 + 安装进度）。
  Future<void> _openInstallScreen() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModuleInstallScreen(service: IwphoneService.instance),
      ),
    );
    // 回来刷新：可能装了新模块
    if (mounted) await _load();
  }

  /// 安装 / 重装模块。重装会覆盖模块目录，同样需要二次确认。
  Future<void> _installModule(
    IwphonePackage pkg, {
    required bool isReinstall,
  }) async {
    final ok = await showConfirmDialog(
      context,
      title: isReinstall
          ? AppStrings.t('modules.reinstallTitle')
          : AppStrings.t('modules.installTitle'),
      message: isReinstall
          ? '${AppStrings.t('modules.reinstallConfirmPrefix')}${pkg.name}'
              '${AppStrings.t('modules.reinstallConfirmSuffix')}'
          : '${AppStrings.t('modules.installConfirmPrefix')}${pkg.name}'
              '${AppStrings.t('modules.installConfirmSuffix')}',
      confirmText: isReinstall
          ? AppStrings.t('modules.reinstall')
          : AppStrings.t('modules.install'),
      danger: isReinstall,
    );
    if (!ok || !mounted) return;

    setState(() => _loading = true);
    final success = await IwphoneService.instance.moduleInstall(pkg.name);
    if (!mounted) return;

    IwphoneService.instance.invalidate();
    await _load();
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? (isReinstall
                  ? '${AppStrings.t('modules.reinstalledToastPrefix')}'
                      '${pkg.name}'
                  : '${AppStrings.t('modules.installedToastPrefix')}'
                      '${pkg.name}')
              : AppStrings.t('modules.installFailed'),
        ),
      ),
    );
  }

  /// 模块操作菜单：重装 / 卸载。
  /// 打开模块配置页。保存后刷新列表，让「已配置」状态与界面同步。
  Future<void> _openModuleConfig(IwphoneModuleItem item) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => ModuleConfigScreen(
          moduleName: item.id,
          service: IwphoneService.instance,
        ),
      ),
    );
    if (changed == true && mounted) await _load();
  }

  /// 执行模块动作（action.sh）。输出用底部弹层展示 —— 动作往往有输出要看。
  Future<void> _runModuleAction(IwphoneModuleItem item) async {
    setState(() => _loading = true);
    final res = await IwphoneService.instance.runModuleAction(item.id);
    if (!mounted) return;
    setState(() => _loading = false);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${item.name}${AppStrings.t('modules.actionOutputSuffix')}',
                style: AppText.cardTitle),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Text(
                  res.msg.isEmpty
                      ? AppStrings.t('modules.noOutput')
                      : res.msg,
                  style: AppText.monoValue14.copyWith(fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 统一的轻提示。
  void _toast(String text, {bool ok = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: ok ? null : AppColors.iconRed,
      ),
    );
  }

  /// 还原写前快照：先拉快照展示「会改什么」，用户确认后再执行。
  ///
  /// 做成两步是为了**不盲还原** —— 用户能看到每项的当前值与将还原的值。
  /// 服务端会先停模块（常驻模块的守卫循环会周期性把值改回去）。
  Future<void> _restoreSnapshot(IwphoneModuleItem item) async {
    setState(() => _loading = true);
    final snap = await IwphoneService.instance.moduleSnapshot(item.id);
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
      builder: (_) => SnapshotSheet(title: item.name, items: snap.items),
    );
    if (ok != true || !mounted) return;

    setState(() => _loading = true);
    final res = await IwphoneService.instance.restoreModuleSnapshot(item.id);
    if (!mounted) return;
    setState(() => _loading = false);
    IwphoneService.instance.invalidate();
    await _load();
    if (!mounted) return;
    _toast(
      res.ok
          ? res.msg
          : '${AppStrings.t('modules.restoreFailedPrefix')}${res.msg}',
      ok: res.ok,
    );
  }

  Future<void> _showModuleActions(IwphoneModuleItem item) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _ModuleActionSheet(item: item),
    );
    if (action == null || !mounted) return;

    switch (action) {
      case 'reinstall':
        await _installModule(
          IwphonePackage(name: item.id, file: '', installed: true),
          isReinstall: true,
        );
      case 'uninstall':
        await _uninstallModule(item);
    }
  }

  /// 卸载模块 —— **不可撤销**，必须二次确认。
  ///
  /// 若该模块有写前快照（改过系统设置），确认框里默认勾选「同时还原」：
  /// 模块卸载后快照虽然会保留，但用户多半希望当场把设置还原干净。
  /// 勾选与否都会保留快照，之后仍可在「设置 → 历史快照」里补救。
  Future<void> _uninstallModule(IwphoneModuleItem item) async {
    var alsoRestore = item.hasSnapshot;

    if (item.hasSnapshot) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            backgroundColor: AppColors.surface,
            title: Text(AppStrings.t('modules.uninstallTitle'),
                style: AppText.cardTitle),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${AppStrings.t('modules.uninstallIntroPrefix')}'
                    '${item.name}'
                    '${AppStrings.t('modules.uninstallIntroSuffix')}'
                    '${item.id}/'
                    '${AppStrings.t('modules.uninstallRestoreSuffix')}',
                    style: AppText.body13,
                  ),
                  CheckboxListTile(
                    value: alsoRestore,
                    onChanged: (v) => setLocal(() => alsoRestore = v ?? false),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    title: Text(AppStrings.t('modules.restoreSettingsToo'),
                        style: AppText.rowLabel),
                    subtitle: Text(
                      AppStrings.t('modules.restoreSettingsTooHint'),
                      style: AppText.desc12,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(AppStrings.t('common.cancel'),
                    style: AppText.rowLabel
                        .copyWith(color: AppColors.textSecondary)),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(AppStrings.t('modules.uninstall'),
                    style:
                        AppText.rowLabel.copyWith(color: AppColors.iconRed)),
              ),
            ],
          ),
        ),
      );
      if (confirmed != true || !mounted) return;
    } else {
      final ok = await showConfirmDialog(
        context,
        title: AppStrings.t('modules.uninstallTitle'),
        message: '${AppStrings.t('modules.uninstallIntroPrefix')}'
            '${item.name}'
            '${AppStrings.t('modules.uninstallIntroSuffix')}'
            '${item.id}/'
            '${AppStrings.t('modules.uninstallConfirmSuffix')}',
        confirmText: AppStrings.t('modules.uninstall'),
      );
      if (ok != true || !mounted) return;
    }

    setState(() => _loading = true);

    // 先还原（若勾选）。还原失败**不阻断卸载** —— 快照会保留，
    // 用户可以稍后在「设置 → 历史快照」里重试。
    var restored = '';
    if (alsoRestore) {
      final r = await IwphoneService.instance.restoreModuleSnapshot(item.id);
      restored = r.ok
          ? AppStrings.t('modules.restoredSettings')
          : '${AppStrings.t('modules.snapshotRestoreFailedPrefix')}${r.msg}'
              '${AppStrings.t('modules.snapshotRestoreFailedSuffix')}';
    }

    final success = await IwphoneService.instance.moduleUninstall(item.id);
    if (!mounted) return;

    IwphoneService.instance.invalidate();
    await _load();
    if (!mounted) return;

    _toast(
      success
          ? '${AppStrings.t('modules.uninstalledToastPrefix')}${item.name}'
              '${restored.isEmpty ? '' : ' · ' + restored}'
          : AppStrings.t('modules.uninstallFailed'),
      ok: success,
    );
  }

  /// 批量操作的统一入口：二次确认 → 调用 → 刷新 → 提示。
  Future<void> _bulkAction({
    required String title,
    required String message,
    required String confirmText,
    required Future<BulkResult> Function() action,
  }) async {
    final ok = await showConfirmDialog(
      context,
      title: title,
      message: message,
      confirmText: confirmText,
    );
    if (!ok || !mounted) return;

    setState(() => _loading = true);
    final res = await action();
    if (!mounted) return;

    IwphoneService.instance.invalidate();
    await _load();
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          res.ok
              ? res.message
              : '${AppStrings.t('modules.actionFailedPrefix')}${res.message}',
        ),
      ),
    );
  }

  /// 全部启动：逐个调用 run（只处理有 main.sh 的模块）。
  Future<void> _startAll() async {
    final targets = _items.where((e) => e.hasMain && !e.running).toList();
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.t('modules.noStartableModules')),
        ),
      );
      return;
    }

    final ok = await showConfirmDialog(
      context,
      title: AppStrings.t('modules.startAllTitle'),
      message:
          '${AppStrings.t('modules.startAllConfirmPrefix')}${targets.length}'
          '${AppStrings.t('modules.startAllConfirmMiddle')}'
          '${targets.map((e) => '· ${e.name}').join('\n')}\n\n'
          '${AppStrings.t('modules.startAllConfirmSuffix')}',
      confirmText: AppStrings.t('modules.startAll'),
      danger: false,
    );
    if (!ok || !mounted) return;

    setState(() => _loading = true);
    var done = 0;
    for (final e in targets) {
      if (await IwphoneService.instance.moduleStart(e.id)) done++;
    }
    if (!mounted) return;

    IwphoneService.instance.invalidate();
    await _load();
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${AppStrings.t('modules.startedCountPrefix')}$done / '
          '${targets.length}${AppStrings.t('modules.startedCountSuffix')}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: AppColors.accent,
      backgroundColor: AppColors.surface,
      onRefresh: _load,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ScreenAppBar(
              title: AppStrings.t('modules.title'),
              actions: [
                AppBarActionIcon(
                  icon: Icons.add_circle_outline,
                  onTap: _openInstallScreen,
                ),
                AppBarActionIcon(
                  icon: Icons.refresh,
                  onTap: _load,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _FilterTab(
                  label: AppStrings.t('modules.filterAll'),
                  selected: _filter == 0,
                  onTap: () => setState(() => _filter = 0),
                ),
                const SizedBox(width: 8),
                _FilterTab(
                  label: AppStrings.t('modules.running'),
                  selected: _filter == 1,
                  onTap: () => setState(() => _filter = 1),
                ),
                const SizedBox(width: 8),
                _FilterTab(
                  label: AppStrings.t('modules.filterStopped'),
                  selected: _filter == 2,
                  onTap: () => setState(() => _filter = 2),
                ),
              ],
            ),
            if (_available) ...[
              const SizedBox(height: 12),
              ResourceSummaryBar(
                report: _report,
                loading: _loading,
                onTap: _openResources,
              ),
              const SizedBox(height: 12),
              _BulkBar(
                busy: _loading,
                onStartAll: _startAll,
                onStopAll: () => _bulkAction(
                  title: AppStrings.t('modules.stopAllTitle'),
                  message: AppStrings.t('modules.stopAllConfirm'),
                  confirmText: AppStrings.t('modules.stopAll'),
                  action: () => IwphoneService.instance.stopAllModules(),
                ),
                onForceStop: () => _bulkAction(
                  title: AppStrings.t('modules.forceStopAllTitle'),
                  message: AppStrings.t('modules.forceStopConfirm'),
                  confirmText: AppStrings.t('modules.forceStop'),
                  action: () => IwphoneService.instance.forceStopAllModules(),
                ),
                onRestartAll: () => _bulkAction(
                  title: AppStrings.t('modules.restartAllTitle'),
                  message: AppStrings.t('modules.restartAllConfirm'),
                  confirmText: AppStrings.t('modules.restartAll'),
                  action: () => IwphoneService.instance.restartAllModules(),
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (_loading)
              _MessageCard(text: AppStrings.t('modules.loadingModules'))
            else if (!_available)
              _MessageCard(
                text: '${AppStrings.t('modules.notConnectedPrefix')}'
                    'adb shell sh /data/local/tmp/iwphone/Main.sh &',
              )
            else if (_error != null)
              _MessageCard(text: _error!)
            else if (_visibleIndices.isEmpty)
              _MessageCard(text: AppStrings.t('modules.noMatchingModules'))
            else
              for (final i in _visibleIndices) ...[
                _ModuleCard(
                  item: _items[i],
                  onChanged: (v) => _onToggle(i, v),
                  onManage: () => _showModuleActions(_items[i]),
                  onOpenConfig: () => _openModuleConfig(_items[i]),
                  onRunAction: () => _runModuleAction(_items[i]),
                  onRestore: () => _restoreSnapshot(_items[i]),
                ),
                const SizedBox(height: 16),
              ],
          ],
        ),
      ),
    );
  }

  Iterable<int> get _visibleIndices {
    return [
      for (var i = 0; i < _items.length; i++)
        if (_filter == 0 ||
            (_filter == 1 && _items[i].running) ||
            (_filter == 2 && !_items[i].running && _items[i].hasMain))
          i,
    ];
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: AppText.body13,
        textAlign: TextAlign.center,
      ),
    );
  }
}

class _FilterTab extends StatelessWidget {
  const _FilterTab({
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
          padding: const EdgeInsets.symmetric(vertical: 6),
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

/// 模块批量操作条：全部启动 / 全部停止 / 强制停止 / 全部重启。
///
/// 「强制停止」不依赖框架锁 —— 通过进程工作目录识别模块进程并连根终止，
/// 用于模块卡死或锁丢失的情况。
class _BulkBar extends StatelessWidget {
  const _BulkBar({
    required this.busy,
    required this.onStartAll,
    required this.onStopAll,
    required this.onForceStop,
    required this.onRestartAll,
  });

  final bool busy;
  final VoidCallback onStartAll;
  final VoidCallback onStopAll;
  final VoidCallback onForceStop;
  final VoidCallback onRestartAll;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _BulkBtn(
            icon: Icons.play_arrow_rounded,
            label: AppStrings.t('modules.startAll'),
            color: AppColors.accent,
            onTap: busy ? null : onStartAll,
          ),
          _BulkBtn(
            icon: Icons.stop_rounded,
            label: AppStrings.t('modules.stopAll'),
            color: AppColors.iconOrange,
            onTap: busy ? null : onStopAll,
          ),
          _BulkBtn(
            icon: Icons.dangerous_outlined,
            label: AppStrings.t('modules.forceStop'),
            color: AppColors.iconRed,
            onTap: busy ? null : onForceStop,
          ),
          _BulkBtn(
            icon: Icons.restart_alt_rounded,
            label: AppStrings.t('modules.restartAll'),
            color: AppColors.iconBlue,
            onTap: busy ? null : onRestartAll,
          ),
        ],
      ),
    );
  }
}

class _BulkBtn extends StatelessWidget {
  const _BulkBtn({
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
    final disabled = onTap == null;
    final fg = disabled ? AppColors.textInactive : color;

    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: [
              Icon(icon, size: 20, color: fg),
              const SizedBox(height: 3),
              Text(
                label,
                style: AppText.desc12.copyWith(color: fg),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 模块卡片。
///
/// 交互仿 Magisk：卡片右下角有个 `<>` 按钮，点它（或点卡片空白处）
/// 会**原地展开**一排操作按钮，再点一次收起。
///
/// 相比之前的「整卡点击弹底部菜单」，原地展开的好处是操作就在卡片上、
/// 不用把手移到屏幕底部，而且展开状态可见、不会误以为没反应。
///
/// 开关本身在 Row 内消费点击，不会触发展开 —— 否则想改开关状态却把卡片展开了。
class _ModuleCard extends StatefulWidget {
  const _ModuleCard({
    required this.item,
    required this.onChanged,
    required this.onManage,
    required this.onOpenConfig,
    required this.onRunAction,
    required this.onRestore,
  });

  final IwphoneModuleItem item;
  final ValueChanged<bool> onChanged;

  /// 展开区里点了「重装 / 卸载」时触发（这两个需要二次确认，走底部菜单）。
  final VoidCallback onManage;

  /// 展开区里点了「配置」时触发。仅 has_config 的模块会显示该按钮。
  final VoidCallback onOpenConfig;

  /// 展开区里点了「动作」时触发。仅 has_action 的模块会显示该按钮。
  final VoidCallback onRunAction;

  /// 展开区里点了「还原」时触发。仅 has_snapshot 的模块会显示该按钮。
  final VoidCallback onRestore;

  @override
  State<_ModuleCard> createState() => _ModuleCardState();
}

class _ModuleCardState extends State<_ModuleCard> {
  bool _expanded = false;

  void _toggleExpand() {
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    // has_main=false 的资源型模块无开关（仅展示）
    final hasSwitch = widget.item.hasMain;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onTap: _toggleExpand,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: _expanded
                  ? const BorderRadius.vertical(top: Radius.circular(12))
                  : BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      color: widget.item.iconColor,
                      child: Icon(widget.item.icon, size: 22, color: Colors.white),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.item.name,
                            style: AppText.itemName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Text(
                                widget.item.version,
                                style: AppText.monoVersion11.copyWith(
                                  color: widget.item.versionColor,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  widget.item.stateLabel,
                                  style: AppText.desc12,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          if (widget.item.hasConflict) ...[
                            const SizedBox(height: 6),
                            _ConflictBadge(item: widget.item),
                          ],
                          if (widget.item.compatVerdict.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            _CompatBadge(item: widget.item),
                          ],
                          if (widget.item.description.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              widget.item.description,
                              style: AppText.desc12,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (hasSwitch)
                      AppSwitch(value: widget.item.running, onChanged: widget.onChanged),
                  ],
                ),
                const SizedBox(height: 10),
                // 右下角的 <> 按钮（Magisk 风格）
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _ExpandChip(expanded: _expanded, onTap: _toggleExpand),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Container(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(12)),
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (widget.item.hasConfig)
                  _ActionChip(
                    icon: Icons.tune_rounded,
                    label: AppStrings.t('modules.config'),
                    color: AppColors.accent,
                    onTap: widget.onOpenConfig,
                  ),
                if (widget.item.hasAction)
                  _ActionChip(
                    icon: Icons.play_circle_outline,
                    label: AppStrings.t('modules.action'),
                    color: AppColors.iconBlue,
                    onTap: widget.onRunAction,
                  ),
                if (widget.item.hasSnapshot)
                  _ActionChip(
                    icon: Icons.settings_backup_restore,
                    label: AppStrings.t('modules.restore'),
                    color: AppColors.iconOrange,
                    onTap: widget.onRestore,
                  ),
                _ActionChip(
                  icon: Icons.refresh_rounded,
                  label: AppStrings.t('modules.reinstall'),
                  color: AppColors.iconOrange,
                  onTap: widget.onManage,
                ),
                _ActionChip(
                  icon: Icons.delete_outline,
                  label: AppStrings.t('modules.uninstall'),
                  color: AppColors.iconRed,
                  onTap: widget.onManage,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 卡片右下角的 `<>` / `</>` 折叠指示按钮。
class _ExpandChip extends StatelessWidget {
  const _ExpandChip({required this.expanded, required this.onTap});

  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: expanded
              ? AppColors.accent.withValues(alpha: 0.14)
              : AppColors.bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: expanded ? AppColors.accent : AppColors.divider,
          ),
        ),
        child: Text(
          expanded ? '</>' : '<>',
          style: AppText.monoValue14.copyWith(
            fontSize: 12,
            color: expanded ? AppColors.accent : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// 展开区里的单个操作按钮。
class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: AppColors.bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            Text(label, style: AppText.desc12.copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}

/// 资源冲突角标：模块与他人声明了同一系统资源时显示。
///
/// 点击展开冲突详情（被哪些模块占用、涉及哪些资源）。
///
/// 注意：本组件嵌在整卡可点的 [GestureDetector] 内。用 [GestureDetector]
/// 会被外层「整卡菜单」抢走手势（点角标会弹出重装/卸载菜单），
/// 因此这里用 [InkWell] + `onTap` 并显式声明命中行为，
/// 让内层在手势竞技场里优先拿到事件。
class _ConflictBadge extends StatelessWidget {
  const _ConflictBadge({required this.item});

  final IwphoneModuleItem item;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        onTap: () => _showConflictDetail(context, item),
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: AppColors.iconRed.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 12, color: AppColors.iconRed),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  item.conflictLabel,
                  style: AppText.desc12.copyWith(
                    color: AppColors.iconRed,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 弹出冲突详情。
Future<void> _showConflictDetail(
  BuildContext context,
  IwphoneModuleItem item,
) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 18, color: AppColors.iconRed),
                const SizedBox(width: 8),
                Text(AppStrings.t('modules.conflictTitle'),
                    style: AppText.cardTitle),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              AppStrings.t('modules.conflictDesc'),
              style: AppText.desc12,
            ),
            const SizedBox(height: 14),
            Text(AppStrings.t('modules.conflictModules'),
                style: AppText.rowLabel),
            const SizedBox(height: 6),
            for (final w in item.blockedBy)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Container(width: 4, height: 4, color: AppColors.iconRed),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(w,
                          style: AppText.body13,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
            if (item.resources.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(AppStrings.t('modules.conflictResources'),
                  style: AppText.rowLabel),
              const SizedBox(height: 6),
              for (final r in item.resources)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(r,
                      style: AppText.monoValue14.copyWith(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      )),
                ),
            ],
            const SizedBox(height: 16),
            Text(
              AppStrings.t('modules.conflictAdvice'),
              style: AppText.desc12,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

/// 兼容层预检角标：告诉用户这个外来模块在我们框架里「预期表现如何」。
/// （判定原因点开角标可见）
class _CompatBadge extends StatelessWidget {
  const _CompatBadge({required this.item});

  final IwphoneModuleItem item;

  @override
  Widget build(BuildContext context) {
    final v = item.compatVerdict;
    final (label, color) = switch (v) {
      'ok' => (AppStrings.t('modules.compatOk'), AppColors.accent),
      'blocked' => (
        AppStrings.t('modules.compatBlocked'),
        AppColors.iconRed
      ),
      'unknown' => (
        AppStrings.t('modules.compatUnknown'),
        AppColors.iconOrange
      ),
      _ => ('', AppColors.textSecondary),
    };
    if (label.isEmpty) return const SizedBox.shrink();

    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => _showCompatDetail(context, item),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(label, style: AppText.desc12.copyWith(color: color)),
        ),
      ),
    );
  }

  void _showCompatDetail(BuildContext context, IwphoneModuleItem item) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${AppStrings.t('modules.compatDetailTitle')} · ${item.name}',
                style: AppText.cardTitle,
              ),
              const SizedBox(height: 12),
              Text(
                item.compatReasons.isEmpty
                    ? AppStrings.t('modules.noReasons')
                    : item.compatReasons,
                style: AppText.body13,
              ),
              const SizedBox(height: 12),
              Text(
                AppStrings.t('modules.compatDesc'),
                style: AppText.desc12,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 单个模块的操作菜单（底部弹出）：重装 / 卸载。
class _ModuleActionSheet extends StatelessWidget {
  const _ModuleActionSheet({required this.item});

  final IwphoneModuleItem item;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(item.name, style: AppText.cardTitle),
            const SizedBox(height: 4),
            Text(item.id, style: AppText.desc12),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.refresh_rounded,
                color: AppColors.iconOrange,
              ),
              title: Text(AppStrings.t('modules.reinstallTitle'),
                  style: AppText.rowLabel),
              subtitle: Text(
                AppStrings.t('modules.reinstallHint'),
                style: AppText.desc12,
              ),
              onTap: () => Navigator.of(context).pop('reinstall'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                Icons.delete_outline,
                color: AppColors.iconRed,
              ),
              title: Text(AppStrings.t('modules.uninstallTitle'),
                  style: AppText.rowLabel),
              subtitle: Text(
                AppStrings.t('modules.uninstallHint'),
                style: AppText.desc12,
              ),
              onTap: () => Navigator.of(context).pop('uninstall'),
            ),
          ],
        ),
      ),
    );
  }
}
