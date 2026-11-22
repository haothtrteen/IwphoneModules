import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
import '../models/workflow.dart';
import '../services/app_catalog.dart';
import '../services/app_prefs.dart';
import '../services/module_catalog.dart';
import '../services/monitor_service.dart';
import '../services/trigger_catalog.dart';
import '../theme/app_theme.dart';
import '../widgets/back_icon_button.dart';

/// 可视化工作流编辑器（借鉴 vFlow WorkflowEditorActivity + ActionEditorSheet）。
///
/// 核心思想：模块声明 ParamDef，编辑器据此**动态生成表单**，
/// 宿主不认识具体模块 —— 新增模块只改 ModuleCatalog 与 Kotlin executeStep。
///
/// 结构：**触发条件（头）+ 步骤（身体）**
/// 触发器不再是「第一步」，而是整个流程的前置条件 —— 这样「什么时候跑」
/// 与「跑什么」分开，用户不会再把触发器当成一个动作去理解。
class WorkflowEditorScreen extends StatefulWidget {
  const WorkflowEditorScreen({super.key, required this.workflow});

  final Workflow workflow;

  @override
  State<WorkflowEditorScreen> createState() => _WorkflowEditorScreenState();
}

class _WorkflowEditorScreenState extends State<WorkflowEditorScreen> {
  late Workflow _wf;
  late TextEditingController _name;

  @override
  void initState() {
    super.initState();
    _wf = widget.workflow;
    _name = TextEditingController(text: _wf.name);
    // 应用级触发器的 key 里是包名，显示要靠应用清单；拉完再刷一次界面，
    // 否则会先显示成 com.tencent.mm 再跳成「微信」。
    AppCatalog.instance.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_wf.isFromModule) return;
    final w = Workflow(
      id: _wf.id,
      name: _name.text.trim().isEmpty ? AppStrings.t('auto.untitled') : _name.text.trim(),
      steps: _wf.steps,
      stopOnError: _wf.stopOnError,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      trigger: _wf.trigger,
    );
    final ok = await MonitorService.instance.saveWorkflow(w);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '${AppStrings.t('auto.save')}: OK' : '${AppStrings.t('auto.save')}: FAIL')),
    );
    if (ok) setState(() => _wf = w);
  }

  Future<void> _run() async {
    final r = await MonitorService.instance.runWorkflow(_wf.id);
    if (!mounted) return;
    showDialog<void>(
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

  /// 选触发器：底部弹层 + 中文名 + 一句说明。
  ///
  /// 不用下拉框：说明文字放不进 DropdownMenuItem，而「什么时候触发」
  /// 恰恰是最需要解释的一格。
  Future<void> _pickTrigger() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      builder: (_) => _TriggerPicker(current: _wf.trigger),
    );
    if (picked == null || !mounted) return;
    setState(() => _wf = Workflow(
          id: _wf.id,
          name: _wf.name,
          steps: _wf.steps,
          stopOnError: _wf.stopOnError,
          updatedAt: _wf.updatedAt,
          trigger: picked,
        ));
  }

  Future<void> _addStep() async {
    final picked = await showModalBottomSheet<ModuleDef>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      builder: (_) => const _ModulePicker(),
    );
    if (picked == null || !mounted) return;
    if (picked.dangerous) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text(picked.name, style: AppText.cardTitle),
          content: Text(AppStrings.t('auto.dangerConfirm'), style: AppText.body13),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('OK')),
          ],
        ),
      );
      if (ok != true) return;
    }
    final params = <String, dynamic>{};
    for (final p in picked.params) {
      params[p.id] = p.defaultValue;
    }
    setState(() => _wf.steps.add(WorkflowStep(moduleId: picked.id, params: params)));
  }

  Future<void> _editStep(int index) async {
    final step = _wf.steps[index];
    final def = ModuleCatalog.find(step.moduleId);
    if (def == null || def.params.isEmpty) return;
    final changed = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      builder: (_) => _ParamForm(def: def, initial: step.params),
    );
    if (changed == null || !mounted) return;
    step.params.clear();
    step.params.addAll(changed);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final readOnly = _wf.isFromModule;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        leading: const BackIconButton(),
        title: Text(_wf.name.isEmpty ? AppStrings.t('auto.editStep') : _wf.name,
            style: AppText.appTitle),
        actions: [
          IconButton(icon: const Icon(Icons.play_arrow), onPressed: _run),
          if (!readOnly)
            IconButton(icon: const Icon(Icons.save), onPressed: _save),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (readOnly) _ReadOnlyBanner(source: _wf.source),
          if (!readOnly) ...[
            TextField(
              controller: _name,
              style: AppText.cardTitle,
              decoration: InputDecoration(
                labelText: AppStrings.t('auto.name'),
                labelStyle: AppText.desc12,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 16),
          ],

          // ---------- 触发条件 ----------
          _TriggerCard(
            trigger: _wf.trigger,
            onTap: readOnly ? null : _pickTrigger,
          ),
          const SizedBox(height: 16),

          // ---------- 步骤 ----------
          Text('${AppStrings.t('auto.steps')} (${_wf.steps.length})',
              style: AppText.sectionTitle),
          const SizedBox(height: 8),
          if (_wf.steps.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: Center(
                  child: Text(AppStrings.t('auto.noSteps'), style: AppText.desc12)),
            )
          else
            for (int i = 0; i < _wf.steps.length; i++)
              _StepCard(
                index: i,
                step: _wf.steps[i],
                def: ModuleCatalog.find(_wf.steps[i].moduleId),
                onEdit: () => _editStep(i),
                onToggle: () => setState(() => _wf.steps[i].disabled = !_wf.steps[i].disabled),
                onDelete: () => setState(() => _wf.steps.removeAt(i)),
                onMoveUp: i > 0
                    ? () => setState(() {
                          final s = _wf.steps.removeAt(i);
                          _wf.steps.insert(i - 1, s);
                        })
                    : null,
                onMoveDown: i < _wf.steps.length - 1
                    ? () => setState(() {
                          final s = _wf.steps.removeAt(i);
                          _wf.steps.insert(i + 1, s);
                        })
                    : null,
              ),
          const SizedBox(height: 12),
          if (!readOnly)
            OutlinedButton.icon(
              onPressed: _addStep,
              icon: const Icon(Icons.add),
              label: Text(AppStrings.t('auto.addStep')),
            ),
        ],
      ),
    );
  }
}

