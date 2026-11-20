import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
import '../models/workflow.dart';
import '../services/monitor_service.dart';
import '../theme/app_theme.dart';
import '../widgets/back_icon_button.dart';
import 'workflow_editor_screen.dart';

/// 可视化工作流列表（借鉴 vFlow 的工作流管理）。
class WorkflowsScreen extends StatefulWidget {
  const WorkflowsScreen({super.key});

  @override
  State<WorkflowsScreen> createState() => _WorkflowsScreenState();
}

class _WorkflowsScreenState extends State<WorkflowsScreen> {
  List<Workflow> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final items = await MonitorService.instance.workflows();
    if (!mounted) return;
    setState(() { _items = items; _loading = false; });
  }

  Future<void> _new() async {
    final w = Workflow(
      id: 'wf_${DateTime.now().millisecondsSinceEpoch}',
      name: AppStrings.t('auto.new'),
    );
    await MonitorService.instance.saveWorkflow(w);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => WorkflowEditorScreen(workflow: w)),
    );
    await _load();
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
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _new,
        backgroundColor: AppColors.accent,
        child: const Icon(Icons.add),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(AppStrings.t('auto.workflowsHint'), style: AppText.desc12),
          const SizedBox(height: 16),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 50),
              child: Center(child: Text(AppStrings.t('auto.noSteps'), style: AppText.desc12)),
            )
          else
            for (final w in _items)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.divider),
                ),
                child: ListTile(
                  title: Text(w.name, style: AppText.cardTitle),
                  subtitle: Text('${w.steps.length} ${AppStrings.t('auto.steps')}', style: AppText.desc12),
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => WorkflowEditorScreen(workflow: w)),
                    );
                    await _load();
                  },
                  trailing: IconButton(
                    icon: Icon(Icons.delete_outline, color: AppColors.iconRed),
                    onPressed: () async {
                      await MonitorService.instance.deleteWorkflow(w.id);
                      await _load();
                    },
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
