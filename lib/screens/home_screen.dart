import 'package:flutter/material.dart';

import '../models/iwphone_module.dart';
import '../services/iwphone_service.dart';
import '../services/webui_token.dart';
import '../services/system_info_service.dart';
import '../theme/app_theme.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/webui_token_dialog.dart';

/// 主页 —— 聚焦 iwphone modrunner v3 框架状态。
///
/// 设计稿承载态保留：
/// - 标题栏（22 Bold） + 设置齿轮
/// - 「框架状态卡」圆形 16 + 内边距 20（替代原来的「Shell 状态卡」）
/// - 2×2 统计网格（圆角 12）：模块总数 / 运行中 / SELinux / 架构
/// - 「系统信息卡」保留（Android 版本 / 内核 / 架构 / 设备型号）
///
/// 数据来源：[IwphoneService]（WebUI 优先 / sdcard 兜底） + [SystemInfoService]（设备信息）。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.reloadToken});

  final int reloadToken;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  IwphoneStatus _status = IwphoneStatus.unavailable;
  SystemInfo? _info;
  bool _statusLoading = true;

  /// 设备上是否已设访问密钥。null = 还没查到（不显示引导，避免闪一下）。
  bool? _tokenSet;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadToken != widget.reloadToken) _load();
  }

  Future<void> _load() async {
    // 框架状态 / 设备信息互不依赖，并行取
    final results = await Future.wait([
      IwphoneService.instance.getStatus(),
      SystemInfoService.instance.load(),
      WebuiTokenManager.instance.isSetOnDevice(),
    ]);
    if (!mounted) return;
    setState(() {
      _status = results[0] as IwphoneStatus;
      _info = results[1] as SystemInfo;
      _tokenSet = results[2] as bool;
      _statusLoading = false;
    });
  }

  /// 引导用户设置访问密钥（未设时 WebUI 一律 403，什么都干不了）。
  Future<void> _setToken() async {
    final ok = await showWebuiTokenDialog(context);
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('访问密钥已生效，框架功能已解锁')),
      );
    }
    await _load();
  }

  /// 执行一次框架级操作，统一走「二次确认 → 调用 → 刷新 → 提示」。
  ///
  /// 框架级操作都会中断守护进程，因此不做静默执行，必须先确认。
  Future<void> _frameworkAction({
    required String title,
    required String message,
    required String confirmText,
    required String successText,
    required Future<bool> Function() action,
  }) async {
    final ok = await showConfirmDialog(
      context,
      title: title,
      message: message,
      confirmText: confirmText,
    );
    if (!ok || !mounted) return;

    setState(() => _statusLoading = true);
    final success = await action();
    if (!mounted) return;

    // 操作后 WebUI 可达性可能改变，清掉短缓存再重读
    IwphoneService.instance.invalidate();
    await _load();
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success ? successText : '$title失败：WebUI 不可达或框架未响应',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: AppColors.accent,
      backgroundColor: AppColors.surface,
      onRefresh: _load,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _HomeAppBar(),
            if (_tokenSet == false) ...[
              const SizedBox(height: 16),
              _TokenSetupCard(onTap: _setToken),
            ],
            const SizedBox(height: 16),
            _FrameworkStatusCard(
              status: _status,
              loading: _statusLoading,
              onStop: () => _frameworkAction(
                title: '停止框架',
                message: '将停止 iwphone 守护进程。\n\n'
                    '停止后框架不再轮询触发目录；已在运行的模块不会被停止，'
                    '但无法再通过 App 或触发文件启动新模块。\n\n确定要停止吗？',
                confirmText: '停止',
                successText: '框架已停止',
                action: () => IwphoneService.instance.runnerStop(),
              ),
              onRestart: () => _frameworkAction(
                title: '重启框架',
                message: '将先停止、再启动 iwphone 守护进程。\n\n'
                    '重启会打断当前轮询周期，期间无法响应模块启动请求；'
                    '已在运行的模块不受影响。\n\n确定要重启吗？',
                confirmText: '重启',
                successText: '框架已重启',
                action: () => IwphoneService.instance.runnerRestart(),
              ),
              onSync: () => _frameworkAction(
                title: '同步状态',
                message: '将把执行区状态镜像同步到 /sdcard/iwphone/state/。\n\n'
                    '同步需遍历模块目录，模块较多时可能短暂变慢。\n\n确定要同步吗？',
                confirmText: '同步',
                successText: '同步完成',
                action: () => IwphoneService.instance.triggerSync(),
              ),
            ),
            const SizedBox(height: 16),
            _StatsGrid(status: _status, info: _info, loading: _statusLoading),
            const SizedBox(height: 16),
            _SystemInfoCard(info: _info, status: _status),
          ],
        ),
      ),
    );
  }
}

