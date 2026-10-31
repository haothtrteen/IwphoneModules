import '../i18n/app_strings.dart';

/// iwphone modrunner v3 模块数据。
///
/// 框架对外有两个数据来源：
/// 1. WebUI HTTP API  →  JSON 字段 `name/title/version/author/description/running/pid/has_main`
/// 2. sdcard 状态镜像 →  iwphone.prop 文本，字段 `PackageName/version/author/description`
///
/// 目录名是唯一 id，UI 始终按 id 稳定映射图标/颜色。
class IwphoneModule {
  const IwphoneModule({
    required this.id,
    required this.title,
    required this.version,
    required this.author,
    required this.description,
    required this.running,
    required this.hasMain,
    this.hasConfig = false,
    this.hasAction = false,
    this.hasWebroot = false,
    this.hasSnapshot = false,
    this.compatVerdict = '',
    this.compatReasons = '',
    this.pid,
    this.exclusive = '',
    this.exclusiveGroup = '',
    this.resources = const [],
    this.blockedBy = const [],
    this.hasConflict = false,
  });

  /// 模块目录名（同时也是框架内部唯一标识）。
  final String id;

  /// 模块在 iwphone.prop 里 `PackageName=`，缺失时回退为 id。
  final String title;

  /// 框架 .iwp 一般写 `version=`，直接读。
  final String version;

  final String author;
  final String description;

  /// WebUI `running` 字段为 true 时表示已被守护调起（或 mod_run 启动）。
  final bool running;

  /// WebUI `has_main` 字段：该模块是否包含 main.sh（可执行模块）。
  /// 资源型模块（仅供其他脚本调用的工具）会是 false。
  final bool hasMain;

  /// 模块是否声明了可配置项（后端检测 config.prop 是否存在）。
  final bool hasConfig;

  /// 是否有 action.sh（Magisk/KernelSU/AxManager 式「动作」按钮）。
  final bool hasAction;

  /// 是否有 webroot/（KernelSU 式每模块 WebUI）。
  final bool hasWebroot;

  /// 兼容层预检判定（仅 Magisk/KernelSU/AxManager 式模块有）：
  /// ok=预计兼容 / blocked=需要 root / unknown=无法自动判断。
  /// 是否有写前快照（可一键把系统资源还原到模块动手之前）。
  final bool hasSnapshot;

  final String compatVerdict;

  /// 预检的原因说明。
  final String compatReasons;

  /// 运行中的进程 PID。模块未运行时为 null。
  final int? pid;

  /// iwphone.prop 里 `exclusive=` 声明的独占资源（逗号分隔）。
  final String exclusive;

  /// `exclusive.group=` 声明的粗粒度分组。
  final String exclusiveGroup;

  /// 该模块实际写过的资源（来自框架 state/owners）。
  final List<String> resources;

  /// 因资源冲突而占用同一资源的其他模块。
  final List<String> blockedBy;

  /// 是否存在资源冲突（blockedBy 非空）。
  final bool hasConflict;

  /// 显示用版本号：补 `v` 前缀，与原 Modules 卡片视觉对齐。
  String get displayVersion {
    final v = version.trim();
    if (v.isEmpty) return '—';
    return v.startsWith('v') ? v : 'v$v';
  }

  /// 是否声明了独占资源（用于 UI 决定是否显示资源标签）。
  bool get hasExclusive => exclusive.trim().isNotEmpty || exclusiveGroup.trim().isNotEmpty;

  /// 是否受资源仲裁约束（有声明 或 实际碰过资源）。
  bool get isResourceAware => hasExclusive || resources.isNotEmpty;

  /// 仅替换运行相关字段（toggle 复用）。
  IwphoneModule copyWith({bool? running, int? pid}) {
    return IwphoneModule(
      id: id,
      title: title,
      version: version,
      author: author,
      description: description,
      running: running ?? this.running,
      hasMain: hasMain,
      pid: pid ?? this.pid,
      exclusive: exclusive,
      exclusiveGroup: exclusiveGroup,
      resources: resources,
      blockedBy: blockedBy,
      hasConflict: hasConflict,
    );
  }

