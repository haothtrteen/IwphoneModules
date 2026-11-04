import 'package:flutter/material.dart';

import '../app_info.dart';
import '../i18n/app_strings.dart';
import '../services/autostart_service.dart';
import '../services/system_info_service.dart';
import '../theme/app_theme.dart';
import 'framework_install_screen.dart';

/// 框架未安装时的**唯一界面**（参照 KernelSU / Magisk 的首页）。
///
/// 安装状态是整个 App 的前置条件：框架不在，模块列表、日志、启停按钮全都
/// 没有数据来源，继续显示只会点出各种无意义报错。所以这一页只做三件事：
///   1. 说明没装，并给出唯一的安装入口
///   2. 把设备真实信息摊开（用户排障时第一眼看的就是这些）
///   3. 放项目与作者信息，避免整页下半截空荡荡
///
/// 真正的安装动作在 [FrameworkInstallScreen] 里，这页只负责"看见状态"。
class FrameworkMissingScreen extends StatefulWidget {
  const FrameworkMissingScreen({
    super.key,
    required this.onInstalled,
    required this.onRefresh,
  });

  /// 安装成功后回调（上层据此重新探测并放行主界面）。
  final VoidCallback onInstalled;

  /// 手动刷新状态。
  final VoidCallback onRefresh;

  @override
  State<FrameworkMissingScreen> createState() => _FrameworkMissingScreenState();
}

class _FrameworkMissingScreenState extends State<FrameworkMissingScreen> {
  SystemInfo? _info;
  bool _paired = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      SystemInfoService.instance.load(),
      AutostartService.instance.status(),
    ]);
    if (!mounted) return;
    setState(() {
      _info = results[0] as SystemInfo;
      _paired = (results[1] as AutostartStatus).provisioned;
    });
  }

  Future<void> _openInstall() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FrameworkInstallScreen(
          onInstalled: () {
            widget.onInstalled();
          },
        ),
      ),
    );
    // 从安装页回来：无论装没装成，状态都重新读一次
    if (mounted) {
      await _load();
      widget.onRefresh();
    }
  }

  Future<void> _openUrl(String url) async {
    final ok = await AutostartService.instance.openUrl(url);
    if (!mounted || ok) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${AppStrings.t('settings.linkFailed')}\n$url'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: RefreshIndicator(
          color: AppColors.accent,
          backgroundColor: AppColors.surface,
          onRefresh: () async {
            await _load();
            widget.onRefresh();
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 28),
            children: [
              Text(
                'Shell Manager',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 20),
              _statusCard(),
              const SizedBox(height: 12),
              _infoCard(),
              const SizedBox(height: 12),
              _aboutCard(),
            ],
          ),
        ),
      ),
    );
  }

  /// 状态卡片 —— 整块可点，就是安装入口。
  Widget _statusCard() {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _openInstall,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 24,
                color: AppColors.textSecondary,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppStrings.t('missing.notInstalled'),
                      style: AppText.rowLabel.copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _paired
                          ? AppStrings.t('missing.tapToInstall')
                          : AppStrings.t('missing.notPairedThenInstall'),
                      style: AppText.desc12,
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: 20, color: AppColors.textInactive),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoCard() {
    final info = _info;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          _InfoRow(
            icon: Icons.tag_rounded,
            label: AppStrings.t('missing.managerVersion'),
            value: 'v$kAppVersion',
          ),
          _InfoRow(
            icon: Icons.memory_rounded,
            label: AppStrings.t('missing.kernelVersion'),
            value: info?.kernelVersion ?? '—',
          ),
          _InfoRow(
            icon: Icons.smartphone_rounded,
            label: AppStrings.t('missing.deviceModel'),
            value: info?.deviceDisplay ?? '—',
          ),
          _InfoRow(
            icon: Icons.android_rounded,
            label: AppStrings.t('missing.systemVersion'),
            value: info?.androidDisplay ?? '—',
          ),
          _InfoRow(
            icon: Icons.developer_board_rounded,
            label: AppStrings.t('missing.arch'),
            value: info?.abi ?? '—',
          ),
          _InfoRow(
            icon: Icons.update_rounded,
            label: AppStrings.t('missing.securityPatch'),
            value: (info?.securityPatch.isNotEmpty ?? false)
                ? info!.securityPatch
                : '—',
          ),
          _InfoRow(
            icon: Icons.shield_outlined,
            label: AppStrings.t('missing.selinux'),
            value: info?.selinux ?? '—',
            last: true,
          ),
        ],
      ),
    );
  }

  Widget _aboutCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          _LinkRow(
            label: AppStrings.t('settings.projectHome'),
            value: 'IwphoneModules',
            onTap: () => _openUrl(AppStrings.t('about.github')),
          ),
          _LinkRow(
            label: AppStrings.t('settings.author'),
            value: 'haothtrteen',
            onTap: () => _openUrl('https://github.com/haothtrteen'),
          ),
          _InfoRow(
            icon: Icons.verified_user_outlined,
            label: AppStrings.t('missing.license'),
            value: AppStrings.t('about.license'),
            last: true,
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.last = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(bottom: BorderSide(color: AppColors.divider, width: 1)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppColors.textSecondary),
          const SizedBox(width: 14),
          // ★ 标签按内容取宽，剩余宽度全给值。
          //   原来标签用 Expanded 会把空间吃满，长值（内核版本、系统版本）
          //   被挤成一两行再省略号，看起来像数据不全。
          Text(label, style: AppText.rowLabel.copyWith(fontSize: 15)),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              value,
              style: AppText.desc12.copyWith(color: AppColors.textSecondary),
              textAlign: TextAlign.right,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// 可点击的链接行（项目主页 / 作者）。
class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.divider, width: 1)),
        ),
        child: Row(
          children: [
            Icon(Icons.link_rounded,
                size: 20, color: AppColors.textSecondary),
            const SizedBox(width: 14),
            Text(label, style: AppText.rowLabel.copyWith(fontSize: 15)),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                value,
                style: AppText.desc12.copyWith(color: AppColors.accent),
                textAlign: TextAlign.right,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.north_east_rounded,
                size: 14, color: AppColors.textInactive),
          ],
        ),
      ),
    );
  }
}