/// 触发条件卡片：显示「什么时候跑」，点开可换。
class _TriggerCard extends StatelessWidget {
  const _TriggerCard({required this.trigger, required this.onTap});

  final String trigger;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final needsA11y = TriggerCatalog.needsAccessibility(trigger);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.accent.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bolt_outlined, size: 18, color: AppColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(AppStrings.t('auto.trigger'), style: AppText.rowLabel),
                ),
                Text(TriggerCatalog.label(trigger),
                    style: AppText.value14.copyWith(color: AppColors.accent)),
                if (onTap != null) ...[
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right, size: 18, color: AppColors.textInactive),
                ],
              ],
            ),
            const SizedBox(height: 6),
            Text(TriggerCatalog.desc(trigger), style: AppText.desc12),
            if (needsA11y) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.info_outline, size: 14, color: AppColors.iconOrange),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      AppStrings.t('auto.needsA11y'),
                      style: AppText.desc12.copyWith(color: AppColors.iconOrange),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner({required this.source});
  final String source;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.iconBlue.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.lock_outline, size: 16, color: AppColors.iconBlue),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${AppStrings.t('auto.readonly')}${source.isEmpty ? '' : ' · $source'}',
              style: AppText.desc12.copyWith(color: AppColors.iconBlue),
            ),
          ),
        ],
      ),
    );
  }
}

/// 触发器选择弹层。
class _TriggerPicker extends StatelessWidget {
  const _TriggerPicker({required this.current});
  final String current;

  /// 选应用后拼成应用级触发器 key 返回。
  Future<void> _pickApp(BuildContext context, {required bool foreground}) async {
    final pkg = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      builder: (_) => _AppPicker(foreground: foreground),
    );
    if (pkg == null || !context.mounted) return;
    Navigator.pop(
      context,
      foreground ? TriggerCatalog.appForeground(pkg) : TriggerCatalog.appNotification(pkg),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.8),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Text(AppStrings.t('auto.triggerPick'), style: AppText.sectionTitle),
            const SizedBox(height: 4),
            Text(AppStrings.t('auto.triggerPickHint'), style: AppText.desc12),
            const SizedBox(height: 8),
            for (final t in TriggerCatalog.all)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  t.key == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: t.key == current ? AppColors.accent : AppColors.textInactive,
                ),
                title: Text(t.label, style: AppText.rowLabel),
                subtitle: Text(t.desc, style: AppText.desc12),
                onTap: () => Navigator.pop(context, t.key),
              ),
            Divider(height: 24, color: AppColors.divider),
            Text(AppStrings.t('auto.triggerAppSection'), style: AppText.sectionTitle),
            const SizedBox(height: 4),
            Text(AppStrings.t('auto.triggerAppHint'), style: AppText.desc12),
            const SizedBox(height: 4),
            _AppTriggerTile(
              icon: Icons.open_in_new,
              label: AppStrings.t('auto.triggerAppForeground'),
              current: current,
              isCurrent: TriggerCatalog.isAppForeground(current),
              selectedLabel: TriggerCatalog.isAppForeground(current)
                  ? AppCatalog.instance.labelOf(TriggerCatalog.appOf(current))
                  : null,
              onTap: () => _pickApp(context, foreground: true),
            ),
            _AppTriggerTile(
              icon: Icons.notifications_none,
              label: AppStrings.t('auto.triggerAppNotification'),
              current: current,
              isCurrent: TriggerCatalog.isAppNotification(current),
              selectedLabel: TriggerCatalog.isAppNotification(current)
                  ? AppCatalog.instance.labelOf(TriggerCatalog.appOf(current))
                  : null,
              onTap: () => _pickApp(context, foreground: false),
            ),
          ],
        ),
      ),
    );
  }
}

