import 'package:flutter/material.dart';

import '../services/autostart_service.dart';
import '../theme/app_theme.dart';
import '../widgets/back_icon_button.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/screen_app_bar.dart';

/// 开机自启的配置与诊断页 —— 独立页面（自带 Scaffold）。
///
/// ## 页面要解决的问题
///
/// 框架本身没有自启能力（它是 shell 脚本，以 shell 身份运行）。
/// 非 root 设备上要让它在每次开机后自动跑起来，只能借 ADB：
/// App 自带一个 adb 可执行文件，自己连自己的 `127.0.0.1:5555`，拿到 shell 后拉起框架。
///
/// 这条链路有三个前置条件，缺一不可，所以本页把三者都做成可见、可单独执行的步骤：
/// 1. 通知权限 —— 不然自启成功了用户也不知道
/// 2. 设备配对   —— 让 adbd 认识 App 的公钥（只需一次，密钥跨重启保持）
/// 3. 固定端口   —— `adb tcpip 5555` 写下的 persist 属性跨重启保持，
///    开机后 adbd 才会自动监听 5555
///
/// 每一步都能单独重试，且都能看到真实结果，避免「配了但没生效」的无声失败。
class AutostartScreen extends StatefulWidget {
  const AutostartScreen({super.key});

  @override
  State<AutostartScreen> createState() => _AutostartScreenState();
}

class _AutostartScreenState extends State<AutostartScreen> {
  AutostartStatus _status = AutostartStatus.unknown;

  /// 框架是否已部署在设备上。null = 还没查到（避免误显示「未部署」）。
  bool? _frameworkInstalled;

  bool _loading = true;
  bool _busy = false;
  bool _deploying = false;

  /// 首次配对引导只弹一次（本页面生命周期内）。
  bool _guidanceShown = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final results = await Future.wait([
      AutostartService.instance.status(),
      AutostartService.instance.frameworkInstalled(),
    ]);
    if (!mounted) return;
    setState(() {
      _status = results[0] as AutostartStatus;
      _frameworkInstalled = results[1] as bool;
      _loading = false;
    });

