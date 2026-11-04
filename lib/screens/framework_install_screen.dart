import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
import '../services/autostart_service.dart';
import '../theme/app_theme.dart';
import '../widgets/back_icon_button.dart';

/// 框架安装页（唯一的"安装"入口）。
///
/// 参照 KernelSU 的安装页：把安装拆成看得见的步骤，每一步都有明确状态，
/// 底部一个大按钮推进。原来的三类引导页（欢迎 / 风险 / 激活）合并到这里 ——
/// 引导页每多一页，就多一处状态要与真实状态同步，反而容易出错。
///
/// 本项目的"安装"只有两步：先配对无线调试（拿到 shell），再把内置框架包解压。
class FrameworkInstallScreen extends StatefulWidget {
  const FrameworkInstallScreen({super.key, required this.onInstalled});

  /// 部署成功后回调（上层据此离开安装页并放行主界面）。
  final VoidCallback onInstalled;

  @override
  State<FrameworkInstallScreen> createState() => _FrameworkInstallScreenState();
}

class _FrameworkInstallScreenState extends State<FrameworkInstallScreen>
    with WidgetsBindingObserver {
  AutostartStatus? _status;
  bool _busy = false;
  String _busyMsg = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从「无线调试」系统页回来时，配对状态可能已经变了
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final st = await AutostartService.instance.status();
    if (!mounted) return;
    setState(() => _status = st);
  }

  void _toast(String text, {bool ok = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      backgroundColor: ok ? null : AppColors.iconRed,
    ));
  }

  /// 配对：与设置页同一套流程（配对码在通知栏输入）。
  Future<void> _pair() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyMsg = AppStrings.t('install.stepPairing');
    });
    try {
      final st = _status;
      if (st != null && !st.notifyGranted) {
        await AutostartService.instance.requestNotification();
        if (!mounted) return;
        final again = await AutostartService.instance.status();
        if (!mounted) return;
        if (!again.notifyGranted) {
          _toast(AppStrings.t('onboarding.notifyNeeded'), ok: false);
          return;
        }
      }

      var flow = await AutostartService.instance.startPairingFlow();
      if (!mounted) return;
      if (flow.needPermission) {
        await AutostartService.instance.requestNotification();
        flow = await AutostartService.instance.startPairingFlow();
        if (!mounted) return;
      }
      if (!flow.ok) {
        _toast(flow.msg, ok: false);
        return;
      }

      final opened = await AutostartService.instance.openWirelessDebug();
      if (!mounted) return;
      _toast(opened
          ? AppStrings.t('onboarding.pairSent')
          : AppStrings.t('onboarding.pairSentManual'));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyMsg = '';
        });
      }
    }
  }

  Future<void> _deploy() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyMsg = AppStrings.t('missing.deploying');
    });
    final r = await AutostartService.instance.deployFramework();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _busyMsg = '';
    });

    if (r.ok) {
      _toast(AppStrings.t('onboarding.deployOk'));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      widget.onInstalled();
      if (mounted) Navigator.of(context).maybePop();
    } else {
      _toast('${AppStrings.t('missing.deployFail')}${r.msg}', ok: false);
      await _refresh();
    }
  }

  bool get _paired => _status?.provisioned ?? false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 16, 8),
              child: Row(
                children: const [
                  BackIconButton(),
                  SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '',
                      style: TextStyle(fontSize: 0),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                children: [
                  Text(
                    AppStrings.t('missing.installTitle'),
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    AppStrings.t('missing.installIntro'),
                    style: AppText.desc12,
                  ),
                  const SizedBox(height: 20),
                  _StepCard(
                    index: 1,
                    title: AppStrings.t('missing.stepPairTitle'),
                    subtitle: AppStrings.t('missing.stepPairDesc'),
                    done: _paired,
                    onTap: _busy ? null : _pair,
                  ),
                  const SizedBox(height: 8),
                  _StepCard(
                    index: 2,
                    title: AppStrings.t('missing.stepDeployTitle'),
                    subtitle: AppStrings.t('missing.stepDeployDesc'),
                    done: false,
                    enabled: _paired && !_busy,
                    onTap: _paired && !_busy ? _deploy : null,
                  ),
                  if (_status != null && !_status!.notifyGranted) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.notifications_off_outlined,
                              size: 20, color: AppColors.iconOrange),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              AppStrings.t('missing.notifyNeeded'),
                              style: AppText.desc12,
                            ),
                          ),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => AutostartService.instance
                                    .requestNotification(),
                            child: Text(
                              AppStrings.t('missing.grant'),
                              style: AppText.desc12
                                  .copyWith(color: AppColors.accent),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  onPressed: _busy
                      ? null
                      : (_paired ? _deploy : _pair),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    disabledBackgroundColor:
                        AppColors.accent.withValues(alpha: 0.35),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    _busy
                        ? _busyMsg
                        : (_paired
                            ? AppStrings.t('missing.startInstall')
                            : AppStrings.t('missing.goPair')),
                    style: const TextStyle(fontSize: 15),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 安装步骤卡片：序号 + 标题 + 说明 + 状态。
class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.index,
    required this.title,
    required this.subtitle,
    required this.done,
    this.enabled = true,
    this.onTap,
  });

  final int index;
  final String title;
  final String subtitle;
  final bool done;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final active = enabled && onTap != null;
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: done
                      ? AppColors.accent
                      : AppColors.bg,
                  shape: BoxShape.circle,
                ),
                child: done
                    ? const Icon(Icons.check_rounded,
                        size: 16, color: Colors.white)
                    : Text(
                        '$index',
                        style: AppText.desc12.copyWith(
                          color: active
                              ? AppColors.textPrimary
                              : AppColors.textInactive,
                        ),
                      ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppText.rowLabel.copyWith(
                        fontSize: 16,
                        color: active || done
                            ? AppColors.textPrimary
                            : AppColors.textInactive,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(subtitle, style: AppText.desc12),
                  ],
                ),
              ),
              if (active)
                Icon(Icons.chevron_right_rounded,
                    size: 20, color: AppColors.textInactive),
            ],
          ),
        ),
      ),
    );
  }
}
