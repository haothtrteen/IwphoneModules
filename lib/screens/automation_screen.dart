import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
import '../models/workflow.dart';
import '../services/monitor_service.dart';
import '../services/trigger_catalog.dart';
import '../theme/app_theme.dart';
import '../widgets/back_icon_button.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/screen_app_bar.dart';
import 'workflows_screen.dart';

/// 自动化页（底栏 tab）。
///
/// 三层信息，从「我现在有什么」到「它是怎么被触发的」：
/// 1. 我的工作流入口 —— 搭流程、看数量、看武装了几个；
/// 2. 已武装的自动化 —— 正在等事件的那些，可就地解除；
/// 3. 模块提供的自动化 —— `.iwp` 包里带的 automation.json / automation.prop。
///
/// [embedded] = true 时不自带 Scaffold（底栏 tab 由 main.dart 统一包裹），
/// 与 [AppAuthScreen] 的约定一致。
class AutomationScreen extends StatefulWidget {
  const AutomationScreen({
    super.key,
    this.embedded = false,
    this.reloadToken = 0,
  });

  final bool embedded;

  /// 切回本 tab 时由外层递增，触发重新读取工作流 / 模块声明。
  final int reloadToken;

  @override
  State<AutomationScreen> createState() => _AutomationScreenState();
}

class _AutomationScreenState extends State<AutomationScreen> {
  List<Workflow> _local = const [];
  List<Workflow> _fromModules = const [];
  Map<String, String> _armed = const {};
  List<AutomationInfo> _specs = const [];
  String _moduleError = '';
  bool _loading = true;

