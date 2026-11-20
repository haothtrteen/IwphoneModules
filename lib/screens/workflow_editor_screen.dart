import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
import '../models/workflow.dart';
import '../services/module_catalog.dart';
import '../services/monitor_service.dart';
import '../theme/app_theme.dart';
import '../widgets/back_icon_button.dart';

/// 可视化工作流编辑器（借鉴 vFlow WorkflowEditorActivity + ActionEditorSheet）。
///
/// 核心思想：模块声明 ParamDef，编辑器据此**动态生成表单**，
/// 宿主不认识具体模块 —— 新增模块只改 ModuleCatalog 与 Kotlin executeStep。
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
  }

  Future<void> _save() async {
    final w = Workflow(
      id: _wf.id,
      name: _name.text.trim().isEmpty ? '未命名工作流' : _name.text.trim(),
      steps: _wf.steps,
      stopOnError: _wf.stopOnError,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
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
    _wf.steps.add(WorkflowStep(moduleId: picked.id, params: params));
    setState(() {});
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
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        leading: const BackIconButton(),
        title: Text(AppStrings.t('auto.editStep'), style: AppText.appTitle),
        actions: [
          IconButton(icon: const Icon(Icons.play_arrow), onPressed: _run),
          IconButton(icon: const Icon(Icons.save), onPressed: _save),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
          Text('${AppStrings.t('auto.steps')} (${_wf.steps.length})', style: AppText.sectionTitle),
          const SizedBox(height: 8),
          if (_wf.steps.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: Center(child: Text(AppStrings.t('auto.noSteps'), style: AppText.desc12)),
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
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.9,
      builder: (_, controller) => ListView.builder(
        controller: controller,
        padding: const EdgeInsets.all(16),
        itemCount: ModuleCatalog.categories.length,
        itemBuilder: (context, ci) {
          final cat = ModuleCatalog.categories[ci];
          final mods = ModuleCatalog.byCategory(cat);
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
