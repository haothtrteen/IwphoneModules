import '../i18n/app_strings.dart';
import 'shell_executor.dart';

/// 设备与系统环境基础信息。
///
/// App 主定位改为 iwphone 框架控制台之后，这里只保留「不需要 root 也能读到的设备元数据」。
/// Root / Magisk 专属字段（rootProvider / rootAppCount / 模块列表 / 启用标记）
/// 一律移除，那些已由 [IwphoneService] 接管。
class SystemInfo {
  const SystemInfo({
    required this.androidVersion,
    required this.buildId,
    required this.kernelVersion,
    required this.abi,
    required this.manufacturer,
    required this.model,
    required this.selinux,
    required this.securityPatch,
  });

  final String androidVersion;
  final String buildId;
  final String kernelVersion;
  final String abi;
  final String manufacturer;
  final String model;
  final String selinux;

  /// Android 安全补丁级别，如 `2023-10-01`。读不到时为空串。
  final String securityPatch;

  /// 界面上「Android 版本」一行显示的文本，如 `14 (UP1A.231105.003)`。
  String get androidDisplay {
    if (androidVersion.isEmpty) return '—';
    if (buildId.isEmpty) return androidVersion;
    return '$androidVersion ($buildId)';
  }

  /// 界面上「设备型号」一行显示的文本。
  String get deviceDisplay {
    final m = manufacturer.trim();
    final d = model.trim();
    if (d.isEmpty) return m.isEmpty ? '—' : m;
    if (m.isEmpty) return d;
    return d.toLowerCase().contains(m.toLowerCase()) ? d : '$m $d';
  }
}

/// 读取真实设备信息（不依赖 root）。
class SystemInfoService {
  SystemInfoService._();

  static final SystemInfoService instance = SystemInfoService._();

  final ShellExecutor _shell = ShellExecutor.instance;

  Future<SystemInfo> load() async {
    final props = await Future.wait<String?>([
      _shell.text('getprop ro.build.version.release'),
      _shell.text('getprop ro.build.display.id'),
      _shell.text('uname -r'),
      _shell.text('getprop ro.product.cpu.abi'),
      _shell.text('getprop ro.product.manufacturer'),
      _shell.text('getprop ro.product.model'),
      _shell.text('getprop ro.build.version.security_patch'),
    ]);

    final selinux = await _readSelinux();

    return SystemInfo(
      androidVersion: props[0] ?? '',
      buildId: props[1] ?? '',
      kernelVersion: props[2] ?? '',
      abi: props[3] ?? '',
      manufacturer: props[4] ?? '',
      model: props[5] ?? '',
      selinux: selinux,
      securityPatch: props[6] ?? '',
    );
  }

  /// SELinux 模式。
  ///
  /// ★ 这个值**只有 shell 权限才读得到**：`getenforce` 和
  ///   `/sys/fs/selinux/enforce` 对普通应用一律 Permission denied，
  ///   `ro.boot.selinux` 在不少 ROM 上又是空的。所以三条都失败时不能笼统
  ///   显示「未知」—— 那会让用户以为设备有问题，其实只是缺权限。
  Future<String> _readSelinux() async {
    final mode = await _shell.text('getenforce');
    if (mode != null) {
      final m = mode.toLowerCase();
      if (m.contains('enforcing')) return AppStrings.t('systemInfo.enforcing');
      if (m.contains('permissive')) return AppStrings.t('systemInfo.permissive');
      if (m.contains('disabled')) return AppStrings.t('systemInfo.disabled');
    }
    final enforce = await _shell.text('cat /sys/fs/selinux/enforce 2>/dev/null');
    if (enforce == '1') return AppStrings.t('systemInfo.enforcing');
    if (enforce == '0') return AppStrings.t('systemInfo.permissive');

    // 最后一条：部分 ROM 会把启动时的模式写进 ro.boot.selinux
    final boot = await _shell.text('getprop ro.boot.selinux');
    if (boot != null && boot.isNotEmpty) {
      final m = boot.toLowerCase();
      if (m.contains('enforcing')) return AppStrings.t('systemInfo.enforcing');
      if (m.contains('permissive')) return AppStrings.t('systemInfo.permissive');
    }
    return AppStrings.t('systemInfo.needShell');
  }
}
