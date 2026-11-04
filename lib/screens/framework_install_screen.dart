import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/app_strings.dart';
import '../services/autostart_service.dart';
import '../services/shell_executor.dart';
import '../services/webui_token.dart';
import '../theme/app_theme.dart';
import '../widgets/app_switch.dart';
import '../widgets/back_icon_button.dart';
import '../widgets/confirm_dialog.dart';

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
  bool _hasRoot = false;

  /// WebUI 访问密钥。默认要求设置 —— 不设的话同设备任何应用都能调用
  /// `/api/shell`（shell 权限），这是唯一拦得住它们的东西。
  final TextEditingController _tokenCtrl = TextEditingController();
  bool _tokenVisible = false;

  /// 高级选项面板是否展开。
  bool _advancedOpen = false;

  /// 跳过密钥（对应「不设置 WebUI 密钥」）。
  bool _skipToken = false;

  /// 是否固定 adb 端口（默认 true，关掉后重启需重新配对）。
  bool _pinPort = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _detectRoot();
  }

  /// 只在页面首次打开时探一次 root（会触发 su 授权弹窗，别反复问）。
  Future<void> _detectRoot() async {
    final ok = await ShellExecutor.instance.hasRoot;
    if (!mounted) return;
    setState(() => _hasRoot = ok);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tokenCtrl.dispose();
    super.dispose();
  }

  /// 密钥是否就绪（跳过或填写合法）。
  bool get _tokenOk =>
      _skipToken || WebuiTokenManager.validate(_tokenCtrl.text) == null;

  /// 输入框下方的错误提示；为空表示没问题。
  String get _tokenError {
    if (_skipToken) return '';
    final v = _tokenCtrl.text;
    if (v.isEmpty) return '';
    return WebuiTokenManager.validate(v) ?? '';
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

  /// 电脑 adb：导出脚本，弹出一条可复制的命令。
  Future<void> _showAdbCommand() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyMsg = AppStrings.t('missing.exporting');
    });
    final r = await AutostartService.instance.exportBootstrap();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _busyMsg = '';
    });
    if (!r.ok) {
      _toast(r.msg, ok: false);
      return;
    }

    final cmd = 'adb shell sh ${r.path}';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(AppStrings.t('missing.adbTitle'), style: AppText.cardTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(AppStrings.t('missing.adbHint'), style: AppText.desc12),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.bg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(cmd, style: AppText.monoValue14),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: cmd));
              if (ctx.mounted) Navigator.of(ctx).pop();
              _toast(AppStrings.t('missing.copied'));
            },
            child: Text(
              AppStrings.t('missing.copy'),
              style: AppText.rowLabel.copyWith(color: AppColors.accent),
            ),
          ),
        ],
      ),
    );
  }

  /// Root：导出后在本地直接 su 执行同一份脚本。
  Future<void> _activateRoot() async {
    if (_busy || !_hasRoot) return;
    final ok = await showConfirmDialog(
      context,
      title: AppStrings.t('missing.rootTitle'),
      message: AppStrings.t('missing.rootMessage'),
      confirmText: AppStrings.t('missing.rootConfirm'),
    );
    if (ok != true || !mounted) return;

    setState(() {
      _busy = true;
      _busyMsg = AppStrings.t('missing.exporting');
    });
    final r = await AutostartService.instance.exportBootstrap();
    if (!mounted) return;
    if (!r.ok) {
      setState(() {
        _busy = false;
        _busyMsg = '';
      });
      _toast(r.msg, ok: false);
      return;
    }

    setState(() => _busyMsg = AppStrings.t('missing.activating'));
    final done = await ShellExecutor.instance.rootOk(
      "sh '${r.path}'",
      timeout: const Duration(seconds: 180),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _busyMsg = '';
    });

    if (done) {
      _toast(AppStrings.t('missing.activated'));
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;
      widget.onInstalled();
      if (mounted) Navigator.of(context).maybePop();
    } else {
      _toast(AppStrings.t('missing.rootFail'), ok: false);
    }
  }

  Future<void> _deploy() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyMsg = AppStrings.t('missing.deploying');
    });

    // 高级选项先落盘：是否固定端口由原生在配对时决定
    await AutostartService.instance.setPinPort(_pinPort);

    final r = await AutostartService.instance.deployFramework();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _busyMsg = '';
    });

    if (r.ok) {
      // 密钥要在框架就位后才能下发（走 adb 写到 state/webui_token）
      if (!_skipToken) {
        final tok = await WebuiTokenManager.instance.set(_tokenCtrl.text);
        if (!mounted) return;
        if (!tok.ok) {
          // 框架已经装好了，密钥没下发不该把用户卡在安装页 ——
          // 提示一句，之后可以在「设置 → 访问密钥」补设。
          _toast('${AppStrings.t('webuiToken.applyFailed')}${tok.msg}',
              ok: false);
        }
      }
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

  /// WebUI 访问密钥输入区。
  Widget _tokenCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppStrings.t('missing.tokenTitle'),
            style: AppText.rowLabel.copyWith(fontSize: 16),
          ),
          const SizedBox(height: 4),
          Text(AppStrings.t('missing.tokenDesc'), style: AppText.desc12),
          const SizedBox(height: 10),
          TextField(
            controller: _tokenCtrl,
            enabled: !_skipToken,
            obscureText: !_tokenVisible,
            onChanged: (_) => setState(() {}),
            style: AppText.monoValue14.copyWith(
              color: _skipToken ? AppColors.textInactive : AppColors.textPrimary,
            ),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: AppColors.bg,
              hintText: _skipToken
                  ? AppStrings.t('missing.tokenSkipped')
                  : AppStrings.t('missing.tokenHint'),
              hintStyle: AppText.desc12,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              suffixIcon: IconButton(
                icon: Icon(
                  _tokenVisible
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                  size: 18,
                ),
                color: AppColors.textInactive,
                onPressed: () =>
                    setState(() => _tokenVisible = !_tokenVisible),
              ),
            ),
          ),
          if (_tokenError.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              _tokenError,
              style: AppText.desc12.copyWith(color: AppColors.iconRed),
            ),
          ],
        ],
      ),
    );
  }

  /// 高级选项：默认收起，展开后是两个带后果说明的开关。
  Widget _advancedPanel() {
    return Column(
      children: [
        Material(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => setState(() => _advancedOpen = !_advancedOpen),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      AppStrings.t('missing.advanced'),
                      style: AppText.rowLabel.copyWith(fontSize: 16),
                    ),
                  ),
                  Icon(
                    _advancedOpen
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 20,
                    color: AppColors.textInactive,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_advancedOpen) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                _OptRow(
                  title: AppStrings.t('missing.optNoToken'),
                  desc: AppStrings.t('missing.optNoTokenDesc'),
                  value: _skipToken,
                  warn: _skipToken,
                  onChanged: (v) => setState(() => _skipToken = v),
                ),
                _OptRow(
                  title: AppStrings.t('missing.optPinPort'),
                  desc: AppStrings.t('missing.optPinPortDesc'),
                  value: _pinPort,
                  warn: !_pinPort,
                  onChanged: (v) => setState(() => _pinPort = v),
                  last: true,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

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
                  const SizedBox(height: 16),
                  _tokenCard(),
                  const SizedBox(height: 12),
                  _advancedPanel(),
                  const SizedBox(height: 24),
                  Text(
                    AppStrings.t('missing.otherWays'),
                    style: AppText.desc12,
                  ),
                  const SizedBox(height: 8),
                  _AltCard(
                    icon: Icons.computer_rounded,
                    title: AppStrings.t('missing.adbTitle'),
                    subtitle: AppStrings.t('missing.adbSubtitle'),
                    onTap: _busy ? null : _showAdbCommand,
                  ),
                  const SizedBox(height: 8),
                  _AltCard(
                    icon: Icons.bolt_rounded,
                    title: AppStrings.t('missing.rootTitle'),
                    subtitle: _hasRoot
                        ? AppStrings.t('missing.rootReady')
                        : AppStrings.t('missing.rootUnavailable'),
                    onTap: (_hasRoot && !_busy) ? _activateRoot : null,
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
                      : (_paired ? (_tokenOk ? _deploy : null) : _pair),
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
                        : (!_paired
                            ? AppStrings.t('missing.goPair')
                            : (!_tokenOk
                                ? AppStrings.t('missing.needToken')
                                : AppStrings.t('missing.startInstall'))),
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

/// 「其他激活方式」卡片：一个图标 + 标题 + 说明，整行可点。
class _AltCard extends StatelessWidget {
  const _AltCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
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
              Icon(
                icon,
                size: 22,
                color: enabled ? AppColors.accent : AppColors.textInactive,
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
                        color: enabled
                            ? AppColors.textPrimary
                            : AppColors.textInactive,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(subtitle, style: AppText.desc12),
                  ],
                ),
              ),
              if (enabled)
                Icon(Icons.chevron_right_rounded,
                    size: 20, color: AppColors.textInactive),
            ],
          ),
        ),
      ),
    );
  }
}

/// 高级选项里的一个开关行：标题 + 后果说明 + 开关。
///
/// 说明文字在「不该动这个」的状态下会变成警示色 —— 这类选项的价值就是让
/// 用户看清代价，文字比开关本身更重要。
class _OptRow extends StatelessWidget {
  const _OptRow({
    required this.title,
    required this.desc,
    required this.value,
    required this.onChanged,
    this.warn = false,
    this.last = false,
  });

  final String title;
  final String desc;
  final bool value;
  final bool warn;
  final bool last;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(bottom: BorderSide(color: AppColors.divider, width: 1)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.rowLabel),
                const SizedBox(height: 4),
                Text(
                  desc,
                  style: AppText.desc12.copyWith(
                    color: warn ? AppColors.iconOrange : null,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: AppSwitch(value: value, onChanged: onChanged),
          ),
        ],
      ),
    );
  }
}
