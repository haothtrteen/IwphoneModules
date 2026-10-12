import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
import '../services/app_prefs.dart';
import '../services/autostart_service.dart';
import '../services/storage_permission_service.dart';
import '../services/webui_token.dart';
import '../theme/app_theme.dart';
import '../widgets/app_switch.dart';
import '../widgets/webui_token_dialog.dart';
import 'autostart_screen.dart';

/// 首次启动引导 —— 三页：这是什么 → 风险告知 → **首次激活**。
///
/// 第三页不是「讲一遍步骤」，而是一张**活清单**：逐项显示当前状态并直接就地完成
/// （申请权限 / 发起配对 / 部署框架 / 设置访问密钥）。
/// 之前只把步骤写出来、点一下就直接进主界面，等于把用户丢进一个还不能用的 App。
///
/// 清单不强制做完 —— 但每项都标出状态，用户自己决定现在做还是稍后在「设置」里做。
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  static const _pageCount = 3;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_page >= _pageCount - 1) {
      _finish();
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _finish() => AppPrefs.instance.setOnboardingDone();

  @override
  Widget build(BuildContext context) {
    final last = _page == _pageCount - 1;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            // 顶部：跳过（最后一页不显示，那时按钮本身就是「完成」）
            SizedBox(
              height: 44,
              child: last
                  ? null
                  : Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _finish,
                        child: Text(
                          AppStrings.t('common.skip'),
                          style: AppText.desc12
                              .copyWith(color: AppColors.textSecondary),
                        ),
                      ),
                    ),
            ),
            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (i) => setState(() => _page = i),
                children: const [
                  _WelcomePage(),
                  _RiskPage(),
                  _ActivatePage(),
                ],
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _pageCount; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _page ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _page ? AppColors.accent : AppColors.divider,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: TextButton(
                  onPressed: _next,
                  style: TextButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    last
                        ? AppStrings.t('onboarding.enter')
                        : AppStrings.t('common.next'),
                    style: AppText.rowLabel.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
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

/// 通用页骨架：图标 + 标题 + 内容。
class _PageShell extends StatelessWidget {
  const _PageShell({
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 56,
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.accentDim,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, size: 28, color: AppColors.accent),
          ),
          const SizedBox(height: 20),
          Text(title, style: AppText.appTitle),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }
}

/// 一行：勾号 + 文案。
class _Bullet extends StatelessWidget {
  const _Bullet({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(Icons.check_circle, size: 15, color: AppColors.accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: AppText.body13.copyWith(height: 1.45)),
          ),
        ],
      ),
    );
  }
}

class _WelcomePage extends StatelessWidget {
  const _WelcomePage();

  @override
  Widget build(BuildContext context) {
    return _PageShell(
      icon: Icons.shield_moon_outlined,
      title: AppStrings.t('onboarding.welcomeTitle'),
      children: [
        Text(
          AppStrings.t('onboarding.welcomeDesc'),
          style: AppText.body13.copyWith(height: 1.5),
        ),
        const SizedBox(height: 20),
        _Bullet(text: AppStrings.t('onboarding.welcomePoint1')),
        _Bullet(text: AppStrings.t('onboarding.welcomePoint2')),
        _Bullet(text: AppStrings.t('onboarding.welcomePoint3')),
      ],
    );
  }
}

class _RiskPage extends StatelessWidget {
  const _RiskPage();