  /// 解析 WebUI 返回的 JSON 对象。
  ///
  /// 服务端字段可能缺失（老版本、不规范的 .iwp），所以每个字段都做宽容解析。
  factory IwphoneModule.fromJson(Map<String, dynamic> json) {
    final name = (json['name'] as String?)?.trim() ?? '';
    final title = (json['title'] as String?)?.trim();
    return IwphoneModule(
      id: name,
      title: (title == null || title.isEmpty) ? name : title,
      version: (json['version'] as String?) ?? '',
      author: (json['author'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
      running: json['running'] == true,
      hasMain: json['has_main'] != false, // 缺省视为有 main.sh（多数模块如此）
      pid: (json['pid'] is num) ? (json['pid'] as num).toInt() : null,
      exclusive: (json['exclusive'] as String?) ?? '',
      exclusiveGroup: (json['exclusive_group'] as String?) ?? '',
      resources: _strList(json['resources']),
      blockedBy: _strList(json['blocked_by']),
      hasConflict: json['has_conflict'] == true,
      hasConfig: json['has_config'] == true,
      hasAction: json['has_action'] == true,
      hasWebroot: json['has_webroot'] == true,
      hasSnapshot: json['has_snapshot'] == true,
      compatVerdict: (json['compatVerdict'] as String?) ?? '',
      compatReasons: (json['compatReasons'] as String?) ?? '',
    );
  }

  static List<String> _strList(dynamic v) {
    if (v is List) return v.whereType<String>().toList();
    return const [];
  }

  /// 解析 sdcard 镜像里的 `iwphone.prop` 文件内容。
  ///
  /// iwphone.prop 字段约定（来自 mod_install.sh 注释）：
  ///   PackageName/version/author/description
  /// 与 Magisk `module.prop` 的 `name=` 不同，这里是 `PackageName=`；
  /// 要严格按 iwphone 走，不能混用 `parseModules`。
  factory IwphoneModule.fromProp(String dirName, String propText) {
    final props = <String, String>{};
    for (final line in propText.split('\n')) {
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      props[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
    }
    final pkg = props['PackageName'] ?? '';
    return IwphoneModule(
      id: dirName,
      title: pkg.isEmpty ? dirName : pkg,
      version: props['version'] ?? '',
      author: props['author'] ?? '',
      description: props['description'] ?? '',
      running: false, // sdcard 镜像读不到运行态，由上层拉取 WebUI 时填充
      hasMain: true,  // prop 存在则视为已有元数据；main.sh 存在与否需另查文件
    );
  }
}

/// iwphone 包（.iwp 安装包）。
class IwphonePackage {
  const IwphonePackage({
    required this.name,
    required this.file,
    required this.installed,
  });

  final String name;
  final String file;
  final bool installed;

  factory IwphonePackage.fromJson(Map<String, dynamic> json) {
    return IwphonePackage(
      name: (json['name'] as String?) ?? '',
      file: (json['file'] as String?) ?? '',
      installed: json['installed'] == true,
    );
  }
}

/// iwphone 框架整体状态：守护 + 统计 + 路径 + 设备侧只读属性。
class IwphoneStatus {
  const IwphoneStatus({
    required this.daemonRunning,
    this.daemonPid,
    required this.moduleCount,
    required this.runningCount,
    this.workDir = '',
    this.logDir = '',
    this.sdcardDir = '',
    this.selinux = '',
    this.abi = '',
    this.daemonUser = '',
    this.webuiUser = '',
  });

  final bool daemonRunning;
  final int? daemonPid;
  final int moduleCount;
  final int runningCount;
  final String workDir;
  final String logDir;
  final String sdcardDir;

  /// SELinux 模式（强制 / 宽容 / 已关闭 / 未知）。
  ///
  /// 由 WebUI 以 root 上下文代读 —— App 进程是 untrusted_app，
  /// 读不到 `/sys/fs/selinux/*`，直接读会拿到空值。
  final String selinux;

  /// CPU 架构，如 `arm64-v8a`。
  final String abi;

  /// 框架守护进程以什么身份运行（`root` / `shell` / `app(10123)`）。
  ///
  /// 免 root 方案下期望是 `shell` —— 这是判断「有没有真的拿到 shell 权限」
  /// 最直观的证据。显示 `root` 说明权限比预期大，显示 `app(...)` 说明没拿到 shell。
  final String daemonUser;

  /// WebUI 进程的身份。
  final String webuiUser;

  /// WebUI 不可达时使用，表示「未连接」。
  static const IwphoneStatus unavailable = IwphoneStatus(
    daemonRunning: false,
    moduleCount: 0,
    runningCount: 0,
  );

  bool get isUnavailable =>
      !daemonRunning && moduleCount == 0 && daemonPid == null && workDir.isEmpty;

  /// 把可能是字符串的数值字段转成 int（后端 pid 有时是 `"8040"`）。
  static int? _asInt(Object? v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  factory IwphoneStatus.fromJson(Map<String, dynamic> json) {
    final daemon = json['daemon'] as Map<String, dynamic>?;
    final webui = json['webui'] as Map<String, dynamic>?;
    final counts = json['counts'] as Map<String, dynamic>?;
    final config = json['config'] as Map<String, dynamic>?;
    final system = json['system'] as Map<String, dynamic>?;
    return IwphoneStatus(
      daemonRunning: daemon?['running'] == true,
      daemonPid: _asInt(daemon?['pid']),
      moduleCount: _asInt(counts?['modules']) ?? 0,
      runningCount: _asInt(counts?['running']) ?? 0,
      workDir: (config?['work_dir'] as String?) ?? '',
      logDir: (config?['log_dir'] as String?) ?? '',
      sdcardDir: (config?['sdcard_dir'] as String?) ?? '',
      selinux: (system?['selinux'] as String?) ?? '',
      abi: (system?['abi'] as String?) ?? '',
      daemonUser: (daemon?['user'] as String?) ?? '',
      webuiUser: (webui?['user'] as String?) ?? '',
    );
  }
}

/// 模块日志类型（与 WebUI `?type=log|out|err` 对应）。
enum IwphoneLogKind { log, out, err }

extension IwphoneLogKindQuery on IwphoneLogKind {
  String get queryValue => switch (this) {
    IwphoneLogKind.log => 'log',
    IwphoneLogKind.out => 'out',
    IwphoneLogKind.err => 'err',
  };
}

/// 框架可配置项（对应 WebUI `GET /api/config` 返回的一条 item）。
class IwphoneConfigItem {
  const IwphoneConfigItem({
    required this.key,
    required this.label,
    required this.type,
    required this.group,
    required this.min,
    required this.max,
    required this.unit,
    required this.desc,
    required this.value,
  });

  final String key;
  final String label;

  /// int | bool | str
  final String type;
  final String group;
  final int min;
  final int max;
  final String unit;
  final String desc;
  final String value;

  bool get isInt => type == 'int';
  bool get isBool => type == 'bool';

  /// 布尔项状态（"1" 视为开启）。
  bool get boolValue => value == '1';

  /// 整数项取值（解析失败回退 0）。
  int get intValue => int.tryParse(value) ?? 0;

  /// 展示用文本：整数带单位，布尔显示开关态。
  String get displayValue {
    if (isBool) {
      return boolValue
          ? AppStrings.t('moduleConfig.on')
          : AppStrings.t('moduleConfig.off');
    }
    if (isInt) return unit.isEmpty ? value : '$value $unit';
    return value.isEmpty ? AppStrings.t('moduleConfig.emptyValue') : value;
  }

  factory IwphoneConfigItem.fromJson(Map<String, dynamic> json) {
    return IwphoneConfigItem(
      key: (json['key'] as String?) ?? '',
      label: (json['label'] as String?) ?? '',
      type: (json['type'] as String?) ?? 'str',
      group: (json['group'] as String?) ?? '',
      min: (json['min'] is num) ? (json['min'] as num).toInt() : 0,
      max: (json['max'] is num) ? (json['max'] as num).toInt() : 0,
      unit: (json['unit'] as String?) ?? '',
      desc: (json['desc'] as String?) ?? '',
      value: (json['value'] as String?) ?? '',
    );
  }

  IwphoneConfigItem copyWith({String? value}) => IwphoneConfigItem(
        key: key,
        label: label,
        type: type,
        group: group,
        min: min,
        max: max,
        unit: unit,
        desc: desc,
        value: value ?? this.value,
      );
}

/// 终端命令执行结果（对应 WebUI `POST /api/shell`）。
class ShellResult {
  const ShellResult({
    required this.ok,
    this.exitCode,
    this.stdout = '',
    this.stderr = '',
    this.message = '',
  });

  final bool ok;
  final int? exitCode;
  final String stdout;
  final String stderr;

  /// ok=false 时的原因（黑名单拦截 / 超时 / 服务不可达）。
  final String message;

  /// 合并 stdout 与 stderr，供终端直接展示。
  String get combined {
    final buf = StringBuffer();
    if (stdout.isNotEmpty) buf.write(stdout);
    if (stderr.isNotEmpty) {
      if (buf.isNotEmpty && !buf.toString().endsWith('\n')) buf.write('\n');
      buf.write(stderr);
    }
    return buf.toString();
  }

  factory ShellResult.fromJson(Map<String, dynamic> json) {
    return ShellResult(
      ok: json['ok'] == true,
      exitCode:
          (json['exitCode'] is num) ? (json['exitCode'] as num).toInt() : null,
      stdout: (json['stdout'] as String?) ?? '',
      stderr: (json['stderr'] as String?) ?? '',
      message: (json['msg'] as String?) ?? '',
    );
  }
}

/// 批量操作结果（stop-all / force-stop-all / restart-all）。
class BulkResult {
  const BulkResult({
    required this.ok,
    required this.message,
    this.names = const [],
  });

  final bool ok;
  final String message;

  /// 受影响的模块名（后端按操作类型分别放在 stopped / killed / restarted）。
  final List<String> names;

  factory BulkResult.fromJson(Map<String, dynamic> json) {
    final raw =
        (json['stopped'] ?? json['killed'] ?? json['restarted']) as List?;
    return BulkResult(
      ok: json['ok'] == true,
      message: (json['msg'] as String?) ?? '',
      names: raw?.whereType<String>().toList() ?? const [],
    );
  }
}

/// 资源冲突记录类型（对应框架 state/conflicts.log 的行）。
enum ConflictType {
  /// L1：启动被拒绝（声明独占资源已被占用）。
  block,

  /// L2：同一资源被多个模块写入。
  writer,

  /// L3：资源值被外部改动。
  drift,
}

/// 一条资源冲突记录。
class ConflictEntry {
  const ConflictEntry({
    required this.time,
    required this.type,
    required this.resource,
    required this.modules,
    required this.message,
  });

  final String time;
  final ConflictType type;
  final String resource;
  final List<String> modules;
  final String message;

  /// 简洁标签，用于列表徽标。
  String get typeLabel => switch (type) {
    ConflictType.block => AppStrings.t('conflictType.block'),
    ConflictType.writer => AppStrings.t('conflictType.writer'),
    ConflictType.drift => AppStrings.t('conflictType.drift'),
  };

  factory ConflictEntry.fromJson(Map<String, dynamic> json) {
    final t = (json['type'] as String?) ?? '';
    final rawMods = json['modules'];
    return ConflictEntry(
      time: (json['time'] as String?) ?? '',
      type: switch (t) {
        'block' => ConflictType.block,
        'writer' => ConflictType.writer,
        _ => ConflictType.drift,
      },
      resource: (json['resource'] as String?) ?? '',
      modules: rawMods is List ? rawMods.whereType<String>().toList() : const [],
      message: (json['message'] as String?) ?? '',
    );
  }
}

/// 资源占用条目：某个系统资源被哪些模块碰过。
class ResourceUsage {
  const ResourceUsage({
    required this.resource,
    required this.modules,
    required this.conflict,
  });

  final String resource;
  final List<String> modules;
  final bool conflict;

  /// 资源域（`.` 前一段），用于分组展示。
  String get domain {
    final i = resource.indexOf('.');
    return i > 0 ? resource.substring(0, i) : resource;
  }

  factory ResourceUsage.fromJson(Map<String, dynamic> json) {
    final rawMods = json['modules'];
    return ResourceUsage(
      resource: (json['resource'] as String?) ?? '',
      modules: rawMods is List ? rawMods.whereType<String>().toList() : const [],
      conflict: json['conflict'] == true,
    );
  }
}

/// 冲突总览：记录列表 + 资源占用图。
class ConflictReport {
  const ConflictReport({
    this.entries = const [],
    this.resources = const [],
  });

  final List<ConflictEntry> entries;
  final List<ResourceUsage> resources;

  /// 有冲突的资源数。
  int get conflictResCount => resources.where((r) => r.conflict).length;

  /// 是否完全无冲突。
  bool get isEmpty => entries.isEmpty && conflictResCount == 0;

  static const ConflictReport empty = ConflictReport();

  factory ConflictReport.fromJson(Map<String, dynamic> json) {
    final es = json['conflicts'];
    final rs = json['resources'];
    return ConflictReport(
      entries: es is List
          ? es
              .whereType<Map<String, dynamic>>()
              .map(ConflictEntry.fromJson)
              .toList()
          : const [],
      resources: rs is List
          ? rs
              .whereType<Map<String, dynamic>>()
              .map(ResourceUsage.fromJson)
              .toList()
          : const [],
    );
  }
}

// ============================================================
// 模块通用配置
//
// 模块作者在目录里放一份 config.prop 声明选项，App 按声明自动渲染
// 配置页 —— 不必为每个模块单独写界面。
//
// config.prop 每行一个选项，竖线分隔 6 段：
//     键|类型|标签|默认值|可选值(逗号分隔)|说明
// 例：
//     scale|select|动画速度|0.5|0,0.5,1|0 关闭动画，1 系统默认
//     blur|toggle|关闭窗口模糊|1||关闭后更流畅
//
// 类型名在后端是 bool/enum/int/text；这里为了避免和 Dart 关键字冲突
// 以及读起来更直观，映射为 toggle/select/number/text。
// 值由后端写进 config.sh（shell 赋值，键名统一大写），模块 source 读取。
// ============================================================

/// 配置项的控件类型。
enum ModuleConfigType {
  /// 布尔开关（后端 bool）
  toggle,

  /// 下拉单选（后端 enum）
  select,

  /// 整数输入（后端 int）
  number,

  /// 自由文本（后端 text）
  text,

  /// 未知类型 —— 渲染时降级为文本输入，不至于让整页崩掉
  unknown,
}

/// 单个配置项的声明。
class ModuleConfigSpec {
  const ModuleConfigSpec({
    required this.key,
    required this.type,
    required this.label,
    required this.defaultValue,
    required this.values,
    required this.desc,
  });

  /// 键名。后端写入 config.sh 时会转成大写，这里保留原名用于显示与提交。
  final String key;

  final ModuleConfigType type;

  /// 界面上显示的标签。
  final String label;

  /// 默认值（未保存过时使用）。
  final String defaultValue;

  /// select 的可选值；其它类型为空。
  final List<String> values;

  /// 说明文字，显示在控件下方。
  final String desc;

  static ModuleConfigType _parseType(String raw) {
    switch (raw) {
      case 'bool':
        return ModuleConfigType.toggle;
      case 'enum':
        return ModuleConfigType.select;
      case 'int':
        return ModuleConfigType.number;
      case 'text':
        return ModuleConfigType.text;
      default:
        return ModuleConfigType.unknown;
    }
  }

  /// 供提交时回传给后端使用的类型名。
  String get wireName => switch (type) {
        ModuleConfigType.toggle => 'bool',
        ModuleConfigType.select => 'enum',
        ModuleConfigType.number => 'int',
        ModuleConfigType.text => 'text',
        ModuleConfigType.unknown => 'text',
      };

  factory ModuleConfigSpec.fromJson(Map<String, dynamic> json) {
    return ModuleConfigSpec(
      key: (json['key'] as String?) ?? '',
      type: _parseType((json['type'] as String?) ?? ''),
      label: (json['label'] as String?) ?? '',
      defaultValue: (json['default'] as String?) ?? '',
      values: ((json['values'] as List<dynamic>?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      desc: (json['desc'] as String?) ?? '',
    );
  }
}

/// 一个模块的完整配置（声明 + 当前值）。
class ModuleConfig {
  const ModuleConfig({
    required this.has,
    required this.specs,
    required this.values,
  });

  /// 模块是否声明了可配置项（false 表示没有 config.prop）。
  final bool has;

  final List<ModuleConfigSpec> specs;

  /// 键 → 当前值；未保存过的项取声明里的默认值。
  final Map<String, String> values;

  bool get isEmpty => specs.isEmpty;

  factory ModuleConfig.fromJson(Map<String, dynamic> json) {
    final specs = ((json['specs'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ModuleConfigSpec.fromJson)
        .where((s) => s.key.isNotEmpty)
        .toList();

    final rawValues = json['values'] as Map<String, dynamic>? ?? const {};
    final values = <String, String>{};
    for (final s in specs) {
      values[s.key] = (rawValues[s.key] as String?) ?? s.defaultValue;
    }

    return ModuleConfig(
      has: json['has'] == true,
      specs: specs,
      values: values,
    );
  }
}
