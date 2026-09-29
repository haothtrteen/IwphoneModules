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
  });

  final String androidVersion;
  final String buildId;
  final String kernelVersion;
  final String abi;
  final String manufacturer;
  final String model;
  final String selinux;

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

  static const String _unknown = '未知';

  final ShellExecutor _shell = ShellExecutor.instance;

  Future<SystemInfo> load() async {
    final props = await Future.wait<String?>([
      _shell.text('getprop ro.build.version.release'),
      _shell.text('getprop ro.build.display.id'),
      _shell.text('uname -r'),
      _shell.text('getprop ro.product.cpu.abi'),
      _shell.text('getprop ro.product.manufacturer'),
      _shell.text('getprop ro.product.model'),
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
    );
  }

  /// SELinux 模式：优先 `getenforce`，部分 ROM 没有该命令则回退读 selinuxfs。
  Future<String> _readSelinux() async {
    final mode = await _shell.text('getenforce');
    if (mode != null) {
      final m = mode.toLowerCase();
      if (m.contains('enforcing')) return '强制';
      if (m.contains('permissive')) return '宽容';
      if (m.contains('disabled')) return '已关闭';
    }
    final enforce = await _shell.text('cat /sys/fs/selinux/enforce 2>/dev/null');
    if (enforce == '1') return '强制';
    if (enforce == '0') return '宽容';
    return _unknown;
  }
}
