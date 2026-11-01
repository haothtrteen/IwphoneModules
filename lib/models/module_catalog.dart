/// 云端模块清单（仓库根目录的 `modules.catalog.json`）。
///
/// 结构见仓库里的 schemaVersion 2：
/// ```json
/// {
///   "schemaVersion": 2,
///   "repository": "haothtrteen/IwphoneModules",
///   "updatedAt": "2026-11-01",
///   "modules": [ { "id", "name", "version", "author", "description",
///                  "icon", "packagePath", "sizeBytes", "sha256" } ]
/// }
/// ```
class ModuleCatalog {
  const ModuleCatalog({
    required this.schemaVersion,
    required this.updatedAt,
    required this.modules,
  });

  final int schemaVersion;
  final String updatedAt;
  final List<StoreModule> modules;

  factory ModuleCatalog.fromJson(Map<String, dynamic> json) {
    final list = (json['modules'] as List?) ?? const [];
    return ModuleCatalog(
      schemaVersion: (json['schemaVersion'] is num)
          ? (json['schemaVersion'] as num).toInt()
          : 0,
      updatedAt: (json['updatedAt'] as String?) ?? '',
      modules: list
          .whereType<Map>()
          .map((m) => StoreModule.fromJson(m.cast<String, dynamic>()))
          .where((m) => m.id.isNotEmpty && m.packagePath.isNotEmpty)
          .toList(growable: false),
    );
  }
}

/// 清单里的一个模块。
class StoreModule {
  const StoreModule({
    required this.id,
    required this.name,
    required this.version,
    required this.author,
    required this.description,
    required this.icon,
    required this.packagePath,
    required this.sizeBytes,
    required this.sha256,
  });

  /// 模块 id，同时也是 `.iwp` 文件名主名（框架按它决定安装目录）。
  final String id;

  final String name;
  final String version;
  final String author;
  final String description;

  /// 语义图标名（与 `ModuleIcons.table` 对应），可能为空。
  final String icon;

  /// 仓库内相对路径，例如 `framework/module/BlurOff.iwp`。
  final String packagePath;

  final int sizeBytes;

  /// 小写十六进制 SHA-256。空串表示清单没提供，跳过校验。
  final String sha256;

  /// 展示用体积，例如 `446 KB` / `1.2 MB`。
  String get sizeLabel {
    if (sizeBytes <= 0) return '—';
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(0)} KB';
    }
    return '${(sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  factory StoreModule.fromJson(Map<String, dynamic> json) {
    return StoreModule(
      id: (json['id'] as String?)?.trim() ?? '',
      name: ((json['name'] as String?)?.trim().isNotEmpty ?? false)
          ? (json['name'] as String).trim()
          : ((json['id'] as String?) ?? '').trim(),
      version: (json['version'] as String?) ?? '',
      author: (json['author'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
      icon: (json['icon'] as String?)?.trim() ?? '',
      packagePath: (json['packagePath'] as String?)?.trim() ?? '',
      sizeBytes: (json['sizeBytes'] is num)
          ? (json['sizeBytes'] as num).toInt()
          : 0,
      sha256: (json['sha256'] as String?)?.trim().toLowerCase() ?? '',
    );
  }
}