    // ★ 首次进入且还没配对 → 主动引导（用户要求：发现未连接就直接带进配对流程）
    if (!_status.provisioned && !_guidanceShown && mounted) {
      _guidanceShown = true;
      _showFirstRunGuide();
    }
  }

  /// 首次进入的配对引导。只弹一次（本页面生命周期内）。
  Future<void> _showFirstRunGuide() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('还没连接上框架', style: AppText.cardTitle),
        content: Text(
          '现在开始配对吗？\n\n'
          '流程：点「开始配对」→ 通知栏会出现输入框 → '
          '到 开发者选项 → 无线调试 打开「使用配对码配对设备」→ '
          '把配对码填进通知 → 完成。\n\n'
          '配对端口会自动发现，全程不用碰电脑。',
          style: AppText.body13,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('稍后再说',
                style: AppText.rowLabel.copyWith(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('开始配对',
                style: AppText.rowLabel.copyWith(color: AppColors.accent)),
          ),
        ],
      ),
    );
    if (ok == true && mounted) _pair();
  }

  /// 统一包一层「忙碌中 + 结果提示」，避免每个操作各写一遍。
  Future<void> _run(Future<({bool ok, String msg})> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final res = await action();
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
    if (!mounted) return;
    _toast(res.ok ? res.msg : '失败：${res.msg}', ok: res.ok);
  }

  void _toast(String text, {bool ok = true}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: ok ? null : AppColors.iconRed,
      ),
    );
  }

  /// 部署 / 修复框架。内置包 12MB，推到设备再解压，耗时可达一两分钟。
  Future<void> _deploy() async {
    if (_deploying) return;
    final ok = await showConfirmDialog(
      context,
      title: _frameworkInstalled == true ? '修复框架' : '部署框架',
      message: '把 App 内置的框架包推送到设备并解压到\n'
          '${_status.frameDir}\n\n'
          '已有文件会被覆盖（脚本被改坏、被误删都能一键还原），\n'
          '耗时约 1～2 分钟，期间请保持屏幕亮着。',
      danger: _frameworkInstalled == true,
    );
    if (ok != true || !mounted) return;

    setState(() => _deploying = true);
    final res = await AutostartService.instance.deployFramework();
    if (!mounted) return;
    setState(() => _deploying = false);
    await _load();
    if (!mounted) return;
    _toast(res.ok ? res.msg : '失败：${res.msg}', ok: res.ok);
  }

  // ---------------- 三个步骤 ----------------

  Future<void> _grantNotify() async {
    final granted = await AutostartService.instance.requestNotification();
    if (!mounted) return;
    await _load();
    if (!mounted) return;
    if (!granted) {
      _toast('未获得通知权限，自启结果将无法通知你', ok: false);
    }
  }

  /// 一键配对（Shizuku 式）。
  ///
  /// 1. 确保通知权限（配对码要在通知里输入）
  /// 2. 发出「等待配对码」通知
  /// 3. 引导用户去系统打开配对界面拿配对码
  ///
  /// 配对端口**不需要用户填**：用户提交配对码时，配对界面必然还开着，
  /// 那时用 mDNS 扫 `_adb-tls-pairing._tcp` 就能拿到 —— 时机最准。
  Future<void> _pair() async {
    // 通知权限是前置：配对码在通知里输入，没有权限流程走不下去
    if (!_status.notifyGranted) {
      await AutostartService.instance.requestNotification();
      await _load();
      if (!mounted) return;
      if (!_status.notifyGranted) {
        _toast('需要通知权限才能在通知栏输入配对码', ok: false);
        return;
      }
    }

    final flow = await AutostartService.instance.startPairingFlow();
    if (!mounted) return;
    if (flow.needPermission) {
      // 首次进入时权限还没给，再来一次
      await AutostartService.instance.requestNotification();
      final retry = await AutostartService.instance.startPairingFlow();
      if (!mounted) return;
      if (!retry.ok) {
        _toast('通知权限未授予，无法发起配对', ok: false);
        return;
      }
    } else if (!flow.ok) {
      _toast('发起配对失败：${flow.msg}', ok: false);
      return;
    }

    await _load();
    if (!mounted) return;

    // 引导用户去拿配对码。系统开发者选项页一次直达。
    final opened = await AutostartService.instance.openWirelessDebug();
    if (!mounted) return;
    if (opened) {
      _toast('通知已发出：打开「无线调试 → 使用配对码配对设备」，'
          '把配对码填进通知即可');
    } else {
      _toast('通知已发出。请手动到 开发者选项 → 无线调试 打开配对界面');
    }
  }

  /// 手动兜底：mDNS 扫不到时的老路 —— 用户自己抄配对端口和配对码。
  Future<void> _pairManually() async {
    final ctrlPort = TextEditingController();
    final ctrlCode = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('配对设备', style: AppText.cardTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '手机上操作：设置 → 开发者选项 → 无线调试 → '
                '「使用配对码配对设备」。\n\n'
                '把弹窗里的两个数字填到下面（**保持那个配对弹窗打开**，'
                '一旦关掉端口就变了）。',
                style: AppText.body13,
              ),
              const SizedBox(height: 16),
              _Field(controller: ctrlPort, label: '配对端口', hint: '如 37193'),
              const SizedBox(height: 12),
              _Field(controller: ctrlCode, label: '配对码', hint: '如 123456'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消',
                style: AppText.rowLabel.copyWith(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('配对',
                style: AppText.rowLabel.copyWith(color: AppColors.accent)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final port = ctrlPort.text.trim();
    final code = ctrlCode.text.trim();
    if (port.isEmpty || code.isEmpty) {
      if (!mounted) return;
      _toast('配对端口与配对码都要填', ok: false);
      return;
    }

    var res = await AutostartService.instance.pair(port: port, code: code);
    if (!mounted) return;

    // 配对成功后立刻把端口固定下来 —— 否则重启后又得重新配对
    if (res.ok) {
      final fixed = await AutostartService.instance.ensurePort();
      if (!mounted) return;
      res = fixed.ok
          ? (ok: true, msg: '配对成功，并已固定端口 ${_status.port}')
          : (ok: false, msg: '配对成功，但固定端口失败：${fixed.msg}');
    }

    await _load();
    if (!mounted) return;
    _toast(res.ok ? res.msg : res.msg, ok: res.ok);
  }

  Future<void> _runNow() async {
    if (_busy) return;
    setState(() => _busy = true);
    final r = await AutostartService.instance.runNow();
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
    if (!mounted) return;

    if (r.skipped) {
      _toast('框架已经在运行，无需重复启动');
    } else {
      _toast(r.ok ? '成功：${r.msg}' : '失败：${r.msg}', ok: r.ok);
    }
  }

  // ---------------- 渲染 ----------------

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
                children: [
                  const BackIconButton(),
                  const SizedBox(width: 4),
                  const Expanded(child: ScreenAppBar(title: '开机自启')),
                  IconButton(
                    onPressed: _loading || _busy ? null : _load,
                    icon: const Icon(Icons.refresh,
                        size: 20, color: AppColors.textSecondary),
                    tooltip: '刷新',
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      children: [
                        _StatusCard(status: _status),
                        const SizedBox(height: 16),
                        _sectionTitle('框架'),
                        const SizedBox(height: 8),
                        _FrameworkCard(
                          installed: _frameworkInstalled,
                          frameDir: _status.frameDir,
                          deploying: _deploying,
                          onDeploy: _deploy,
                        ),
                        const SizedBox(height: 16),
                        _sectionTitle('配置步骤'),
                        const SizedBox(height: 8),
                        _StepCard(
                          index: 1,
                          title: '通知权限',
                          desc: '自启是后台静默完成的，没有通知你就无法确认它到底有没有生效。',
                          done: _status.notifyGranted,
                          doneText: '已授权',
                          actionText: '去授权',
                          enabled: !_busy,
                          onTap: _grantNotify,
                        ),
                        const SizedBox(height: 8),
                        _StepCard(
                          index: 2,
                          title: '设备配对',
                          desc: '点「去配对」后在通知栏输入配对码即可 —— '
                              '配对端口会自动发现，不用手抄。只需做一次，'
                              '密钥跨重启保持，之后每次开机都是静默重认证。',
                          done: _status.provisioned,
                          doneText: '已配对',
                          actionText: '去配对',
                          enabled: !_busy && !_deploying,
                          onTap: _pair,
                          secondaryText: '手动填入',
                          onSecondary: _pairManually,
                        ),
                        const SizedBox(height: 8),
                        _StepCard(
                          index: 3,
                          title: '固定 ADB 端口',
                          desc: '把端口固定为 ${_status.port}，这项设置跨重启保持，'
                              '开机后系统会自动监听它 —— 这是全自动的前提。',
                          done: _status.portFixed,
                          doneText: '已固定',
                          actionText: '执行',
                          enabled: !_busy,
                          onTap: () =>
                              _run(AutostartService.instance.ensurePort),
                        ),
                        const SizedBox(height: 16),
                        _sectionTitle('验证'),
                        const SizedBox(height: 8),
                        _PrimaryButton(
                          label: _busy ? '执行中…' : '立即执行一次',
                          icon: Icons.play_arrow_rounded,
                          enabled: !_busy,
                          onTap: _runNow,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '不必等到下次开机 —— 这里会完整走一遍'
                          '「重认证 → 取 shell → 拉起框架」并给出真实结果。',
                          style: AppText.desc12,
                        ),
                        const SizedBox(height: 16),
                        _sectionTitle('重要提示'),
                        const SizedBox(height: 8),
                        _NoticeCard(
                          onOpenSettings: () async {
                            final ok = await AutostartService
                                .instance
                                .openAutostartSettings();
                            if (!mounted) return;
                            if (!ok) _toast('未找到自启动管理页，请手动到系统设置里放行', ok: false);
                          },
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) =>
      Text(text, style: AppText.sectionTitle);
}

/// 框架部署卡片。
///
/// App 内置了框架包（assets/framework.tar.gz，约 12MB），所以部署、修复、
/// 重置都能在手机上完成 —— 不需要电脑。这也是「无限次调试」的底气：
/// 框架改坏了就重新部署，改配置改乱了也是。
class _FrameworkCard extends StatelessWidget {
  const _FrameworkCard({
    required this.installed,
    required this.frameDir,
    required this.deploying,
    required this.onDeploy,
  });

  /// null = 还没查到，显示「检测中」而不是误报「未部署」。
  final bool? installed;
  final String frameDir;
  final bool deploying;
  final VoidCallback onDeploy;

  @override
  Widget build(BuildContext context) {
    final state = deploying
        ? '部署中…'
        : switch (installed) {
            true => '已部署',
            false => '未部署',
            null => '检测中…',
          };
    final stateColor = switch ((deploying, installed)) {
      (false, true) => AppColors.accent,
      (false, false) => AppColors.iconOrange,
      _ => AppColors.textSecondary,
    };

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('框架包', style: AppText.rowLabel),
              ),
              Text(state, style: AppText.desc12.copyWith(color: stateColor)),
              const SizedBox(width: 10),
              InkWell(
                onTap: deploying ? null : onDeploy,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: deploying ? AppColors.bg : AppColors.accentDim,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    deploying ? '部署中…' : (installed == true ? '修复' : '部署'),
                    style: AppText.desc12.copyWith(
                      color: deploying ? AppColors.textInactive : AppColors.accent,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'App 内置了整套框架（含 Python 运行时，约 12MB）。\n'
            '部署位置：$frameDir\n\n'
            '重复点「修复」即可把框架还原成出厂状态 —— 脚本改坏了、删了都不怕。\n'
            '启动框架时若发现未部署，也会自动补上。',
            style: AppText.desc12,
          ),
        ],
      ),
    );
  }
}

/// 状态总览。
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status});

  final AutostartStatus status;

  @override
  Widget build(BuildContext context) {
    final last = status.lastRunAt;
    final lastText = last == null
        ? '尚未执行'
        : '${_fmt(last)}  ${status.lastOk ? "成功" : "失败"}';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                status.enabled ? Icons.restart_alt_rounded : Icons.pause_circle_outline,
                size: 20,
                color: status.enabled ? AppColors.accent : AppColors.textInactive,
              ),
              const SizedBox(width: 8),
              Text(status.enabled ? '开机自启已开启' : '开机自启已关闭',
                  style: AppText.cardTitle),
            ],
          ),
          const SizedBox(height: 14),
          _kv('密钥', status.provisioned ? '已生成（未授权则需配对）' : '未生成'),
          const SizedBox(height: 10),
          _kv('固定端口', '${status.port}'),
          const SizedBox(height: 10),
          _kv('上次自启', lastText),
          if (!status.neverRun && status.lastMsg.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(status.lastMsg, style: AppText.desc12),
          ],
        ],
      ),
    );
  }

  static String _fmt(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.month}月${t.day}日 ${two(t.hour)}:${two(t.minute)}';
  }

  Widget _kv(String k, String v) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 72, child: Text(k, style: AppText.body13)),
          Expanded(
            child: Text(v,
                style: AppText.body13.copyWith(color: AppColors.textSecondary)),
          ),
        ],
      );
}

