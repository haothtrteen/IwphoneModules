import 'package:flutter/material.dart';

import '../services/autostart_service.dart';
import '../services/app_prefs.dart';
import '../i18n/app_strings.dart';
import '../services/storage_permission_service.dart';
import '../theme/app_theme.dart';
import '../widgets/framework_uninstall.dart';
import '../widgets/screen_app_bar.dart';
import '../widgets/settings_rows.dart';
import 'autostart_screen.dart';
import 'config_screen.dart';
import 'tools_screen.dart';
import '../services/webui_token.dart';
import '../widgets/webui_token_dialog.dart';

/// 设置页 —— 1:1 还原设计稿「Settings Screen」
///
/// 结构：标题栏 → 常规 / Shell / 安全 / 关于 四个分组 → 页脚
/// 分组卡片：圆角 16 / 内边距 16 / 内部间距 12。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.autoStart,
    required this.storageStatus,
    required this.onAutoStartChanged,
    required this.onRequestStorage,
  });

  final bool autoStart;

  /// 存储权限（「所有文件访问」）当前状态。
  final StoragePermissionStatus storageStatus;

  final ValueChanged<bool> onAutoStartChanged;

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
          // ── 外观 ──
          SettingsSection(
            title: AppStrings.t('settings.section.appearance'),
            children: [
              NavRow(
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
              NavRow(
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

          // ── Shell 与框架 ──
          //
          // 原来拆成「Shell」和「框架」两组，但这两者的边界对用户没有意义：
          // 开机自启、框架配置、访问密钥都是「框架的事」。合并后少一个分组标题。
          SettingsSection(
            title: AppStrings.t('settings.section.shellFramework'),
            children: [
              ToggleRow(
                label: AppStrings.t('settings.autostart'),
                value: autoStart,
                onChanged: (v) => _toggleAutostart(context, v, onAutoStartChanged),
              ),
              NavRow(
                label: AppStrings.t('settings.autostartSettings'),
                hint: AppStrings.t('settings.autostartHint'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AutostartScreen()),
                ),
              ),
              NavRow(
                label: AppStrings.t('settings.frameworkConfig'),
                hint: AppStrings.t('settings.frameworkConfigHint'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ConfigScreen(reloadToken: 0),
                  ),
                ),
              ),
              NavRow(
                label: AppStrings.t('settings.webuiToken'),
                hint: AppStrings.t('settings.webuiTokenHint'),
                onTap: () async {
                  final cur = await WebuiTokenManager.instance.localToken();
                  if (!context.mounted) return;
                  final ok = await showWebuiTokenDialog(context, current: cur);
                  if (ok && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(AppStrings.t('settings.tokenUpdated')),
                      ),
                    );
                  }
                },
              ),
              // 低频工具收进子页 —— 三个都是「偶尔用一次」，
              // 平铺在这里只会让设置页变长。
              NavRow(
                label: AppStrings.t('settings.tools'),
                hint: AppStrings.t('settings.toolsHint'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ToolsScreen()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── 权限 ──
          SettingsSection(
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

          // ── 关于 ──
          SettingsSection(
            title: AppStrings.t('settings.section.about'),
            children: [
              ValueRow(
                label: AppStrings.t('settings.version'),
                value: '1.2.3',
                mono: true,
              ),
              NavRow(
                label: AppStrings.t('settings.projectHome'),
                hint: 'haothtrteen/IwphoneModules',
                onTap: () => _openProjectPage(context),
              ),
              ValueRow(
                label: AppStrings.t('settings.author'),
                value: 'haothtrteen',
              ),
              ValueRow(
                label: 'License',
                value: AppStrings.t('about.license'),
                mono: true,
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── 危险操作 ──
          //
          // 单独成组而不是塞进「关于」：破坏性操作不该混在信息行里被顺手点到。
          SettingsSection(
            title: AppStrings.t('settings.section.danger'),
            children: [
              NavRow(
                label: AppStrings.t('settings.uninstallFramework'),
                hint: AppStrings.t('settings.uninstallFrameworkHint'),
                danger: true,
                onTap: () => confirmFrameworkUninstall(context),
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
          SnackBar(
            content: Text(AppStrings.t('settings.autostartNeedsPair')),
          ),
        );
        return;
      }
    }
  }
  onChanged(want);
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
        return AppStrings.t('settings.permissionGranted');
      case StoragePermissionStatus.notRequired:
        return AppStrings.t('settings.permissionNotRequired');
      case StoragePermissionStatus.denied:
        return AppStrings.t('settings.permissionGrant');
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