  final TextEditingController _module = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant AutomationScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadToken != widget.reloadToken) _load();
  }

  @override
  void dispose() {
    _module.dispose();
    super.dispose();
  }

  Future<void> _load({bool forceScan = false}) async {
    final results = await Future.wait([
      MonitorService.instance.workflows(),
      MonitorService.instance.moduleWorkflows(force: forceScan),
      MonitorService.instance.armedWorkflows(),
      MonitorService.instance.automations(),
      MonitorService.instance.moduleAutomationError(),
    ]);
    if (!mounted) return;
    setState(() {
      _local = results[0] as List<Workflow>;
      _fromModules = results[1] as List<Workflow>;
      _armed = results[2] as Map<String, String>;
      _specs = results[3] as List<AutomationInfo>;
      _moduleError = results[4] as String;
      _loading = false;
    });
  }

  List<Workflow> get _all => [..._local, ..._fromModules];

  Future<void> _openWorkflows() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const WorkflowsScreen()),
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
      await _openWorkflows();
      return;
    }
    final ok = await MonitorService.instance.armWorkflow(w.id, w.trigger);
    if (!mounted) return;
    _snack(ok
        ? '${AppStrings.t('auto.armed')} · ${TriggerCatalog.label(w.trigger)}'
        : AppStrings.t('auto.armFailed'));
    await _load();
  }

  /// 旧式 automation.prop：按模块名从设备 cat 出来再注册。
  Future<void> _loadSpec(String module) async {
    if (module.trim().isEmpty) return;
    final ok = await MonitorService.instance.automationLoad(module.trim());
    if (!mounted) return;
    _snack(ok ? '${AppStrings.t('auto.load')}: OK' : '${AppStrings.t('auto.load')}: FAIL');
    await _load();
  }

  Future<void> _specAction(String op, AutomationInfo a) async {
    switch (op) {
      case 'arm':
        await MonitorService.instance.automationArm(a.id);
        break;
      case 'disarm':
        await MonitorService.instance.automationDisarm(a.id);
        break;
      case 'run':
        final confirmed = await showConfirmDialog(
          context,
          title: AppStrings.t('auto.run'),
          message: '${AppStrings.t('auto.run')} ${a.id}?',
        );
        if (confirmed != true) return;
        await MonitorService.instance.automationRun(a.id);
        break;
    }
    await _load();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final body = RefreshIndicator(
      color: AppColors.accent,
      backgroundColor: AppColors.surface,
      onRefresh: () => _load(forceScan: true),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ScreenAppBar(
              title: AppStrings.t('auto.title'),
              leading: widget.embedded ? null : const BackIconButton(),
              actions: [
                AppBarActionIcon(
                  icon: Icons.refresh,
                  onTap: () => _load(forceScan: true),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(AppStrings.t('auto.hint'), style: AppText.desc12),
            const SizedBox(height: 16),
            _WorkflowEntryCard(
              total: _local.length,
              armed: _armed.length,
              onTap: _openWorkflows,
            ),
            const SizedBox(height: 16),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 30),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              if (_armed.isNotEmpty) ...[
                Text(AppStrings.t('auto.armedSection'), style: AppText.sectionTitle),
                const SizedBox(height: 8),
                for (final entry in _armed.entries)
                  _ArmedRow(
                    workflow: _findWorkflow(entry.key),
                    id: entry.key,
                    trigger: entry.value,
                    onDisarm: () {
                      final w = _findWorkflow(entry.key);
                      if (w != null) {
                        _toggleArm(w);
                      } else {
                        MonitorService.instance
                            .disarmWorkflow(entry.key)
                            .then((_) => _load());
                      }
                    },
                  ),
                const SizedBox(height: 16),
              ],
              Text(AppStrings.t('auto.sectionModule'), style: AppText.sectionTitle),
              const SizedBox(height: 8),
              if (_fromModules.isEmpty)
                _EmptyHint(
                  text: _moduleError.isEmpty
                      ? AppStrings.t('auto.moduleEmpty')
                      : '${AppStrings.t('auto.moduleEmpty')}\n$_moduleError',
                )
              else
                for (final w in _fromModules)
                  _ModuleWorkflowRow(
                    workflow: w,
                    armed: _armed.containsKey(w.id),
                    onRun: () => _run(w),
                    onArm: () => _toggleArm(w),
                  ),
              const SizedBox(height: 20),
              Text(AppStrings.t('auto.propTitle'), style: AppText.sectionTitle),
              const SizedBox(height: 6),
              Text(AppStrings.t('auto.propHint'), style: AppText.desc12),
              const SizedBox(height: 10),
              for (final a in _specs)
                _SpecRow(
                  info: a,
                  onArm: () => _specAction('arm', a),
                  onDisarm: () => _specAction('disarm', a),
                  onRun: () => _specAction('run', a),
                ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _module,
                      style: AppText.body13,
                      decoration: InputDecoration(
                        hintText: AppStrings.t('auto.propPlaceholder'),
                        hintStyle: AppText.desc12,
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () => _loadSpec(_module.text),
                    child: Text(AppStrings.t('auto.load')),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _HelpCard(),
            ],
          ],
        ),
      ),
    );

    if (widget.embedded) return body;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(child: body),
    );
  }

  Workflow? _findWorkflow(String id) {
    for (final w in _all) {
      if (w.id == id) return w;
    }
    return null;
  }
}

/// 顶部入口卡：进去搭流程。
class _WorkflowEntryCard extends StatelessWidget {
  const _WorkflowEntryCard({
    required this.total,
    required this.armed,
    required this.onTap,
  });

  final int total;
  final int armed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.accentDim,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.account_tree_outlined,
                  size: 20, color: AppColors.accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(AppStrings.t('auto.workflows'), style: AppText.cardTitle),
                  const SizedBox(height: 3),
                  Text(
                    '${AppStrings.t('auto.workflowsHint')}',
                    style: AppText.desc12,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('$total', style: AppText.value14),
                Text(
                  armed > 0 ? '$armed ${AppStrings.t('auto.armed')}' : AppStrings.t('auto.steps'),
                  style: AppText.desc12.copyWith(
                    color: armed > 0 ? AppColors.accent : AppColors.textInactive,
                  ),
                ),
              ],
            ),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 18, color: AppColors.textInactive),
          ],
        ),
      ),
    );
  }
}

