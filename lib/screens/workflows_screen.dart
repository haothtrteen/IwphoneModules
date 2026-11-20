import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
import '../models/workflow.dart';
import '../services/monitor_service.dart';
import '../services/trigger_catalog.dart';
import '../theme/app_theme.dart';
import '../widgets/back_icon_button.dart';
import '../widgets/confirm_dialog.dart';
import 'workflow_editor_screen.dart';

/// 可视化工作流列表（借鉴 vFlow 的工作流管理）。
///
/// 两类来源：
/// - **本地**：App 里搭的，可编辑 / 删除 / 导出成 .iwp；
/// - **模块自带**：`.iwp` 里带了 automation.json，装完就在这儿出现，只读。
class WorkflowsScreen extends StatefulWidget {
  const WorkflowsScreen({super.key});

  @override
  State<WorkflowsScreen> createState() => _WorkflowsScreenState();
}

class _WorkflowsScreenState extends State<WorkflowsScreen> {
  List<Workflow> _local = const [];
  List<Workflow> _fromModules = const [];
  Map<String, String> _armed = const {};
  bool _loading = true;
  String _moduleError = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool forceScan = false}) async {
    setState(() => _loading = true);
    final local = await MonitorService.instance.workflows();
    final fromModules = await MonitorService.instance.moduleWorkflows(force: forceScan);
    final armed = await MonitorService.instance.armedWorkflows();
    final err = await MonitorService.instance.moduleAutomationError();
    if (!mounted) return;
    setState(() {
      _local = local;
      _fromModules = fromModules;
      _armed = armed;
      _moduleError = err;
      _loading = false;
    });
  }

  Future<void> _new() async {
    final w = Workflow(
      id: 'wf_${DateTime.now().millisecondsSinceEpoch}',
      name: AppStrings.t('auto.new'),
    );
    await MonitorService.instance.saveWorkflow(w);
    if (!mounted) return;
    await _openEditor(w);
  }

  Future<void> _openEditor(Workflow w) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => WorkflowEditorScreen(workflow: w)),
    );
    await _load();
  }

  Future<void> _run(Workflow w) async {
    final r = await MonitorService.instance.runWorkflow(w.id);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(AppStrings.t('auto.runResult'), style: AppText.cardTitle),
        content: Text('${r.ok ? 'OK' : 'FAIL'}\n${r.msg}', style: AppText.body13),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _toggleArm(Workflow w) async {
    if (_armed.containsKey(w.id)) {
      await MonitorService.instance.disarmWorkflow(w.id);
      if (!mounted) return;
      _snack(AppStrings.t('auto.disarmed'));
      await _load();
      return;
    }
    if (w.trigger == TriggerCatalog.manual) {
      _snack(AppStrings.t('auto.needTrigger'));
      await _openEditor(w);
      return;
    }
    final ok = await MonitorService.instance.armWorkflow(w.id, w.trigger);
    if (!mounted) return;
    _snack(ok
        ? '${AppStrings.t('auto.armed')} · ${TriggerCatalog.label(w.trigger)}'
        : AppStrings.t('auto.armFailed'));
    await _load();
  }

  /// 导出成 iwphone 模块包（.iwp）。
  Future<void> _export(Workflow w) async {
    final ctrl = TextEditingController(
      text: w.name.trim().isEmpty ? 'auto_module' : w.name.trim(),
    );
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(AppStrings.t('auto.exportTitle'), style: AppText.cardTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(AppStrings.t('auto.exportHint'), style: AppText.desc12),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              style: AppText.body13,
              decoration: InputDecoration(
                labelText: AppStrings.t('auto.exportName'),
                labelStyle: AppText.desc12,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: Text(AppStrings.t('auto.export')),
          ),
        ],
      ),
    );
    // 不 dispose：showDialog 的 future 结束时弹层可能还在退场动画里，
    // 立刻释放 controller 会撞上 "used after being disposed"
    if (name == null || name.isEmpty || !mounted) return;

    final r = await MonitorService.instance.exportWorkflow(w.id, name);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(AppStrings.t('auto.exportTitle'), style: AppText.cardTitle),
        content: Text('${r.ok ? 'OK' : 'FAIL'}\n${r.msg}', style: AppText.body13),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
  }

  /// 模块带来的流程不能就地改 —— 复制一份到本地再编辑。
  Future<void> _copyToLocal(Workflow w) async {
    final copy = Workflow(
      id: 'wf_${DateTime.now().millisecondsSinceEpoch}',
      name: '${w.name} (副本)',
      steps: w.steps
          .map((s) => WorkflowStep(moduleId: s.moduleId, params: Map.of(s.params), disabled: s.disabled))
          .toList(),
      stopOnError: w.stopOnError,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      trigger: w.trigger,
    );
    final ok = await MonitorService.instance.saveWorkflow(copy);
    if (!mounted) return;
    if (!ok) {
      _snack(AppStrings.t('auto.save'));
      return;
    }
    await _openEditor(copy);
  }

  Future<void> _delete(Workflow w) async {
    final ok = await showConfirmDialog(
      context,
      title: AppStrings.t('auto.delete'),
      message: '${AppStrings.t('auto.delete')} ${w.name}?',
      confirmText: AppStrings.t('auto.delete'),
    );
    if (ok != true || !mounted) return;
    if (_armed.containsKey(w.id)) {
      await MonitorService.instance.disarmWorkflow(w.id);
    }
    await MonitorService.instance.deleteWorkflow(w.id);
    await _load();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        leading: const BackIconButton(),
        title: Text(AppStrings.t('auto.workflows'), style: AppText.appTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _load(forceScan: true),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _new,
        backgroundColor: AppColors.accent,
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              color: AppColors.accent,
              backgroundColor: AppColors.surface,
              onRefresh: () => _load(forceScan: true),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
                children: [
                  Text(AppStrings.t('auto.workflowsHint'), style: AppText.desc12),
                  const SizedBox(height: 16),
                  if (_local.isNotEmpty) ...[
                    Text(AppStrings.t('auto.sectionLocal'), style: AppText.sectionTitle),
                    const SizedBox(height: 8),
                    for (final w in _local)
                      _WorkflowCard(
                        workflow: w,
                        armedTrigger: _armed[w.id],
                        onTap: () => _openEditor(w),
                        onRun: () => _run(w),
                        onArm: () => _toggleArm(w),
                        onExport: () => _export(w),
                        onDelete: () => _delete(w),
                      ),
                    const SizedBox(height: 16),
                  ],
                  Text(AppStrings.t('auto.sectionModule'), style: AppText.sectionTitle),
                  const SizedBox(height: 8),
                  if (_fromModules.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.divider),
                      ),
                      child: Text(
                        _moduleError.isEmpty
                            ? AppStrings.t('auto.moduleEmpty')
                            : '${AppStrings.t('auto.moduleEmpty')}\n$_moduleError',
                        style: AppText.desc12,
                      ),
                    )
                  else
                    for (final w in _fromModules)
                      _WorkflowCard(
                        workflow: w,
                        armedTrigger: _armed[w.id],
                        onTap: () => _openEditor(w),
                        onRun: () => _run(w),
                        onArm: () => _toggleArm(w),
                        onCopy: () => _copyToLocal(w),
                      ),
                ],
              ),
            ),
    );
  }
}

