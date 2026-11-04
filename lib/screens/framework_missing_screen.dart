import 'package:flutter/material.dart';

import '../app_info.dart';
import '../i18n/app_strings.dart';
import '../services/autostart_service.dart';
import '../services/system_info_service.dart';
import '../theme/app_theme.dart';
import '../widgets/confirm_dialog.dart';

/// 框架未安装时的**唯一界面**。
///
/// 借鉴 KernelSU / Magisk 的做法：安装状态是整个 App 的前置条件 ——
/// 框架不在，模块列表、日志、启停按钮全都没有数据来源，继续显示这些界面
/// 只会产生一堆「看着能点、点了没反应 / 报错」的逻辑混乱。
///
/// 所以这里只做三件事：说明没装、给一个安装入口、展示设备基本信息。
/// 部署成功后由上层重新探测，四页主界面才会出现。
class FrameworkMissingScreen extends StatefulWidget {
  const FrameworkMissingScreen({
    super.key,
    required this.onInstalled,
    required this.onNeedPairing,
    required this.onRefresh,
  });

  /// 部署成功后回调（上层据此重新探测并切到主界面）。
  final VoidCallback onInstalled;

  /// 未配对时回调（上层负责把用户送去配对）。
  final VoidCallback onNeedPairing;

  /// 手动刷新状态。
  final VoidCallback onRefresh;

  @override
  State<FrameworkMissingScreen> createState() => _FrameworkMissingScreenState();
}

class _FrameworkMissingScreenState extends State<FrameworkMissingScreen> {
  SystemInfo? _info;
  bool _deploying = false;
  bool _needPairing = false;

  @override
  void initState() {
    super.initState();
    _loadInfo();
    _checkPairing();
  }

  Future<void> _loadInfo() async {
    final info = await SystemInfoService.instance.load();
    if (!mounted) return;
    setState(() => _info = info);
  }

  Future<void> _checkPairing() async {
    final st = await AutostartService.instance.status();
    if (!mounted) return;
    setState(() => _needPairing = !st.provisioned);
  }

  Future<void> _deploy() async {
    if (_deploying) return;

    if (_needPairing) {
      widget.onNeedPairing();
      return;
    }

    final ok = await showConfirmDialog(
      context,
      title: AppStrings.t('missing.deployTitle'),
      message: AppStrings.t('missing.deployMessage'),
      confirmText: AppStrings.t('missing.tapToInstall'),
    );
    if (ok != true || !mounted) return;

    setState(() => _deploying = true);
    final r = await AutostartService.instance.deployFramework();
    if (!mounted) return;
    setState(() => _deploying = false);

    if (r.ok) {
      // 给框架文件一点落盘时间，再让上层重新探测
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      widget.onInstalled();
    } else {
      // 未配对 / 连不上时，原生侧会在这里给出原因
      final pairing = r.msg.contains('配对');
      if (pairing) setState(() => _needPairing = true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${AppStrings.t('missing.deployFail')}${r.msg}'),
        backgroundColor: AppColors.iconRed,
      ));
    }
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
            await _loadInfo();
            await _checkPairing();
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
              const SizedBox(height: 16),
              Text(
                AppStrings.t('missing.hint'),
                style: AppText.desc12,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 状态卡片 —— 整块可点，就是安装入口（KernelSU 的「未安装 / 点击安装」）。
  Widget _statusCard() {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _deploying ? null : _deploy,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              if (_deploying)
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  _needPairing
                      ? Icons.link_off_rounded
                      : Icons.error_outline_rounded,
                  size: 24,
                  color: AppColors.textSecondary,
                ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _needPairing
                          ? AppStrings.t('missing.notPaired')
                          : AppStrings.t('missing.notInstalled'),
                      style: AppText.rowLabel.copyWith(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _deploying
                          ? AppStrings.t('missing.deploying')
                          : (_needPairing
                              ? AppStrings.t('missing.tapToPair')
                              : AppStrings.t('missing.tapToInstall')),
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
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
            icon: Icons.memory_rounded,
            label: AppStrings.t('missing.arch'),
            value: info?.abi ?? '—',
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
          Expanded(
            child: Text(
              label,
              style: AppText.rowLabel.copyWith(fontSize: 15),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              style: AppText.desc12,
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
