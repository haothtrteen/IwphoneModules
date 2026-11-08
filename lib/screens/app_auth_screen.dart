import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n/app_strings.dart';
import '../services/app_auth_service.dart';
import '../theme/app_theme.dart';
import '../widgets/back_icon_button.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/screen_app_bar.dart';
import '../widgets/settings_rows.dart';

/// 应用授权页 —— 决定「哪些应用可以通过本应用执行 shell 命令」。
///
/// ## 请求即确认（v2）
///
/// 未授权应用发起调用时，原生侧用悬浮窗当场弹出「允许 / 拒绝」对话框，
/// 用户点完才继续执行命令 —— 与 Magisk 的 su 弹窗同一体验。
/// 悬浮窗不是 Activity，所以不受 Android 10+ 后台启动限制。
///
/// 悬浮窗权限需要用户手动开，没开时**自动降级**为 v1 的「待授权列表 +
/// NEED_APPROVAL」：调用只登记、不执行，用户回本页点允许。本页顶部会显示
/// 当前处于哪种模式并给出开启入口。
class AppAuthScreen extends StatefulWidget {
  const AppAuthScreen({
    super.key,
    this.embedded = false,
    this.reloadToken = 0,
  });

  /// 底栏 tab 内嵌时为 true：不包 Scaffold、不显示返回按钮，
  /// 与其它 tab 页一样由 main.dart 的 Scaffold 统一包裹。
  final bool embedded;

  /// 宿主切回本页时递增，触发重新读取授权数据。
  final int reloadToken;

  @override
  State<AppAuthScreen> createState() => _AppAuthScreenState();
}