class _WorkflowCard extends StatelessWidget {
  const _WorkflowCard({
    required this.workflow,
    required this.armedTrigger,
    required this.onTap,
    required this.onRun,
    required this.onArm,
    this.onExport,
    this.onDelete,
    this.onCopy,
  });

  final Workflow workflow;

  /// 非 null 表示已武装，值是触发器 key。
  final String? armedTrigger;
  final VoidCallback onTap;
  final VoidCallback onRun;
  final VoidCallback onArm;
  final VoidCallback? onExport;
  final VoidCallback? onDelete;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final armed = armedTrigger != null;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: armed ? AppColors.accent.withValues(alpha: 0.5) : AppColors.divider,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(workflow.name, style: AppText.cardTitle),
                        const SizedBox(height: 3),
                        Text(
                          '${TriggerCatalog.label(workflow.trigger)} · '
                          '${workflow.steps.length} ${AppStrings.t('auto.steps')}',
                          style: AppText.desc12,
                        ),
                      ],
                    ),
                  ),
                  if (armed)
                    Container(
                      margin: const EdgeInsets.only(right: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: AppColors.accentDim,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(AppStrings.t('auto.armed'),
                          style: AppText.badge.copyWith(color: AppColors.accent)),
                    ),
                  PopupMenuButton<String>(
                    icon: Icon(Icons.more_horiz, color: AppColors.textSecondary),
                    color: AppColors.surface,
                    onSelected: (v) {
                      switch (v) {
                        case 'run':
                          onRun();
                          break;
                        case 'arm':
                          onArm();
                          break;
                        case 'export':
                          onExport?.call();
                          break;
                        case 'copy':
                          onCopy?.call();
                          break;
                        case 'delete':
                          onDelete?.call();
                          break;
                      }
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(value: 'run', child: Text(AppStrings.t('auto.run'))),
                      PopupMenuItem(
                        value: 'arm',
                        child: Text(armed
                            ? AppStrings.t('auto.disarm')
                            : AppStrings.t('auto.arm')),
                      ),
                      if (onExport != null)
                        PopupMenuItem(
                            value: 'export', child: Text(AppStrings.t('auto.export'))),
                      if (onCopy != null)
                        PopupMenuItem(
                            value: 'copy', child: Text(AppStrings.t('auto.copyToLocal'))),
                      if (onDelete != null)
                        PopupMenuItem(
                          value: 'delete',
                          child: Text(AppStrings.t('auto.delete'),
                              style: TextStyle(color: AppColors.iconRed)),
                        ),
                    ],
                  ),
                ],
              ),
              if (workflow.isFromModule) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.inventory_2_outlined,
                        size: 12, color: AppColors.textInactive),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        workflow.source,
                        style: AppText.desc12.copyWith(color: AppColors.textInactive),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