/// 空值占位。
String _dash(String? value) =>
    (value == null || value.trim().isEmpty) ? '—' : value;

class _HomeAppBar extends StatelessWidget {
  const _HomeAppBar();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(child: Text('Shell Manager', style: AppText.appTitle)),
        SizedBox(
          width: 24,
          height: 24,
          child: Icon(
            Icons.settings_outlined,
            size: 24,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// 框架状态卡：替换原「Shell 状态卡」。
///
/// 显示守护运行态、运行中的模块数，以及 WebUI 地址（便于排查为何连不上）。
class _FrameworkStatusCard extends StatelessWidget {
  const _FrameworkStatusCard({
    required this.status,
    required this.loading,
    required this.onStop,
    required this.onRestart,
    required this.onSync,
  });

  final IwphoneStatus status;
  final bool loading;

  /// 框架控制回调。三个操作都会先弹二次确认，由宿主层负责。
  final VoidCallback onStop;
  final VoidCallback onRestart;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final running = !loading && status.daemonRunning;
    final badgeText = loading ? '检测中' : (running ? '运行中' : '未运行');
    final badgeColor = running ? AppColors.accent : AppColors.textInactive;
    final endpoint = loading
        ? '—'
        : (running ? 'http://127.0.0.1:8537' : '未连接');
    final desc = loading
        ? '正在探测 iwphone 框架…'
        : running
            ? 'iwphone modrunner v3 守护进程已启动'
            : '请先在终端执行：\nadb shell sh /data/local/tmp/iwphone/Main.sh &';

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('iwphone 框架', style: AppText.cardTitle),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.accentDim,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  badgeText,
                  style: AppText.badge.copyWith(color: badgeColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(height: 1, color: AppColors.divider),
          const SizedBox(height: 16),
          _InfoRow(label: 'WebUI 地址', value: endpoint, mono: true),
          const SizedBox(height: 16),
          _InfoRow(label: 'PID', value: _dash(status.daemonPid?.toString())),
          const SizedBox(height: 16),
          // 框架以什么身份运行 —— 免 root 方案最关键的验证点
          _InfoRow(
            label: '运行身份',
            value: _dash(status.daemonUser),
            mono: true,
          ),
          const SizedBox(height: 16),
          Text(desc, style: AppText.body13),
          const SizedBox(height: 16),
          Container(height: 1, color: AppColors.divider),
          const SizedBox(height: 12),
          _FrameworkActions(
            running: running,
            enabled: !loading,
            onStop: onStop,
            onRestart: onRestart,
            onSync: onSync,
          ),
        ],
      ),
    );
  }
}

/// 框架控制按钮行：停止 / 重启 / 同步。
///
/// 三个操作都会改变框架运行态，点击后由宿主层弹二次确认再执行。
/// 未运行时「停止」置灰；「重启」兼具「启动」语义，故保持可用。
class _FrameworkActions extends StatelessWidget {
  const _FrameworkActions({
    required this.running,
    required this.enabled,
    required this.onStop,
    required this.onRestart,
    required this.onSync,
  });

  final bool running;
  final bool enabled;
  final VoidCallback onStop;
  final VoidCallback onRestart;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _ActionButton(
            icon: Icons.stop_rounded,
            label: '停止',
            color: AppColors.iconRed,
            onTap: (enabled && running) ? onStop : null,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ActionButton(
            icon: Icons.restart_alt_rounded,
            label: '重启',
            color: AppColors.iconOrange,
            onTap: enabled ? onRestart : null,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ActionButton(
            icon: Icons.sync_rounded,
            label: '同步',
            color: AppColors.iconBlue,
            onTap: enabled ? onSync : null,
          ),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;

  /// 为 null 表示禁用。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    final fg = disabled ? AppColors.textInactive : color;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: disabled ? AppColors.divider : color.withValues(alpha: 0.45),
          ),
        ),
        child: Column(
          children: [
            Icon(icon, size: 18, color: fg),
            const SizedBox(height: 4),
            Text(label, style: AppText.desc12.copyWith(color: fg)),
          ],
        ),
      ),
    );
  }
}

/// 信息行：左标签 + 右等宽值（与设计稿 13/灰白 对齐）。
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.mono = false});

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: AppText.body13),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            style: mono ? AppText.mono13 : AppText.mono13,
            textAlign: TextAlign.end,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// 统计网格：4 个状态卡（模块总数 / 运行中 / 运行身份 / CPU 架构）
///
/// 第 3 格上一版显示 SELinux。改成「运行身份」的原因：
/// 这套框架是**免 root** 方案，最需要一眼确认的就是「框架到底以什么身份在跑」——
/// `shell` 才说明真的拿到了 shell 权限；显示 `root` 说明权限比预期大，
/// 显示 `app(...)` 说明根本没拿到 shell。SELinux 信息仍然保留，
/// 挪到下面的系统信息卡里。
class _StatsGrid extends StatelessWidget {
  const _StatsGrid({
    required this.status,
    required this.info,
    required this.loading,
  });

