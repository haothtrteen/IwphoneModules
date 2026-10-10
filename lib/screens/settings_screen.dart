import 'package:flutter/material.dart';

import '../services/autostart_service.dart';
import '../services/app_prefs.dart';
import '../i18n/app_strings.dart';
import '../services/iwphone_service.dart';
import '../services/storage_permission_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_switch.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/screen_app_bar.dart';
import 'autostart_screen.dart';
import 'config_screen.dart';
import 'resources_screen.dart';
import 'snapshot_screen.dart';
import '../services/webui_token.dart';
import '../widgets/webui_token_dialog.dart';
import 'terminal_screen.dart';

/// 设置页 —— 1:1 还原设计稿「Settings Screen」
///
/// 结构：标题栏 → 常规 / Shell / 安全 / 关于 四个分组 → 页脚
/// 分组卡片：圆角 16 / 内边距 16 / 内部间距 12。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.autoStart,
    required this.hideApp,
    required this.biometricLock,
    required this.storageStatus,
    required this.onAutoStartChanged,
    required this.onHideAppChanged,
    required this.onBiometricLockChanged,
    required this.onRequestStorage,
  });

  final bool autoStart;
  final bool hideApp;
  final bool biometricLock;

  /// 存储权限（「所有文件访问」）当前状态。
  final StoragePermissionStatus storageStatus;

  final ValueChanged<bool> onAutoStartChanged;
  final ValueChanged<bool> onHideAppChanged;
  final ValueChanged<bool> onBiometricLockChanged;

  /// 点击「授权」时回调，由宿主层发起系统授权流程。
  final VoidCallback onRequestStorage;

  /// 弹出选择器（主题 / 语言共用）。
  ///
  /// 刻意不用 Radio 列表铺在设置页里 —— 设置项一多，三选一的展开会占掉半屏。
  Future<void> _pickOption(
    BuildContext context, {
    required String title,
    required String current,
    required List<({String value, String label})> options,
    required Future<void> Function(String value) onPick,
  }) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Text(title, style: AppText.cardTitle),
            ),
            for (final o in options)
              InkWell(
                onTap: () => Navigator.of(ctx).pop(o.value),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(o.label, style: AppText.rowLabel),
                      ),
                      if (o.value == current)
                        Icon(Icons.check, size: 18, color: AppColors.accent),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
    if (picked != null && picked != current) {
      await onPick(picked);
    }
  }

  String _themeLabel(String mode) => switch (mode) {
        'light' => AppStrings.t('settings.themeLight'),
        'dark' => AppStrings.t('settings.themeDark'),
        _ => AppStrings.t('settings.themeSystem'),
      };

  String _localeLabel(String mode) => switch (mode) {
        'zh' => AppStrings.t('settings.languageZh'),
        'en' => AppStrings.t('settings.languageEn'),
        _ => AppStrings.t('settings.languageSystem'),
      };

  Future<void> _openProjectPage(BuildContext context) async {
    final url = AppStrings.t('about.github');
    final ok = await AutostartService.instance.openUrl(url);
    if (!context.mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${AppStrings.t('settings.linkFailed')}\n$url')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ScreenAppBar(title: AppStrings.t('settings.title')),
          const SizedBox(height: 16),
          // 外观：主题 + 语言
          //
          // 主题支持「跟随系统」—— 系统切深色时 App 跟着切，
          // 这是现在的默认值，也是多数人期望的行为。
          _SettingsSection(
            title: AppStrings.t('settings.section.appearance'),
            children: [
              _NavRow(
                label: AppStrings.t('settings.theme'),
                hint: _themeLabel(AppPrefs.instance.themeMode),
                onTap: () => _pickOption(
                  context,
                  title: AppStrings.t('settings.theme'),
                  current: AppPrefs.instance.themeMode,
                  options: [
                    (value: 'system', label: AppStrings.t('settings.themeSystem')),
                    (value: 'light', label: AppStrings.t('settings.themeLight')),
                    (value: 'dark', label: AppStrings.t('settings.themeDark')),
                  ],
                  onPick: (v) => AppPrefs.instance.setThemeMode(v),
                ),
              ),
              _NavRow(
                label: AppStrings.t('settings.language'),
                hint: _localeLabel(AppPrefs.instance.locale),
                onTap: () => _pickOption(
                  context,
                  title: AppStrings.t('settings.language'),
                  current: AppPrefs.instance.locale,
                  options: [
                    (value: 'system', label: AppStrings.t('settings.languageSystem')),
                    (value: 'zh', label: AppStrings.t('settings.languageZh')),
                    (value: 'en', label: AppStrings.t('settings.languageEn')),
                  ],
                  onPick: (v) => AppPrefs.instance.setLocale(v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Shell
          _SettingsSection(
            title: 'Shell',
            children: [
              _ToggleRow(
                label: AppStrings.t('settings.autostart'),
                value: autoStart,
                onChanged: (v) => _toggleAutostart(context, v, onAutoStartChanged),
              ),
              _NavRow(
                label: AppStrings.t('settings.autostartSettings'),
                hint: AppStrings.t('settings.autostartHint'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AutostartScreen()),
                ),
              ),
              _ValueRow(label: AppStrings.t('settings.mountNs'), value: AppStrings.t('settings.mountNsValue')),
            ],
          ),
          const SizedBox(height: 16),
          // 框架
          _SettingsSection(
            title: AppStrings.t('settings.section.framework'),
            children: [
              _NavRow(
                label: AppStrings.t('settings.frameworkConfig'),
                hint: AppStrings.t('settings.frameworkConfigHint'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ConfigScreen(reloadToken: 0),
                  ),
                ),
              ),
              _NavRow(
                label: AppStrings.t('settings.terminal'),
                hint: AppStrings.t('settings.terminalHint'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const TerminalScreen()),
                ),
              ),
              _NavRow(
                label: AppStrings.t('settings.resources'),
                hint: AppStrings.t('settings.resourcesHint'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ResourcesScreen()),
                ),
              ),
              _NavRow(
                label: AppStrings.t('settings.webuiToken'),
                hint: AppStrings.t('settings.webuiTokenHint'),
                onTap: () async {
                  final cur = await WebuiTokenManager.instance.localToken();
                  if (!context.mounted) return;
                  final ok =
                      await showWebuiTokenDialog(context, current: cur);
                  if (ok && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('访问密钥已更新')),
                    );
                  }
                },
              ),
              _NavRow(
                label: AppStrings.t('settings.snapshots'),
                hint: AppStrings.t('settings.snapshotsHint'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SnapshotScreen()),
                ),
              ),
              _NavRow(
                label: AppStrings.t('settings.uninstallFramework'),
                hint: AppStrings.t('settings.uninstallFrameworkHint'),
                danger: true,
                onTap: () => confirmFrameworkUninstall(context),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 权限
          _SettingsSection(
            title: AppStrings.t('settings.section.permissions'),
            children: [
              _PermissionRow(
                label: AppStrings.t('settings.storageAllFiles'),
                status: storageStatus,
                onRequest: onRequestStorage,
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 安全
          _SettingsSection(
            title: AppStrings.t('settings.section.security'),
            children: [
              _ToggleRow(label: AppStrings.t('settings.hideApp'), value: hideApp, onChanged: onHideAppChanged),
              _ToggleRow(label: AppStrings.t('settings.biometric'), value: biometricLock, onChanged: onBiometricLockChanged),
            ],
          ),
          const SizedBox(height: 16),
          // 关于
          _SettingsSection(
            title: AppStrings.t('settings.section.about'),
            children: [
              _ValueRow(
                label: AppStrings.t('settings.version'),
                value: '1.2.3',
                mono: true,
              ),
              _NavRow(
                label: AppStrings.t('settings.projectHome'),
                hint: 'haothtrteen/IwphoneModules',
                onTap: () => _openProjectPage(context),
              ),
              _ValueRow(label: AppStrings.t('settings.author'), value: 'haothtrteen'),
              _ValueRow(
                label: 'License',
                value: AppStrings.t('about.license'),
                mono: true,
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 页脚
          Text('Shell Manager v1.2.3', style: AppText.footer, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Text('Powered by Flutter', style: AppText.footerSub, textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

/// 切换「开机自启」。
///
/// 首次开启时必须先完成一次性配置（与设备配对 + 固定 ADB 端口），
/// 否则开关打开也只是空转 —— 重启后既连不上也没端口可连，
/// 而且失败是静默的。所以这里直接把人送去配置页，而不是留个假开关。
///
/// 配置没做完就返回时**保持关闭**，并明确告知原因。
Future<void> _toggleAutostart(
  BuildContext context,
  bool want,
  ValueChanged<bool> onChanged,
) async {
  if (want) {
    var st = await AutostartService.instance.status();
    if (!context.mounted) return;

    if (!st.provisioned) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const AutostartScreen()),
      );
      if (!context.mounted) return;

      // 回来复查：用户可能在配置页里完成了配对
      st = await AutostartService.instance.status();
      if (!st.provisioned) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('还未完成设备配对，开机自启无法生效，开关保持关闭'),
          ),
        );
        return;
      }
    }
  }
  onChanged(want);
}

/// 设置分组卡片：圆角 16 / 内边距 16 / 内部间距 12
class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

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
          Text(title, style: AppText.sectionTitle),
          const SizedBox(height: 12),
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// 开关行：左侧标签（15 / 白）+ 右侧开关
class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label, style: AppText.rowLabel)),
        AppSwitch(value: value, onChanged: onChanged),
      ],
    );
  }
}