/// 应用级触发器的两种入口（点开再去选具体应用）。
class _AppTriggerTile extends StatelessWidget {
  const _AppTriggerTile({
    required this.icon,
    required this.label,
    required this.current,
    required this.isCurrent,
    required this.selectedLabel,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String current;
  final bool isCurrent;
  final String? selectedLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        isCurrent ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        size: 18,
        color: isCurrent ? AppColors.accent : AppColors.textInactive,
      ),
      title: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.textSecondary),
          const SizedBox(width: 6),
          Expanded(child: Text(label, style: AppText.rowLabel)),
        ],
      ),
      subtitle: Text(
        isCurrent && selectedLabel != null
            ? selectedLabel!
            : AppStrings.t('auto.triggerAppPick'),
        style: AppText.desc12.copyWith(
          color: isCurrent ? AppColors.accent : AppColors.textInactive,
        ),
      ),
      trailing: Icon(Icons.chevron_right, size: 18, color: AppColors.textInactive),
      onTap: onTap,
    );
  }
}

/// 选应用弹层：搜索 + 列表。
///
/// 应用多的时候（这份设备上 60+）没搜索基本没法用，所以第一行就是输入框。
class _AppPicker extends StatefulWidget {
  const _AppPicker({required this.foreground});
  final bool foreground;

  @override
  State<_AppPicker> createState() => _AppPickerState();
}

class _AppPickerState extends State<_AppPicker> {
  List<AppEntry> _items = const [];
  String _query = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await AppCatalog.instance.load(force: !AppCatalog.instance.loaded);
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? _items
        : _items
            .where((a) =>
                a.label.toLowerCase().contains(q) || a.pkg.toLowerCase().contains(q))
            .toList();

    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.foreground
                        ? AppStrings.t('auto.triggerAppForeground')
                        : AppStrings.t('auto.triggerAppNotification'),
                    style: AppText.sectionTitle,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    style: AppText.body13,
                    decoration: InputDecoration(
                      hintText: AppStrings.t('auto.appSearch'),
                      hintStyle: AppText.desc12,
                      prefixIcon: const Icon(Icons.search, size: 18),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ],
              ),
            ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: [
                    // 不限应用：适合「任何应用来通知就记录一下」这类场景
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.all_inclusive,
                          size: 18, color: AppColors.textSecondary),
                      title: Text(AppStrings.t('auto.appAny'), style: AppText.rowLabel),
                      onTap: () => Navigator.pop(context, ''),
                    ),
                    for (final a in filtered)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(a.label, style: AppText.rowLabel),
                        subtitle: Text(a.pkg, style: AppText.desc12),
                        onTap: () => Navigator.pop(context, a.pkg),
                      ),
                    if (filtered.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(AppStrings.t('auto.appEmpty'),
                              style: AppText.desc12),
                        ),
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