/// 单个配置步骤卡片。
class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.index,
    required this.title,
    required this.desc,
    required this.done,
    required this.doneText,
    required this.actionText,
    required this.enabled,
    required this.onTap,
    this.secondaryText,
    this.onSecondary,
  });

  final int index;
  final String title;
  final String desc;
  final bool done;
  final String doneText;
  final String actionText;
  final bool enabled;
  final VoidCallback onTap;

  /// 次要操作（如「手动填入」），显示在主按钮左侧；为空则不显示。
  final String? secondaryText;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: done
                      ? AppColors.accent.withValues(alpha: 0.16)
                      : AppColors.bg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: done ? AppColors.accent : AppColors.divider,
                  ),
                ),
                child: done
                    ? const Icon(Icons.check, size: 13, color: AppColors.accent)
                    : Text('$index',
                        style: AppText.desc12.copyWith(fontSize: 11)),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: AppText.rowLabel)),
              if (done && doneText.isNotEmpty)
                Text(doneText,
                    style: AppText.desc12.copyWith(color: AppColors.accent)),
              if (secondaryText != null) ...[
                const SizedBox(width: 8),
                InkWell(
                  onTap: (enabled && onSecondary != null) ? onSecondary : null,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: enabled ? AppColors.bg : AppColors.bg,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppColors.divider),
                    ),
                    child: Text(
                      secondaryText!,
                      style: AppText.desc12.copyWith(
                        color: enabled
                            ? AppColors.textSecondary
                            : AppColors.textInactive,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 8),
              InkWell(
                onTap: enabled ? onTap : null,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: enabled ? AppColors.accentDim : AppColors.bg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    actionText,
                    style: AppText.desc12.copyWith(
                      color:
                          enabled ? AppColors.accent : AppColors.textInactive,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(desc, style: AppText.desc12),
        ],
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? AppColors.accent : AppColors.textInactive;
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 6),
            Text(label, style: AppText.rowLabel.copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}

/// 限制说明 + 系统自启动管理入口。
class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '· 小米 / Redmi 机型默认拦截开机广播，需要在系统的「自启动管理」里'
            '放行本应用，否则自启不会生效，而且**不会有任何报错**。\n\n'
            '· 自启依赖固定端口，因此该端口会常驻监听。它需要 ADB 密钥才能连接，'
            '但同网络下的设备仍可尝试 —— 请勿在不可信网络下长期开启。\n\n'
            '· 请勿在框架运行期间切换 USB / 无线调试或执行 adb 模式切换命令：'
            '那会重启 ADB 服务，连带终止框架进程。',
            style: AppText.desc12,
          ),
          const SizedBox(height: 14),
          InkWell(
            onTap: onOpenSettings,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.bg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.divider),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.settings_applications_outlined,
                      size: 16, color: AppColors.textSecondary),
                  const SizedBox(width: 6),
                  Text('打开系统自启动管理',
                      style: AppText.rowLabel
                          .copyWith(color: AppColors.textSecondary)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 对话框里的小输入框。
class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    required this.hint,
  });

  final TextEditingController controller;
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      style: AppText.monoValue14.copyWith(color: AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: AppText.body13,
        hintStyle: AppText.desc12,
        isDense: true,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppColors.accent),
        ),
      ),
    );
  }
}
