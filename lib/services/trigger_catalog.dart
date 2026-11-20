/// 触发器预设（Dart 侧展示用）。
///
/// 与 Kotlin 的 `TriggerPresets.kt` **一一对应**：key 相同、顺序相同。
/// 真正的判定在原生侧（它才拿得到事件流），这里只负责把 key 显示成人话，
/// 避免界面上出现 `monitor:framework@STOPPED|ERROR` 这种没人看得懂的东西。
///
/// 新增触发器要两边一起改 —— 只改一边的后果是：界面里能选，但永远不触发。
class TriggerDef {
  const TriggerDef({
    required this.key,
    required this.label,
    required this.desc,
    this.needsAccessibility = false,
  });

  final String key;
  final String label;
  final String desc;

  /// 依赖无障碍服务 —— 界面要提示用户去系统设置里开。
  final bool needsAccessibility;
}

class TriggerCatalog {
  TriggerCatalog._();

  /// 手动执行：不进触发器列表的自动分支。
  static const String manual = 'manual';

  static const List<TriggerDef> all = [
    TriggerDef(
      key: manual,
      label: '手动执行',
      desc: '不自动触发，只在自动化页点「运行」时执行一次',
    ),
    TriggerDef(
      key: 'framework_down',
      label: '框架停止运行',
      desc: 'iwphone 守护进程（Main.sh）掉线、崩溃或未启动时触发',
    ),
    TriggerDef(
      key: 'framework_up',
      label: '框架恢复运行',
      desc: '守护进程重新拉起、状态回到运行中时触发一次',
    ),
    TriggerDef(
      key: 'adb_down',
      label: 'adb 通道断开',
      desc: '自持 adb 与设备失联（无线调试掉线 / 端口变了）时触发',
    ),
    TriggerDef(
      key: 'module_exit',
      label: '模块退出',
      desc: '任一 iwphone 模块的进程消失时触发（事件里带模块名）',
    ),
    TriggerDef(
      key: 'window_change',
      label: '前台界面切换',
      desc: '任何应用切换前台界面时触发，需要开启无障碍服务',
      needsAccessibility: true,
    ),
    TriggerDef(
      key: 'a11y_ready',
      label: '无障碍服务连上',
      desc: '无障碍服务被系统重新绑定后触发，适合做首次初始化',
      needsAccessibility: true,
    ),
  ];

  /// 可自动触发的（排除 manual）。
  static List<TriggerDef> get automatable =>
      all.where((t) => t.key != manual).toList();

  static TriggerDef? find(String key) {
    for (final t in all) {
      if (t.key == key) return t;
    }
    return null;
  }

  /// 未知 key 原样返回 —— 可能是旧版/手写的裸事件前缀，别把它显示成空白。
  static String label(String key) => find(key)?.label ?? (key.isEmpty ? '手动执行' : key);

  static String desc(String key) => find(key)?.desc ?? '自定义事件过滤器：$key';

  static bool needsAccessibility(String key) =>
      find(key)?.needsAccessibility ?? false;
}