class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.index, required this.step, required this.def,
    required this.onEdit, required this.onToggle, required this.onDelete,
    required this.onMoveUp, required this.onMoveDown,
  });

  final int index;
  final WorkflowStep step;
  final ModuleDef? def;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  @override
  Widget build(BuildContext context) {
    final summary = step.params.entries
        .where((e) => e.value != null && '${e.value}'.isNotEmpty)
        .map((e) => '${e.key}=${e.value}')
        .join(' · ');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.divider),
      ),
      child: Row(
        children: [
          Text(def?.icon ?? '?', style: const TextStyle(fontSize: 22)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${index + 1}. ${def?.name ?? step.moduleId}', style: AppText.cardTitle),
                Text(summary.isEmpty ? step.moduleId : summary, style: AppText.desc12,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          Column(
            children: [
              IconButton(icon: const Icon(Icons.arrow_upward, size: 18),
                  onPressed: onMoveUp, padding: EdgeInsets.zero, constraints: const BoxConstraints()),
              IconButton(icon: const Icon(Icons.arrow_downward, size: 18),
                  onPressed: onMoveDown, padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            ],
          ),
          IconButton(icon: Icon(step.disabled ? Icons.visibility_off : Icons.visibility, size: 18),
              onPressed: onToggle),
          IconButton(icon: const Icon(Icons.edit, size: 18), onPressed: onEdit),
          IconButton(icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: onDelete, color: AppColors.iconRed),
        ],
      ),
    );
  }
}

class _ModulePicker extends StatelessWidget {
  const _ModulePicker();

  @override
  Widget build(BuildContext context) {
    // 开发者模式只在这里控制"显不显示"；原生侧 executeStep 还会再校验一次，
    // 所以模块 automation.json 里写死 dev.* 也绕不过开关。
    final dev = AppPrefs.instance.developerMode;
    final cats = ModuleCatalog.categoriesFor(includeDeveloper: dev);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.9,
      builder: (_, controller) => ListView.builder(
        controller: controller,
        padding: const EdgeInsets.all(16),
        itemCount: cats.length,
        itemBuilder: (context, ci) {
          final cat = cats[ci];
          final mods = ModuleCatalog.byCategory(cat, includeDeveloper: dev);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(cat, style: AppText.sectionTitle),
              ...mods.map((m) => ListTile(
                leading: Text(m.icon, style: const TextStyle(fontSize: 20)),
                title: Text(m.name, style: AppText.body13),
                subtitle: Text(m.params.isEmpty ? m.id : '${m.params.length} 个参数', style: AppText.desc12),
                onTap: () => Navigator.pop(context, m),
              )),
              const SizedBox(height: 8),
            ],
          );
        },
      ),
    );
  }
}

class _ParamForm extends StatefulWidget {
  const _ParamForm({required this.def, required this.initial});
  final ModuleDef def;
  final Map<String, dynamic> initial;

  @override
  State<_ParamForm> createState() => _ParamFormState();
}

class _ParamFormState extends State<_ParamForm> {
  late Map<String, dynamic> _values;

  @override
  void initState() {
    super.initState();
    _values = Map<String, dynamic>.from(widget.initial);
    for (final p in widget.def.params) {
      _values.putIfAbsent(p.id, () => p.defaultValue);
    }
  }

  Widget _field(ParamDef p) {
    final key = p.id;
    switch (p.type) {
      case ParamType.enumValue:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(p.label, style: AppText.rowLabel),
            Wrap(
              spacing: 8,
              children: p.options.map((o) {
                final selected = _values[key] == o;
                return ChoiceChip(
                  label: Text(o, style: AppText.body13),
                  selected: selected,
                  onSelected: (_) => setState(() => _values[key] = o),
                );
              }).toList(),
            ),
          ],
        );
      case ParamType.boolean:
        return SwitchListTile(
          title: Text(p.label, style: AppText.rowLabel),
          value: _values[key] == true,
          onChanged: (v) => setState(() => _values[key] = v),
        );
      case ParamType.number:
        return TextFormField(
          initialValue: (_values[key] ?? p.defaultValue ?? 0).toString(),
          style: AppText.body13,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: p.label, hintText: p.hint,
              labelStyle: AppText.desc12, border: const OutlineInputBorder(), isDense: true),
          onChanged: (v) => _values[key] = int.tryParse(v) ?? 0,
        );
      case ParamType.text:
        return TextFormField(
          initialValue: (_values[key] ?? p.defaultValue ?? '').toString(),
          style: AppText.body13,
          decoration: InputDecoration(labelText: p.label, hintText: p.hint,
              labelStyle: AppText.desc12, border: const OutlineInputBorder(), isDense: true),
          onChanged: (v) => _values[key] = v,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: 16, right: 16, top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.def.name, style: AppText.sectionTitle),
            const SizedBox(height: 12),
            for (final p in widget.def.params) ...[
              _field(p),
              const SizedBox(height: 12),
            ],
            ElevatedButton(
              onPressed: () => Navigator.pop(context, _values),
              child: Text(AppStrings.t('auto.save')),
            ),
          ],
        ),
      ),
    );
  }
}