/// 数值行：左侧标签（15 / 白）+ 右侧值（14 / 灰，可等宽）
class _ValueRow extends StatelessWidget {
  const _ValueRow({required this.label, required this.value, this.mono = false});

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label, style: AppText.rowLabel)),
        Text(value, style: mono ? AppText.monoValue14 : AppText.value14),
      ],
    );
  }
}

/// 权限行：左侧标签 + 状态徽标。
///
/// 未授权时整行可点，右侧显示「去授权」；已授权时只显示状态、不可点。
/// 「所有文件访问」在 Android 11+ 只能由用户在系统设置页手动开启，
/// 所以这里只负责把用户送过去，结果等回到 App 后再查询。
class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.label,
    required this.status,
    required this.onRequest,
  });

  final String label;
  final StoragePermissionStatus status;
  final VoidCallback onRequest;

  bool get _editable => status == StoragePermissionStatus.denied;

  String get _statusText {
    switch (status) {
      case StoragePermissionStatus.granted:
        return '已授权';
      case StoragePermissionStatus.notRequired:
        return '无需授权';
      case StoragePermissionStatus.denied:
        return '去授权';
    }
  }

  @override
  Widget build(BuildContext context) {
    final granted = status == StoragePermissionStatus.granted;

    return InkWell(
      onTap: _editable ? onRequest : null,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(child: Text(label, style: AppText.rowLabel)),
            Text(
              _statusText,
              style: AppText.value14.copyWith(
                color: granted ? AppColors.accent : AppColors.textSecondary,
              ),
            ),
            if (_editable) ...[
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: AppColors.textSecondary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 可跳转的设置行：标签 + 副标题提示 + 右箭头。
///
/// [danger] 为 true 时标签用警示色（用于卸载这类不可撤销操作）。
class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.label,
    required this.hint,
    required this.onTap,
    this.danger = false,
  });

  final String label;
  final String hint;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final labelColor = danger ? AppColors.iconRed : null;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: labelColor == null
                        ? AppText.rowLabel
                        : AppText.rowLabel.copyWith(color: labelColor),
                  ),
                  const SizedBox(height: 2),
                  Text(hint, style: AppText.desc12),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                size: 20, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// 卸载框架（最高危）：二次确认 → 调用 → 结果弹窗。
///
/// 后端是**延迟 3 秒**执行的 —— 因为 uninstall.sh 会把 WebUI 自己停掉，
/// 同步执行的话响应根本发不回来。所以这里拿到 ok 只代表「任务已排队」。
Future<void> confirmFrameworkUninstall(BuildContext context) async {
  final ok = await showConfirmDialog(
    context,
    title: AppStrings.t('settings.uninstallTitle'),
    message: '⚠️ 最高危操作，不可撤销。\n\n'
        '将删除：\n'
        '· 运行时目录（全部已装模块、锁、触发文件）\n'
        '· 日志目录与状态镜像\n\n'
        '框架源文件目录会保留，可用一键启动脚本重新安装。\n'
        '卸载后 App 将无法连接框架。\n\n确定要继续吗？',
    confirmText: '卸载框架',
  );
  if (!ok || !context.mounted) return;

  final res = await IwphoneService.instance.uninstallFramework();
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(res.ok ? '卸载已启动' : '卸载失败', style: AppText.cardTitle),
      content: Text(res.msg, style: AppText.body13),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text('知道了',
              style: AppText.rowLabel.copyWith(color: AppColors.accent)),
        ),
      ],
    ),
  );
}
