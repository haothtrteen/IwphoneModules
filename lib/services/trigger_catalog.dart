import 'app_catalog.dart';

/// 触发器预设（Dart 侧展示用）。
///
/// 与 Kotlin 的 `TriggerPresets.kt` **一一对应**：key 相同、顺序相同。
/// 真正的判定在原生侧（它才拿得到事件流），这里只负责把 key 显示成人话，
/// 避免界面上出现 `monitor:framework@STOPPED|ERROR` 这种没人看得懂的东西。
///
/// 新增触发器要两边一起改 —— 只改一边的后果是：界面里能选，但永远不触发。
///
/// 除了下面这张固定表，还有两类**应用级**触发器，key 后面直接跟包名：
/// - `app_foreground:<包名>`：某应用进入前台（依赖无障碍）
/// - `notif_post:<包名>`：某应用发出通知（依赖通知使用权）
/// 包名留空表示「任意应用」。它们不能放进固定表 —— 包名是枚举不完的。
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

  // ------------------------------------------------------------------
  // 应用级触发器
  // ------------------------------------------------------------------

  static const String appForegroundPrefix = 'app_foreground:';
  static const String appNotificationPrefix = 'notif_post:';

  static bool isAppForeground(String key) => key.startsWith(appForegroundPrefix);
  static bool isAppNotification(String key) => key.startsWith(appNotificationPrefix);
  static bool isAppScoped(String key) =>
      isAppForeground(key) || isAppNotification(key);

  /// 取出 key 里的包名；空串表示「任意应用」。
  static String appOf(String key) {
    if (isAppForeground(key)) return key.substring(appForegroundPrefix.length);
    if (isAppNotification(key)) return key.substring(appNotificationPrefix.length);
    return '';
  }

  static String appForeground(String pkg) => '$appForegroundPrefix$pkg';
  static String appNotification(String pkg) => '$appNotificationPrefix$pkg';

  /// 应用显示名；取不到就回退包名。
  static String _appLabel(String pkg) =>
      pkg.isEmpty ? '任意应用' : AppCatalog.instance.labelOf(pkg);

  static TriggerDef? find(String key) {
    for (final t in all) {
      if (t.key == key) return t;
    }
    return null;
  }

  /// 未知 key 原样返回 —— 可能是旧版/手写的裸事件前缀，别把它显示成空白。
  static String label(String key) {
    if (isAppForeground(key)) return '前台：${_appLabel(appOf(key))}';
    if (isAppNotification(key)) return '通知：${_appLabel(appOf(key))}';
    return find(key)?.label ?? (key.isEmpty ? '手动执行' : key);
  }

  static String desc(String key) {
    if (isAppForeground(key)) {
      final name = _appLabel(appOf(key));
      return '当 $name 切换到前台时触发（同一应用内部切页面不算）';
    }
    if (isAppNotification(key)) {
      final name = _appLabel(appOf(key));
      return '当 $name 发出新通知时触发（常驻通知与分组摘要不算）';
    }
    return find(key)?.desc ?? '自定义事件过滤器：$key';
  }

  static bool needsAccessibility(String key) =>
      isAppForeground(key) || (find(key)?.needsAccessibility ?? false);

  static bool needsNotification(String key) => isAppNotification(key);
}
