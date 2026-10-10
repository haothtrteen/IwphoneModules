import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
import '../theme/app_theme.dart';
import '../widgets/back_icon_button.dart';
import '../widgets/screen_app_bar.dart';
import '../widgets/settings_rows.dart';
import 'resources_screen.dart';
import 'snapshot_screen.dart';
import 'terminal_screen.dart';

/// 框架工具 —— 把低频的三个工具从设置页收进来。
///
/// 为什么单独一页：这三个都是「偶尔用一次」（查日志、看资源、还原设置），
/// 平铺在设置页里会把真正常用的项（主题、开机自启、访问密钥）淹掉。
///
/// 注意：这里是 `Navigator.push` 打开的独立页面，
/// **必须自带 Scaffold**（InkWell / TextButton 需要 Material 祖先），返回用 BackIconButton。
class ToolsScreen extends StatelessWidget {
  const ToolsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const BackIconButton(),
                  const SizedBox(width: 4),
                  Expanded(child: ScreenAppBar(title: AppStrings.t('tools.title'))),
                ],
              ),
              const SizedBox(height: 16),
              SettingsSection(
                title: AppStrings.t('tools.section.diagnostics'),
                children: [
                  NavRow(
                    label: AppStrings.t('settings.terminal'),
                    hint: AppStrings.t('settings.terminalHint'),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const TerminalScreen()),
                    ),
                  ),
                  NavRow(
                    label: AppStrings.t('settings.resources'),
                    hint: AppStrings.t('settings.resourcesHint'),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const ResourcesScreen()),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SettingsSection(
                title: AppStrings.t('tools.section.data'),
                children: [
                  NavRow(
                    label: AppStrings.t('settings.snapshots'),
                    hint: AppStrings.t('settings.snapshotsHint'),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SnapshotScreen()),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