class _AppAuthScreenState extends State<AppAuthScreen>
    with WidgetsBindingObserver {
  bool _loading = true;
  bool _hasToken = true;
  bool _overlay = false;
  String _error = '';
  List<AuthorizedApp> _grants = const [];
  List<PendingApp> _pending = const [];
  List<AuthorizedApp> _denied = const [];
  List<AuditEntry> _audit = const [];
  List<IwshGrant> _iwshGrants = const [];

  /// 正在撤销/批准的应用包名，用于禁用按钮防连点。
  String? _busy;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void didUpdateWidget(covariant AppAuthScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reloadToken != oldWidget.reloadToken) _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从系统设置页返回时立刻复查悬浮窗权限，不用手动点刷新。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final hasToken = await AppAuthService.instance.hasToken();
      final overlay = await AppAuthService.instance.overlayEnabled();
      final grants = await AppAuthService.instance.listGrants();
      final pending = await AppAuthService.instance.listPending();
      final denied = await AppAuthService.instance.listDenied();
      final audit = await AppAuthService.instance.listAudit();
      final iwshGrants = await AppAuthService.instance.listIwshGrants();
      if (!mounted) return;
      setState(() {
        _hasToken = hasToken;
        _overlay = overlay;
        _grants = grants;
        _pending = pending;
        _denied = denied;
        _audit = audit;
        _iwshGrants = iwshGrants;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  // ---------------- 操作 ----------------

  Future<void> _grant(String pkg, String label) async {
    setState(() => _busy = pkg);
    final r = await AppAuthService.instance.grant(pkg);
    if (!mounted) return;
    setState(() => _busy = null);
    if (!r.ok) {
      _toast(r.msg, ok: false);
      return;
    }
    _toast(
      '${AppStrings.t('auth.grantedPrefix')}$label${AppStrings.t('auth.grantedSuffix')}',
    );
    await _load();
  }

  Future<void> _revoke(String pkg, String label) async {
    final ok = await showConfirmDialog(
      context,
      title: AppStrings.t('auth.revokeConfirmTitle'),
      message: '${AppStrings.t('auth.revokeConfirmPrefix')}$label'
          '${AppStrings.t('auth.revokeConfirmSuffix')}',
      confirmText: AppStrings.t('auth.revoke'),
      danger: true,
    );
    if (!ok) return;

    setState(() => _busy = pkg);
    await AppAuthService.instance.revoke(pkg);
    if (!mounted) return;
    setState(() => _busy = null);
    _toast(AppStrings.t('auth.revoked'));
    await _load();
  }

  Future<void> _pickApp() async {
    final picked = await showModalBottomSheet<PickableApp>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const _AppPickerSheet(),
    );
    if (picked == null || !mounted) return;
    await _grant(picked.pkg, picked.label);
  }

  void _toast(String text, {bool ok = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      backgroundColor: ok ? null : AppColors.iconRed,
    ));
  }

  // ---------------- 构建 ----------------

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ScreenAppBar(
              title: AppStrings.t('auth.title'),
              actions: [
                AppBarActionIcon(
                  icon: Icons.refresh_rounded,
                  onTap: _loading ? null : _load,
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_loading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 80),
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.accent),
                ),
              )
            else if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '${AppStrings.t('auth.loadFail')}\n$_error',
                  textAlign: TextAlign.center,
                  style: AppText.desc12,
                ),
              )
            else
              ..._cards(),
          ],
        ),
      );
    }
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
              child: Row(
                children: [
                  const BackIconButton(),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      AppStrings.t('auth.title'),
                      style: AppText.appTitle,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                    color: AppColors.textSecondary,
                    onPressed: _loading ? null : _load,
                    tooltip: AppStrings.t('auth.refresh'),
                  ),
                ],
              ),
            ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(color: AppColors.accent),
      );
    }
    if (_error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '${AppStrings.t('auth.loadFail')}\n$_error',
            textAlign: TextAlign.center,
            style: AppText.desc12,
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: _cards(),
    );
  }

  /// 卡片列表：底栏 tab（embedded）与独立页面共用同一份内容。
  List<Widget> _cards() => [
        _introCard(),
        const SizedBox(height: 12),
        _promptCard(),
        if (!_hasToken) ...[
          const SizedBox(height: 12),
          _tokenWarning(),
        ],
        const SizedBox(height: 16),

        if (_pending.isNotEmpty) ...[
          SettingsSection(
            title: AppStrings.t('auth.sectionPending'),
            children: [
              Text(AppStrings.t('auth.pendingHint'), style: AppText.desc12),
              const SizedBox(height: 8),
              for (final p in _pending) _pendingRow(p),
            ],
          ),
          const SizedBox(height: 16),
        ],

        SettingsSection(
          title: AppStrings.t('auth.sectionGrants'),
          children: [
            if (_grants.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(AppStrings.t('auth.emptyGrants'), style: AppText.desc12),
              )
            else
              for (final g in _grants) _grantRow(g),
            const SizedBox(height: 8),
            NavRow(
              label: AppStrings.t('auth.addApp'),
              hint: AppStrings.t('auth.pickNoLauncher'),
              onTap: _pickApp,
            ),
          ],
        ),
        const SizedBox(height: 16),

        SettingsSection(
          title: AppStrings.t('auth.iwshGrants'),
          children: [
            Text(AppStrings.t('auth.iwshGrantsHint'), style: AppText.desc12),
            const SizedBox(height: 8),
            if (_iwshGrants.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(AppStrings.t('auth.iwshGrantsEmpty'),
                    style: AppText.desc12),
              )
            else
              for (final g in _iwshGrants) _iwshGrantRow(g),
          ],
        ),
        const SizedBox(height: 16),

        if (_denied.isNotEmpty) ...[
          SettingsSection(
            title: AppStrings.t('auth.sectionDenied'),
            children: [
              Text(AppStrings.t('auth.deniedHint'), style: AppText.desc12),
              const SizedBox(height: 8),
              for (final d in _denied) _deniedRow(d),
              const SizedBox(height: 6),
              NavRow(
                label: AppStrings.t('auth.clearDenied'),
                hint: AppStrings.t('auth.clearedDenied'),
                onTap: () async {
                  await AppAuthService.instance.clearDenied();
                  _toast(AppStrings.t('auth.clearedDenied'));
                  await _load();
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],

        SettingsSection(
          title: AppStrings.t('auth.sectionAudit'),
          children: [
            if (_audit.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(AppStrings.t('auth.emptyAudit'), style: AppText.desc12),
              )
            else ...[
              for (final a in _audit.take(30)) _auditRow(a),
              if (_audit.length > 30)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('… ${_audit.length - 30}', style: AppText.desc12),
                ),
            ],
            if (_audit.isNotEmpty) ...[
              const SizedBox(height: 6),
              NavRow(
                label: AppStrings.t('auth.clearAudit'),
                hint: AppStrings.t('auth.clearedAudit'),
                danger: true,
                onTap: () async {
                  await AppAuthService.instance.clearAudit();
                  _toast(AppStrings.t('auth.clearedAudit'));
                  await _load();
                },
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),

        SettingsSection(
          title: AppStrings.t('auth.usageTitle'),
          children: [
            Text(AppStrings.t('auth.usageIntro'), style: AppText.desc12),
            const SizedBox(height: 8),
            NavRow(
              label: AppStrings.t('auth.usageTitle'),
              hint: 'content://com.shellmgr.shell_manager.broker',
              onTap: () => _showUsage(context),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(AppStrings.t('auth.frameworkNote'), style: AppText.footer),
  ];

  Widget _introCard() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.verified_user_outlined,
                    size: 18, color: AppColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    AppStrings.t('auth.introTitle'),
                    style: AppText.cardTitle,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(AppStrings.t('auth.introBody'), style: AppText.desc12),
          ],
        ),
      );

  Widget _tokenWarning() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.iconOrange.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.iconOrange.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 18, color: AppColors.iconOrange),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    AppStrings.t('auth.warnTokenTitle'),
                    style: AppText.cardTitle.copyWith(color: AppColors.iconOrange),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(AppStrings.t('auth.warnTokenBody'), style: AppText.desc12),
          ],
        ),
      );

  /// 即时弹窗状态卡片：开着显示绿灯，没开给出开启入口。
  Widget _promptCard() {
    final on = _overlay;
    final color = on ? AppColors.accent : AppColors.iconOrange;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(on ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                  size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  on
                      ? AppStrings.t('auth.promptOnTitle')
                      : AppStrings.t('auth.promptOffTitle'),
                  style: AppText.cardTitle.copyWith(color: color),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            on
                ? AppStrings.t('auth.promptOnBody')
                : AppStrings.t('auth.promptOffBody'),
            style: AppText.desc12,
          ),
          if (!on) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () async {
                  // 既然 App 已经拿到 shell，优先用 adb 给自己授权；
                  // 只有该 ROM 拦 appops 时才退回系统设置页。
                  final r = await AppAuthService.instance.grantOverlayViaAdb();
                  if (!mounted) return;
                  if (r.enabled) {
                    await _load();
                    _toast(AppStrings.t('auth.overlaySelfGranted'));
                  } else {
                    final ok = await AppAuthService.instance.openOverlaySettings();
                    if (!ok && mounted) {
                      _toast(AppStrings.t('auth.promptOpenFail'), ok: false);
                    }
                  }
                },
                child: Text(AppStrings.t('auth.promptEnable')),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _iwshGrantRow(IwshGrant g) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(Icons.terminal_rounded, size: 30, color: AppColors.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(g.label.isEmpty ? g.pkg : g.label,
                      style: AppText.rowLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  Text('${g.pkg} · uid ${g.uid}', style: AppText.desc12),
                ],
              ),
            ),
            TextButton(
              onPressed: _busy == g.pkg
                  ? null
                  : () async {
                      setState(() => _busy = g.pkg);
                      await AppAuthService.instance.revokeIwshGrant(g.pkg);
                      if (!mounted) return;
                      setState(() => _busy = null);
                      _toast(AppStrings.t('auth.iwshRevoked'));
                      await _load();
                    },
              child: Text(
                AppStrings.t('auth.revoke'),
                style: TextStyle(color: AppColors.iconRed),
              ),
            ),
          ],
        ),
      );

  Widget _deniedRow(AuthorizedApp d) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            _icon(d.icon),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.label.isEmpty ? d.pkg : d.label,
                      style: AppText.rowLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  Text(d.pkg, style: AppText.desc12,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _busy == d.pkg
                  ? null
                  : () async {
                      setState(() => _busy = d.pkg);
                      await AppAuthService.instance.clearDenied(d.pkg);
                      if (!mounted) return;
                      setState(() => _busy = null);
                      _toast(AppStrings.t('auth.clearedDenied'));
                      await _load();
                    },
              child: Text(AppStrings.t('auth.undeny')),
            ),
          ],
        ),
      );

  Widget _pendingRow(PendingApp p) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            _icon(p.icon),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.label.isEmpty ? p.pkg : p.label,
                      style: AppText.rowLabel, maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    '${p.pkg} · ${AppStrings.t('auth.triesPrefix')}${p.tries}'
                    '${AppStrings.t('auth.triesSuffix')} · ${_fmt(p.lastAt)}',
                    style: AppText.desc12,
                    maxLines: 2,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _busy == p.pkg ? null : () => _grant(p.pkg, p.label),
              child: Text(AppStrings.t('auth.allow')),
            ),
            TextButton(
              onPressed: _busy == p.pkg
                  ? null
                  : () async {
                      await AppAuthService.instance.clearPending(p.pkg);
                      await _load();
                    },
              child: Text(
                AppStrings.t('auth.ignore'),
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      );

  Widget _grantRow(AuthorizedApp g) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            _icon(g.icon),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(g.label.isEmpty ? g.pkg : g.label,
                      style: AppText.rowLabel, maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    '${g.pkg}\n'
                    '${AppStrings.t('auth.sigLabel')} ${g.sig.isEmpty ? "-" : g.sig.substring(0, g.sig.length < 12 ? g.sig.length : 12)} · '
                    '${AppStrings.t('auth.calls')} ${g.calls} · '
                    '${AppStrings.t('auth.lastUsed')} ${g.lastUsed == null ? AppStrings.t('auth.never') : _fmt(g.lastUsed)}',
                    style: AppText.desc12,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _busy == g.pkg ? null : () => _revoke(g.pkg, g.label),
              child: Text(
                AppStrings.t('auth.revoke'),
                style: TextStyle(color: AppColors.iconRed),
              ),
            ),
          ],
        ),
      );

  Widget _auditRow(AuditEntry a) {
    final color = a.succeeded
        ? AppColors.textSecondary
        : (a.code == 'OK' ? AppColors.iconOrange : AppColors.iconRed);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 74,
            child: Text(_fmt(a.time), style: AppText.desc12),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  a.cmd.replaceAll('\n', ' '),
                  style: AppText.monoValue14.copyWith(fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${_shortPkg(a.pkg)} · ${a.code}'
                  '${a.exitCode >= 0 ? " · exit ${a.exitCode}" : ""} · ${a.ms}ms',
                  style: AppText.desc12.copyWith(color: color, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _icon(Uint8List? bytes) {
    if (bytes == null) {
      return Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: AppColors.divider,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.android, size: 20, color: AppColors.textSecondary),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.memory(bytes, width: 36, height: 36, gaplessPlayback: true),
    );
  }

  static String _shortPkg(String pkg) {
    final i = pkg.lastIndexOf('.');
    return i >= 0 && i < pkg.length - 1 ? pkg.substring(i + 1) : pkg;
  }

  static String _fmt(DateTime? t) {
    if (t == null) return '-';
    String two(int v) => v.toString().padLeft(2, '0');
    final time = '${two(t.hour)}:${two(t.minute)}';
    if (AppStrings.isEnglish) {
      return '${two(t.month)}-${two(t.day)} $time';
    }
    return '${t.month}/${t.day} $time';
  }

  // ---------------- 接入说明 ----------------

  void _showUsage(BuildContext context) {
    const javaSample = '''
// AndroidManifest.xml（Android 11+ 需要声明可见性）
<queries>
  <provider android:authorities="com.shellmgr.shell_manager.broker" />
</queries>

// 调用
Uri uri = Uri.parse("content://com.shellmgr.shell_manager.broker");
Bundle r = getContentResolver().call(uri, "exec", "id", null);

if (r == null) return;
if (!r.getBoolean("ok")) {
    Log.w(TAG, r.getString("code") + ": " + r.getString("msg"));
    return;
}
int exitCode = r.getInt("exitCode");
String out   = r.getString("stdout");
String err   = r.getString("stderr");

// 其它方法：version / ping / request / exec
// 可传 extras：timeout(Int 1~60)、cwd(String)''';

    const shellSample = r'''#!/system/bin/sh
# ============================================================
# iwphone · 终端 shell 接入示例
# 用法： sh iwphone_terminal.sh [要执行的命令]
#
# 重要：两种终端环境的可用通道不同，脚本按 uid 自动选择。
#   adb shell / root (uid 2000 / 0) → content CLI，可触发应用授权弹窗
#   第三方 app 的终端 (uid 10xxx)  → 回环 HTTP + 访问密钥
# ============================================================
CMD="${1:-id}"
AUTH='content://com.shellmgr.shell_manager.broker'
WEBUI='http://127.0.0.1:8537'

# 第三方 app 终端必填：Shell Manager → 设置 → 访问密钥
TOKEN=''

case "$(id -u)" in
  0|2000)
    echo '== adb shell / root：content CLI（可触发授权弹窗） =='
    # 注意：version / ping / request 一律省略 --arg。
    # 传空的 --arg 会让 content 打印整份 usage（No value for argument）。
    content call --uri "$AUTH" --method version
    content call --uri "$AUTH" --method ping

    # 未授权时弹「允许 / 拒绝」对话框，本条调用阻塞到用户点完。
    # 勾选「记住此选择」→ 长期授权；不勾 → 仅本次。
    content call --uri "$AUTH" --method request

    # 授权通过后执行；只有 exec 需要 --arg
    content call --uri "$AUTH" --method exec --arg "$CMD"
    ;;
  *)
    echo '== 第三方 app 终端：回环 HTTP =='
    # content CLI 内部调 getContentProviderExternal()，需要签名级权限
    # ACCESS_CONTENT_PROVIDERS_EXTERNALLY，普通 app 拿不到，必定抛
    # SecurityException。所以这里改走框架 WebUI 的回环接口。
    # 注意：这条路径不经「应用授权」表，权限由访问密钥承担。
    if [ -z "$TOKEN" ]; then
      echo '请先填入 TOKEN（设置 → 访问密钥）后重试' >&2
      exit 1
    fi
    # 框架的 POST 参数走 query string、不读请求体：
    # 必须用 -G --data-urlencode；用 -d 会得到「命令为空」。
    curl -sS --max-time 20 -G -X POST -H "X-Token: $TOKEN" \
         --data-urlencode "cmd=$CMD" "$WEBUI/api/shell"
    ;;
esac''';

    Future<void> doExportKit() async {
      // 直接导出，不预先绑定应用：包名写在 iwsh.env 里由用户自己改
      final path = await AppAuthService.instance.exportIwsh();
      if (!mounted) return;
      if (path == null || path.isEmpty) {
        _toast(AppStrings.t('auth.exportKitFail'), ok: false);
        return;
      }
      await Clipboard.setData(ClipboardData(text: path));
      Navigator.of(context).pop();
      _toast('${AppStrings.t('auth.exportedKit')}$path\n'
          '${AppStrings.t('auth.iwshEditEnv')}');
    }

    var tab = 0; // 0 = Java, 1 = Shell

    Future<void> doExport() async {
      final path = await AppAuthService.instance.exportScript(
        name: 'iwphone_terminal.sh',
        text: shellSample,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      if (path == null || path.isEmpty) {
        _toast(AppStrings.t('auth.exportFail'), ok: false);
        return;
      }
      await Clipboard.setData(ClipboardData(text: path));
      _toast('${AppStrings.t('auth.exportedScript')}$path');
    }

    void doCopy(String text) {
      Clipboard.setData(ClipboardData(text: text));
      Navigator.of(context).pop();
      _toast(AppStrings.t('auth.copied'));
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (_, setSheet) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.75,
          maxChildSize: 0.92,
          builder: (_, controller) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(AppStrings.t('auth.usageTitle'),
                          style: AppText.cardTitle),
                    ),
                    TextButton(
                      onPressed: doExportKit,
                      child: Text(AppStrings.t('auth.exportKit')),
                    ),
                    if (tab == 1)
                      TextButton(
                        onPressed: doExport,
                        child: Text(AppStrings.t('auth.exportScript')),
                      ),
                    TextButton(
                      onPressed: () =>
                          doCopy(tab == 0 ? javaSample : shellSample),
                      child: Text(AppStrings.t('auth.copy')),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(
                        backgroundColor: tab == 0
                            ? AppColors.accent.withValues(alpha: 0.12)
                            : null,
                      ),
                      onPressed: () => setSheet(() => tab = 0),
                      child: Text(AppStrings.t('auth.usageJava')),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      style: TextButton.styleFrom(
                        backgroundColor: tab == 1
                            ? AppColors.accent.withValues(alpha: 0.12)
                            : null,
                      ),
                      onPressed: () => setSheet(() => tab = 1),
                      child: Text(AppStrings.t('auth.usageShell')),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                child: Text(AppStrings.t('auth.iwshHint'),
                    style: AppText.desc12),
              ),
              Expanded(
                child: SingleChildScrollView(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  child: Text(
                    tab == 0 ? javaSample : shellSample,
                    style: AppText.monoValue14
                        .copyWith(fontSize: 11.5, height: 1.45),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「添加应用」选择器：带搜索的底部弹层。
///
/// 懒加载图标由原生侧统一编码（一次 channel 往返拿全部），
/// 这里只管过滤与选中。
class _AppPickerSheet extends StatefulWidget {
  const _AppPickerSheet();

  @override
  State<_AppPickerSheet> createState() => _AppPickerSheetState();
}

class _AppPickerSheetState extends State<_AppPickerSheet> {
  bool _loading = true;
  List<PickableApp> _all = const [];
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await AppAuthService.instance.installedApps();
    if (!mounted) return;
    setState(() {
      _all = list;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final list = q.isEmpty
        ? _all
        : _all
            .where((a) =>
                a.label.toLowerCase().contains(q) ||
                a.pkg.toLowerCase().contains(q))
            .toList();

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(AppStrings.t('auth.pickTitle'),
                        style: AppText.cardTitle),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    color: AppColors.textSecondary,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                autofocus: false,
                style: AppText.body13,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: AppStrings.t('auth.searchHint'),
                  hintStyle: AppText.desc12,
                  prefixIcon: Icon(Icons.search,
                      size: 18, color: AppColors.textSecondary),
                  filled: true,
                  fillColor: AppColors.bg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (v) => setState(() => _q = v),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? Center(
                      child: CircularProgressIndicator(color: AppColors.accent))
                  : list.isEmpty
                      ? Center(
                          child: Text(AppStrings.t('auth.pickEmpty'),
                              style: AppText.desc12),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: list.length,
                          itemBuilder: (_, i) {
                            final a = list[i];
                            return InkWell(
                              onTap: a.granted
                                  ? null
                                  : () => Navigator.of(context).pop(a),
                              borderRadius: BorderRadius.circular(10),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                child: Row(
                                  children: [
                                    _appIcon(a.icon),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(a.label,
                                              style: AppText.rowLabel,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis),
                                          Text(a.pkg, style: AppText.desc12,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis),
                                        ],
                                      ),
                                    ),
                                    if (a.granted)
                                      Text(AppStrings.t('auth.badgeGranted'),
                                          style: AppText.badge.copyWith(
                                              color: AppColors.accent))
                                    else
                                      Icon(Icons.chevron_right,
                                          size: 20,
                                          color: AppColors.textSecondary),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _appIcon(Uint8List? bytes) {
    if (bytes == null) {
      return Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: AppColors.divider,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.android, size: 18, color: AppColors.textSecondary),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.memory(bytes, width: 32, height: 32, gaplessPlayback: true),
    );
  }
}
