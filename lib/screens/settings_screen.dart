import 'package:flutter/material.dart';

import '../services/autostart_service.dart';
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
    required this.darkTheme,
    required this.autoStart,
    required this.hideApp,
    required this.biometricLock,
    required this.storageStatus,
    required this.onDarkThemeChanged,
    required this.onAutoStartChanged,
    required this.onHideAppChanged,
    required this.onBiometricLockChanged,
    required this.onRequestStorage,
  });

  final bool darkTheme;
  final bool autoStart;
  final bool hideApp;
  final bool biometricLock;

  /// 存储权限（「所有文件访问」）当前状态。
  final StoragePermissionStatus storageStatus;

  final ValueChanged<bool> onDarkThemeChanged;
  final ValueChanged<bool> onAutoStartChanged;
  final ValueChanged<bool> onHideAppChanged;
  final ValueChanged<bool> onBiometricLockChanged;

  /// 点击「授权」时回调，由宿主层发起系统授权流程。
  final VoidCallback onRequestStorage;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ScreenAppBar(title: '设置'),
          const SizedBox(height: 16),
          // 常规
          _SettingsSection(
            title: '常规',
            children: [
              _ToggleRow(label: '深色主题', value: darkTheme, onChanged: onDarkThemeChanged),
              _ValueRow(label: '语言', value: '简体中文'),
            ],
          ),
          const SizedBox(height: 16),
          // Shell
          _SettingsSection(
            title: 'Shell',
            children: [
              _ToggleRow(
                label: '开机自启',
                value: autoStart,
                onChanged: (v) => _toggleAutostart(context, v, onAutoStartChanged),
              ),
              _NavRow(
                label: '开机自启设置',
                hint: '配对设备、固定端口、查看上次执行结果',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AutostartScreen()),
                ),
              ),
              _ValueRow(label: '挂载命名空间', value: '全局'),
            ],
          ),
          const SizedBox(height: 16),
          // 框架
          _SettingsSection(
            title: '框架',
            children: [
              _NavRow(
                label: '框架配置',
                hint: '轮询间隔 / 超时 / 沙箱 / 访问令牌',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ConfigScreen(reloadToken: 0),
                  ),
                ),
              ),
              _NavRow(
                label: '内置终端',
                hint: '执行 shell 命令、反查文件归属',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const TerminalScreen()),
                ),
              ),
              _NavRow(
                label: '资源占用',
                hint: '各模块占用的系统资源与冲突记录',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ResourcesScreen()),
                ),
              ),
              _NavRow(
                label: '访问密钥',
                hint: '框架 shell 接口的密钥，可修改',
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
                label: '历史快照',
                hint: '各模块改动过的设置原值，可一键还原',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SnapshotScreen()),
                ),
              ),
              _NavRow(
                label: '卸载框架',
                hint: '删除全部模块、锁与日志（源文件保留）',
                danger: true,
                onTap: () => confirmFrameworkUninstall(context),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 权限
          _SettingsSection(
            title: '权限',
            children: [
              _PermissionRow(
                label: '所有文件访问',
                status: storageStatus,
                onRequest: onRequestStorage,
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 安全
          _SettingsSection(
            title: '安全',
            children: [
              _ToggleRow(label: '隐藏应用', value: hideApp, onChanged: onHideAppChanged),
              _ToggleRow(label: '生物识别锁', value: biometricLock, onChanged: onBiometricLockChanged),
            ],
          ),
          const SizedBox(height: 16),
          // 关于
          _SettingsSection(
            title: '关于',
            children: const [
              _ValueRow(label: '版本', value: '1.2.3', mono: true),
              _ValueRow(label: '源代码', value: 'github.com/shell-mgr', mono: true),
              _ValueRow(label: '更新通道', value: '稳定版'),
            ],
          ),
          const SizedBox(height: 16),
          // 页脚
          const Text('Shell Manager v1.2.3', style: AppText.footer, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          const Text('Powered by Flutter', style: AppText.footerSub, textAlign: TextAlign.center),
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
              const Icon(
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
            const Icon(Icons.chevron_right,
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
    title: '卸载 iwphone 框架',
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
