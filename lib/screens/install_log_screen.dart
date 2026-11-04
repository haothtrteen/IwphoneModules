import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
import '../services/autostart_service.dart';
import '../theme/app_theme.dart';
import '../widgets/back_icon_button.dart';

/// 一行日志的类型，决定前缀符号与颜色。
enum LogKind { info, ok, warn, fail }

/// 执行器往日志页追加一行。
typedef InstallLogEmitter = void Function(String message, LogKind kind);

/// 安装执行器：由调用方（安装页）提供，日志页只负责驱动与展示。
typedef InstallRunner = Future<({bool ok, String msg})> Function(
  InstallLogEmitter log,
);

/// 安装日志页（参照 Magisk 安装完成前的日志界面）。
///
/// 配置全部集中在上一页，这里只做一件事：**把执行过程摊开给人看**。
/// 完成后右下角出现「重启应用」—— 让 main() 重新探测框架/密钥/版本标记，
/// 比在各页面里手工同步状态干净得多。
class InstallLogScreen extends StatefulWidget {
  const InstallLogScreen({
    super.key,
    required this.runner,
    required this.onInstalled,
  });

  final InstallRunner runner;
  final VoidCallback onInstalled;

  @override
  State<InstallLogScreen> createState() => _InstallLogScreenState();
}

class _InstallLogScreenState extends State<InstallLogScreen> {
  final List<({String text, LogKind kind})> _lines = [];
  final ScrollController _scroll = ScrollController();

  bool _running = true;
  bool? _success;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _emit(String message, LogKind kind) {
    if (!mounted) return;
    setState(() => _lines.add((text: message, kind: kind)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _start() async {
    _emit(AppStrings.t('log.begin'), LogKind.info);
    final result = await widget.runner(_emit);
    if (!mounted) return;
    setState(() {
      _running = false;
      _success = result.ok;
    });
    if (result.ok) {
      _emit(AppStrings.t('log.finished'), LogKind.ok);
      widget.onInstalled();
    } else {
      _emit('${AppStrings.t('log.failed')}${result.msg}', LogKind.fail);
    }
  }

  @override
  Widget build(BuildContext context) {
    final done = !_running;
    final ok = _success == true;

    return Scaffold(
      backgroundColor: AppColors.bg,
      floatingActionButton: done
          ? FloatingActionButton.extended(
              onPressed: () async {
                if (ok) {
                  await AutostartService.instance.restartApp();
                } else if (mounted) {
                  Navigator.of(context).pop();
                }
              },
              backgroundColor: ok ? AppColors.accent : AppColors.surface,
              foregroundColor: ok ? Colors.white : AppColors.textPrimary,
              icon: Icon(ok ? Icons.restart_alt_rounded : Icons.arrow_back_rounded),
              label: Text(
                ok
                    ? AppStrings.t('log.restartApp')
                    : AppStrings.t('log.backToFix'),
              ),
            )
          : null,
      // 执行过程中不允许返回：装到一半退出，用户既看不到结果也拿不到重启入口
      body: PopScope(
        canPop: !_running,
        child: SafeArea(
          child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 16, 8),
              child: Row(
                children: [
                  const BackIconButton(),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      AppStrings.t('log.title'),
                      style: AppText.appTitle,
                    ),
                  ),
                  _StatusBadge(running: _running, ok: ok),
                ],
              ),
            ),
            Expanded(
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: ListView.builder(
                  controller: _scroll,
                  itemCount: _lines.length + (_running ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i == _lines.length) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: AppColors.textInactive,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              AppStrings.t('log.running'),
                              style: AppText.desc12,
                            ),
                          ],
                        ),
                      );
                    }
                    final line = _lines[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 14,
                            child: Text(
                              _symbol(line.kind),
                              style: AppText.monoValue14.copyWith(
                                color: _color(line.kind),
                                fontSize: 13,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              line.text,
                              style: AppText.desc12.copyWith(
                                color: line.kind == LogKind.fail
                                    ? AppColors.iconRed
                                    : AppColors.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }

  String _symbol(LogKind kind) => switch (kind) {
        LogKind.info => '›',
        LogKind.ok => '✓',
        LogKind.warn => '!',
        LogKind.fail => '✕',
      };

  Color _color(LogKind kind) => switch (kind) {
        LogKind.info => AppColors.textInactive,
        LogKind.ok => AppColors.iconGreen,
        LogKind.warn => AppColors.iconOrange,
        LogKind.fail => AppColors.iconRed,
      };
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.running, required this.ok});

  final bool running;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final text = running
        ? AppStrings.t('log.statusRunning')
        : (ok
            ? AppStrings.t('log.statusOk')
            : AppStrings.t('log.statusFail'));
    final color = running
        ? AppColors.textInactive
        : (ok ? AppColors.iconGreen : AppColors.iconRed);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: AppText.desc12.copyWith(color: color)),
    );
  }
}
