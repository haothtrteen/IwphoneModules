import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
import '../services/monitor_service.dart';
import '../theme/app_theme.dart';
import '../widgets/back_icon_button.dart';
import '../widgets/confirm_dialog.dart';
import 'workflows_screen.dart';

/// 自动化脚本管理页（P3）。
class AutomationScreen extends StatefulWidget {
  const AutomationScreen({super.key});

  @override
  State<AutomationScreen> createState() => _AutomationScreenState();
}

class _AutomationScreenState extends State<AutomationScreen> {
  List<AutomationInfo> _items = const [];
  final TextEditingController _module = TextEditingController();
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final items = await MonitorService.instance.automations();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  Future<void> _action(String op, String id) async {
    final ok = switch (op) {
      'arm' => await MonitorService.instance.automationArm(id),
      'run' => await MonitorService.instance.automationRun(id),
      'load' => await MonitorService.instance.automationLoad(id),
      _ => false,
    };
    if (op == 'disarm') {
      await MonitorService.instance.automationDisarm(id);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$op ${id.isEmpty ? '' : id}: ${ok || op == 'disarm' ? 'OK' : 'FAIL'}')),
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
        title: Text(AppStrings.t('auto.title'), style: AppText.appTitle),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(AppStrings.t('auto.hint'), style: AppText.desc12),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const WorkflowsScreen()),
            ),
            icon: const Icon(Icons.account_tree_outlined),
            label: Text(AppStrings.t('auto.workflows')),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _module,
                  style: AppText.body13,
                  decoration: InputDecoration(
                    hintText: 'module name',
                    hintStyle: AppText.desc12,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () => _action('load', _module.text.trim()),
                child: Text(AppStrings.t('auto.load')),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(child: Text(AppStrings.t('auto.empty'), style: AppText.desc12)),
            )
          else
            for (final a in _items)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.divider),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a.id, style: AppText.cardTitle),
                    Text('${a.state} · ${a.trigger}', style: AppText.desc12),
                    Text(a.action, style: AppText.body13),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () => _action('arm', a.id),
                          child: Text(AppStrings.t('auto.arm')),
                        ),
                        TextButton(
                          onPressed: () => _action('disarm', a.id),
                          child: Text(AppStrings.t('auto.disarm')),
                        ),
                        TextButton(
                          onPressed: () async {
                            final confirmed = await showConfirmDialog(
                              context,
                              title: AppStrings.t('auto.run'),
                              message: '${AppStrings.t('auto.run')} ${a.id}?',
                            );
                            if (confirmed == true && mounted) {
                              await _action('run', a.id);
                            }
                          },
                          child: Text(AppStrings.t('auto.run')),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