  @override
  Widget build(BuildContext context) {
    return _PageShell(
      icon: Icons.warning_amber_rounded,
      title: AppStrings.t('onboarding.step3Title'),
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: AppColors.iconOrange.withValues(alpha: 0.45),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 16, color: AppColors.iconOrange),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  AppStrings.t('onboarding.step3Desc'),
                  style: AppText.body13.copyWith(height: 1.5),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 首次激活清单页。
///
/// 每项都查真实状态（不是记住用户点过没有），所以从系统设置里授权完回来、
/// 或者在别处部署过框架，这里刷新一下就会显示已完成。
class _ActivatePage extends StatefulWidget {
  const _ActivatePage();

  @override
  State<_ActivatePage> createState() => _ActivatePageState();
}

class _ActivatePageState extends State<_ActivatePage>
    with WidgetsBindingObserver {
  AutostartStatus? _status;
  StoragePermissionStatus _storage = StoragePermissionStatus.denied;
  bool _fwInstalled = false;
  bool _tokenSet = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // 去系统设置授权后回到 App 需要重新查一遍
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
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final st = await AutostartService.instance.status();
    final storage = await StoragePermissionService.instance.status();
    final fw = await AutostartService.instance.frameworkInstalled();
    final token = await WebuiTokenManager.instance.isSetOnDevice();
    if (!mounted) return;
    setState(() {
      _status = st;
      _storage = storage;
      _fwInstalled = fw;
      _tokenSet = token;
    });
  }

  void _toast(String text, {bool ok = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: ok ? null : AppColors.iconRed,
      ),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    await action();
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  /// 通知权限 —— 配对的前置条件。
  Future<void> _askNotification() => _run(() async {
        await AutostartService.instance.requestNotification();
      });

  Future<void> _askStorage() => _run(() async {
        await StoragePermissionService.instance.request();
      });

  /// 配对：与「开机自启设置」页完全同一套流程（配对码在通知栏输入）。
  Future<void> _pair() => _run(() async {
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
      });

  Future<void> _deploy() => _run(() async {
        final r = await AutostartService.instance.deployFramework();
        if (!mounted) return;
        _toast(r.ok ? AppStrings.t('onboarding.deployOk') : '${AppStrings.t('onboarding.deployFail')}：${r.msg}',
            ok: r.ok);
      });

  Future<void> _setToken() => _run(() async {
        await showWebuiTokenDialog(context);
      });

  /// 开关「开机自启」。沿用设置页的同一套前置：没配对时先提示去配对。
  Future<void> _setAutostart(bool value) async {
    if (_busy) return;
    if (value && !(_status?.provisioned ?? false)) {
      _toast(AppStrings.t('onboarding.pairFirst'), ok: false);
      return;
    }
    setState(() => _busy = true);
    await AutostartService.instance.setEnabled(value);
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  /// 去「开机自启设置」页看详情（上次执行结果等）。
  void _openAutostartSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AutostartScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final notify = _status?.notifyGranted ?? false;
    final paired = _status?.provisioned ?? false;
    final storageOk = _storage == StoragePermissionStatus.granted ||
        _storage == StoragePermissionStatus.notRequired;

    return _PageShell(
      icon: Icons.power_settings_new_rounded,
      title: AppStrings.t('onboarding.activateTitle'),
      children: [
        Text(
          AppStrings.t('onboarding.activateDesc'),
          style: AppText.body13.copyWith(height: 1.5),
        ),
        const SizedBox(height: 16),
        _CheckRow(
          title: AppStrings.t('onboarding.permNotify'),
          desc: AppStrings.t('onboarding.permNotifyDesc'),
          done: notify,
          busy: _busy,
          onAction: _askNotification,
        ),
        _CheckRow(
          title: AppStrings.t('onboarding.permStorage'),
          desc: AppStrings.t('onboarding.permStorageDesc'),
          done: storageOk,
          busy: _busy,
          optional: true,
          onAction: _askStorage,
        ),
        _CheckRow(
          title: AppStrings.t('onboarding.pair'),
          desc: AppStrings.t('onboarding.pairDesc'),
          done: paired,
          busy: _busy,
          onAction: _pair,
        ),
        // 开机自启：原来只在设置页，合并到这里 —— 激活流程本来就要配它
        _CheckRow(
          title: AppStrings.t('settings.autostart'),
          desc: AppStrings.t('onboarding.autostartDesc'),
          done: _status?.enabled ?? false,
          busy: _busy,
          onAction: () async {},
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppSwitch(
                value: _status?.enabled ?? false,
                onChanged: (v) => _setAutostart(v),
              ),
              const SizedBox(width: 6),
              InkWell(
                onTap: _busy ? null : _openAutostartSettings,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: _busy ? AppColors.textInactive : AppColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
        _CheckRow(
          title: AppStrings.t('onboarding.deploy'),
          desc: AppStrings.t('onboarding.deployDesc'),
          done: _fwInstalled,
          busy: _busy,
          onAction: _deploy,
        ),
        _CheckRow(
          title: AppStrings.t('onboarding.token'),
          desc: AppStrings.t('onboarding.tokenOptionalDesc'),
          done: _tokenSet,
          busy: _busy,
          optional: true,
          onAction: _setToken,
        ),
        const SizedBox(height: 4),
        Center(
          child: TextButton(
            onPressed: _busy ? null : _refresh,
            child: Text(
              AppStrings.t('onboarding.refresh'),
              style: AppText.desc12.copyWith(color: AppColors.textSecondary),
            ),
          ),
        ),
      ],
    );
  }
}

/// 清单一行：状态圆点 + 标题 + 说明 + 动作按钮。
class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.title,
    required this.desc,
    required this.done,
    required this.busy,
    required this.onAction,
    this.optional = false,
    this.trailing,
  });

  final String title;
  final String desc;
  final bool done;
  final bool busy;
  final bool optional;
  final Future<void> Function() onAction;

  /// 传了就替换右侧的动作按钮/已完成文字（用于「开机自启」这种
  /// 既要看状态又要直接操作的项）。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: done ? AppColors.accent.withValues(alpha: 0.4) : AppColors.divider,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              done ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 17,
              color: done ? AppColors.accent : AppColors.textInactive,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(child: Text(title, style: AppText.rowLabel)),
                    if (optional) ...[
                      const SizedBox(width: 6),
                      Text(
                        '· ${AppStrings.t('onboarding.optional')}',
                        style: AppText.desc12
                            .copyWith(color: AppColors.textInactive),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(desc, style: AppText.desc12.copyWith(height: 1.4)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (trailing != null)
            trailing!
          else if (done)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                AppStrings.t('onboarding.doneTag'),
                style: AppText.desc12.copyWith(color: AppColors.accent),
              ),
            )
          else
            InkWell(
              onTap: busy ? null : () => onAction(),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: AppColors.accentDim,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  AppStrings.t('onboarding.action'),
                  style: AppText.desc12.copyWith(
                    color: busy ? AppColors.textInactive : AppColors.accent,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