class _ArmedRow extends StatelessWidget {
  const _ArmedRow({
    required this.workflow,
    required this.id,
    required this.trigger,
    required this.onDisarm,
  });

  final Workflow? workflow;
  final String id;
  final String trigger;
  final VoidCallback onDisarm;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Icon(Icons.bolt, size: 16, color: AppColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(workflow?.name ?? id, style: AppText.rowLabel),
                Text(
                  '${TriggerCatalog.label(trigger)} · '
                  '${workflow?.steps.length ?? 0} ${AppStrings.t('auto.steps')}',
                  style: AppText.desc12,
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: onDisarm,
            child: Text(AppStrings.t('auto.disarm')),
          ),
        ],
      ),
    );
  }
}

class _ModuleWorkflowRow extends StatelessWidget {
  const _ModuleWorkflowRow({
    required this.workflow,
    required this.armed,
    required this.onRun,
    required this.onArm,
  });

  final Workflow workflow;
  final bool armed;
  final VoidCallback onRun;
  final VoidCallback onArm;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(workflow.name, style: AppText.cardTitle)),
              Icon(Icons.inventory_2_outlined,
                  size: 13, color: AppColors.textInactive),
              const SizedBox(width: 4),
              Text(workflow.module, style: AppText.desc12),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            '${TriggerCatalog.label(workflow.trigger)} · '
            '${workflow.steps.length} ${AppStrings.t('auto.steps')}',
            style: AppText.desc12,
          ),
          Row(
            children: [
              TextButton(onPressed: onRun, child: Text(AppStrings.t('auto.run'))),
              TextButton(
                onPressed: onArm,
                child: Text(armed
                    ? AppStrings.t('auto.disarm')
                    : AppStrings.t('auto.arm')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SpecRow extends StatelessWidget {
  const _SpecRow({
    required this.info,
    required this.onArm,
    required this.onDisarm,
    required this.onRun,
  });

  final AutomationInfo info;
  final VoidCallback onArm;
  final VoidCallback onDisarm;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(info.id, style: AppText.cardTitle)),
              Text(info.state,
                  style: AppText.badge.copyWith(color: AppColors.textInactive)),
            ],
          ),
          Text(
            info.triggerLabel.isEmpty ? info.trigger : info.triggerLabel,
            style: AppText.desc12,
          ),
          Text(info.action, style: AppText.body13, maxLines: 2),
          Row(
            children: [
              TextButton(onPressed: onArm, child: Text(AppStrings.t('auto.arm'))),
              TextButton(onPressed: onDisarm, child: Text(AppStrings.t('auto.disarm'))),
              TextButton(onPressed: onRun, child: Text(AppStrings.t('auto.run'))),
            ],
          ),
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
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.divider),
      ),
      child: Text(text, style: AppText.desc12),
    );
  }
}

/// 帮助卡：把「触发器到底是什么」讲清楚。
///
/// 之前界面只列 `monitor:framework` 这种串，用户根本不知道它意味着什么，
/// 也不知道「武装」之后靠什么启动 —— 这张卡就是补那一段。
class _HelpCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.help_outline, size: 16, color: AppColors.textSecondary),
              const SizedBox(width: 6),
              Text(AppStrings.t('auto.helpTitle'), style: AppText.rowLabel),
            ],
          ),
          const SizedBox(height: 8),
          Text(AppStrings.t('auto.helpBody'), style: AppText.desc12),
          const SizedBox(height: 10),
          for (final t in TriggerCatalog.automatable)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 4,
                    height: 4,
                    margin: const EdgeInsets.only(top: 6, right: 8),
                    decoration: BoxDecoration(
                      color: AppColors.accent,
                      shape: BoxShape.circle,
                    ),
                  ),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: AppText.desc12,
                        children: [
                          TextSpan(
                            text: '${t.label}：',
                            style: AppText.desc12.copyWith(color: AppColors.textPrimary),
                          ),
                          TextSpan(text: t.desc),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
