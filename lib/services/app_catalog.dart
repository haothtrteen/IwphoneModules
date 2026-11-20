import 'monitor_service.dart';

/// 已安装应用清单（包名 → 显示名）。
///
/// 应用级触发器的 key 里存的是包名（`app_foreground:com.tencent.mm`），
/// 但界面上必须显示「微信」。这份缓存就是那个映射表：
/// - 只取有桌面入口的应用（没图标的系统组件列出来只会干扰选择）；
/// - 中文按 Collator 排序由原生侧完成；
/// - 加载失败时 `labelOf` 回退成包名，不会因为拿不到名字就崩或显示空白。
class AppCatalog {
  AppCatalog._();
  static final AppCatalog instance = AppCatalog._();

  List<AppEntry> _items = const [];
  Map<String, String> _byPkg = const {};
  bool _loaded = false;

  bool get loaded => _loaded;
  List<AppEntry> get items => _items;

  Future<List<AppEntry>> load({bool force = false}) async {
    if (_loaded && !force) return _items;
    final raw = await MonitorService.instance.apps();
    final list = raw
        .map((e) => AppEntry(pkg: e.pkg, label: e.label.isEmpty ? e.pkg : e.label))
        .toList();
    if (list.isEmpty && _loaded) return _items; // 拉失败就别把已有缓存冲掉
    _items = list;
    _byPkg = {for (final a in list) a.pkg: a.label};
    _loaded = list.isNotEmpty;
    return _items;
  }

  /// 包名 → 显示名；查不到就返回包名本身（比显示「未知应用」有用）。
  String labelOf(String pkg) => _byPkg[pkg] ?? pkg;
}

class AppEntry {
  const AppEntry({required this.pkg, required this.label});
  final String pkg;
  final String label;

  factory AppEntry.fromJson(Map<String, dynamic> j) => AppEntry(
        pkg: j['pkg'] as String? ?? '',
        label: j['label'] as String? ?? '',
      );
}
