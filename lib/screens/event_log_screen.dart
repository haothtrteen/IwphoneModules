import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
import '../models/monitor_event.dart';
import '../services/monitor_service.dart';
import '../theme/app_theme.dart';
import '../widgets/back_icon_button.dart';

/// 即时事件流页（P0 验证用）。
///
/// 按项目约定：Navigator 打开的独立页必须自带 Scaffold + BackIconButton。
class EventLogScreen extends StatefulWidget {
  const EventLogScreen({super.key});

  @override
  State<EventLogScreen> createState() => _EventLogScreenState();
}

class _EventLogScreenState extends State<EventLogScreen> {
  final List<PlatformEvent> _events = [];
  Map<String, String> _states = const {};
  List<CapabilityInfo> _capabilities = const [];

  @override
  void initState() {
    super.initState();
    MonitorService.instance.startListening((e) {
      if (!mounted) return;
      setState(() => _events.insert(0, e));
    });
    _loadStates();
  }

  Future<void> _loadStates() async {
    final s = await MonitorService.instance.allStates();
    final caps = await MonitorService.instance.capabilities();
    if (!mounted) return;
    setState(() {
      _states = s;
      _capabilities = caps;
    });
  }

  @override
  void dispose() {
    MonitorService.instance.stopListening();
    super.dispose();
  }

  Color _severityColor(String severity) {
    switch (severity) {
      case 'error':
        return AppColors.iconRed;
      case 'warn':
        return AppColors.iconOrange;
      default:
        return AppColors.accent;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        leading: const BackIconButton(),
        title: Text(AppStrings.t('logs.events'), style: AppText.appTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadStates,
          ),
        ],
      ),
      body: RefreshIndicator(
        color: AppColors.accent,
        backgroundColor: AppColors.surface,
        onRefresh: _loadStates,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(AppStrings.t('logs.eventsHint'), style: AppText.desc12),
            const SizedBox(height: 12),
            if (_capabilities.isNotEmpty) ...[
              Text('能力状态', style: AppText.cardTitle),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _capabilities.map((c) {
                  final ok = c.availability == 'AVAILABLE';
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: ok ? AppColors.accent : AppColors.divider),
                    ),
                    child: Text(
                      '${c.name}: ${c.availability}',
                      style: AppText.body13.copyWith(
                        color: ok ? AppColors.accent : AppColors.textSecondary,
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
            ],
            if (_states.isNotEmpty) ...[
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _states.entries.map((e) {
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.divider),
                    ),
                    child: Text(
                      '${e.key}: ${e.value}',
                      style: AppText.body13.copyWith(color: AppColors.accent),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),
            ],
            if (_events.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text(AppStrings.t('logs.noEvents'), style: AppText.desc12),
                ),
              )
            else
              for (final e in _events)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.divider),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 4,
                        height: 36,
                        decoration: BoxDecoration(
                          color: _severityColor(e.severity),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(e.id, style: AppText.cardTitle),
                            if (e.to.isNotEmpty)
                              Text('${e.from} → ${e.to}', style: AppText.desc12),
                            Text(e.reason, style: AppText.body13),
                            Text(
                              '${e.time.hour.toString().padLeft(2, '0')}:'
                              '${e.time.minute.toString().padLeft(2, '0')}:'
                              '${e.time.second.toString().padLeft(2, '0')} · ${e.kind}',
                              style: AppText.desc12,
                            ),
                          ],
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