  final IwphoneStatus status;
  final SystemInfo? info;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final abi = status.abi.trim().isNotEmpty ? status.abi : (info?.abi ?? '');
    final who = status.daemonUser.trim();
    final whoColor = switch (who) {
      'shell' => AppColors.accent,
      'root' => AppColors.iconOrange,
      '' => AppColors.textInactive,
      _ => AppColors.iconRed, // app(...) 或其它 = 没拿到 shell
    };

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: '模块总数',
                value: loading ? '—' : status.moduleCount.toString(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                label: '运行中',
                value: loading ? '—' : status.runningCount.toString(),
                valueColor: status.daemonRunning
                    ? AppColors.accent
                    : AppColors.textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: '运行身份',
                value: loading ? '—' : _dash(who),
                valueColor: loading ? AppColors.textPrimary : whoColor,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                label: '架构',
                value: _dash(abi),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 统计卡片：高 89 / 圆角 12 / 内边距 16。
///
/// 数值默认 28 / Bold（为「2」「0」这类短数字设计）。
/// 遇到 `arm64-v8a` 这种长文本时按比例縮小，**不换行** ——
/// 卡片内宽有限，硬排会折成两行把卡片撑破。
class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    this.valueColor = AppColors.textPrimary,
  });

  final String label;
  final String value;
  final Color valueColor;

  /// 超过这个字符数就交给 FittedBox 缩放，短值保持原字号。
  static const int _shrinkThreshold = 4;

  @override
  Widget build(BuildContext context) {
    final style = AppText.statValue.copyWith(color: valueColor);
    final text = Text(
      value,
      style: style,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.visible,
    );

    return Container(
      height: 89,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppText.statLabel),
          const SizedBox(height: 8),
          Expanded(
            child: Align(
              alignment: Alignment.bottomLeft,
              child: value.length > _shrinkThreshold
                  // scaleDown：只縮不放，短值仍然吃满 28pt
                  ? FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: text,
                    )
                  : text,
            ),
          ),
        ],
      ),
    );
  }
}

/// 系统信息卡：Android 版本 / 内核 / 架构 / 设备型号。
///
/// 架构优先取 WebUI 的值（同 [_StatsGrid]），其余字段本地读取即可。
class _SystemInfoCard extends StatelessWidget {
  const _SystemInfoCard({required this.info, required this.status});

  final SystemInfo? info;
  final IwphoneStatus status;

  @override
  Widget build(BuildContext context) {
    final data = info;
    final abi = status.abi.trim().isNotEmpty ? status.abi : (data?.abi ?? '');
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('系统信息', style: AppText.infoTitle),
          const SizedBox(height: 16),
          _InfoRow(
            label: 'Android 版本',
            value: data == null ? '—' : data.androidDisplay,
            mono: true,
          ),
          const SizedBox(height: 16),
          _InfoRow(label: '内核版本', value: _dash(data?.kernelVersion), mono: true),
          const SizedBox(height: 16),
          _InfoRow(label: '架构', value: _dash(abi), mono: true),
          const SizedBox(height: 16),
          // SELinux 从统计卡片挪到这里，保留信息但不占一个显眼位置
          _InfoRow(
            label: 'SELinux',
            value: _dash(status.selinux.trim().isNotEmpty
                ? status.selinux
                : data?.selinux),
            mono: true,
          ),
          const SizedBox(height: 16),
          _InfoRow(
            label: '设备型号',
            value: data == null ? '—' : data.deviceDisplay,
            mono: true,
          ),
        ],
      ),
    );
  }
}

/// 未设置访问密钥时的引导卡片。
///
/// 框架的 WebUI 上挂着 shell 权限接口且监听回环口，所以「没设密钥 = 全部拒绝」。
/// 这张卡片就是那条唯一出路 —— 不做成隐晦的设置项，直接摆在主页。
class _TokenSetupCard extends StatelessWidget {
  const _TokenSetupCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.iconOrange.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.iconOrange.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.key_outlined,
                size: 20, color: AppColors.iconOrange),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('先设置访问密钥', style: AppText.rowLabel),
                SizedBox(height: 3),
                Text(
                  '框架的 shell 接口监听在本机回环口，需要一把密钥才能对外开放。'
                  '设好之前，模块列表 / 配置 / 日志都用不了。',
                  style: AppText.desc12,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.iconOrange.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('去设置',
                  style:
                      AppText.desc12.copyWith(color: AppColors.iconOrange)),
            ),
          ),
        ],
      ),
    );
  }
}
