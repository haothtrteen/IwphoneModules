import '../models/workflow.dart';

/// 内置模块目录 —— 可视化编辑器的"积木库"。
///
/// 借鉴 vFlow：模块只声明 id / 名称 / 分类 / 输入参数定义，
/// 编辑器据此动态生成表单，宿主不认识具体模块也能编辑。
/// 新增模块只需在这里加一条 + Kotlin WorkflowStore.executeStep 加一个分支。
class ModuleCatalog {
  static const List<ModuleDef> all = [
    // ---------- 触发器（旧版：现已挪到工作流头部，仅保留给旧数据展示） ----------
    ModuleDef(
      id: 'trigger.event',
      name: '事件触发',
      category: '触发器',
      icon: '⚡',
      trigger: true,
      params: [
        ParamDef(id: 'on', label: '监听事件', type: ParamType.enumValue,
            options: ['monitor:framework', 'monitor:adb', 'a11y:window', 'capability:accessibility'],
            defaultValue: 'monitor:framework'),
      ],
    ),
    ModuleDef(
      id: 'trigger.manual',
      name: '手动执行',
      category: '触发器',
      icon: '👆',
      trigger: true,
    ),

    // ---------- adb shell 动作（无需无障碍） ----------
    ModuleDef(
      id: 'adb.tap',
      name: '点击坐标',
      category: 'adb shell',
      icon: '👆',
      params: [
        ParamDef(id: 'x', label: 'X', type: ParamType.number, defaultValue: 500, min: 0, max: 5000),
        ParamDef(id: 'y', label: 'Y', type: ParamType.number, defaultValue: 1000, min: 0, max: 5000),
      ],
    ),
    ModuleDef(
      id: 'adb.swipe',
      name: '滑动',
      category: 'adb shell',
      icon: '↔',
      params: [
        ParamDef(id: 'x1', label: '起点 X', type: ParamType.number, defaultValue: 500),
        ParamDef(id: 'y1', label: '起点 Y', type: ParamType.number, defaultValue: 1500),
        ParamDef(id: 'x2', label: '终点 X', type: ParamType.number, defaultValue: 500),
        ParamDef(id: 'y2', label: '终点 Y', type: ParamType.number, defaultValue: 500),
        ParamDef(id: 'duration', label: '时长(ms)', type: ParamType.number, defaultValue: 300),
      ],
    ),
    ModuleDef(
      id: 'adb.text',
      name: '输入文本',
      category: 'adb shell',
      icon: '⌨',
      params: [
        ParamDef(id: 'text', label: '文本（空格请用 %s）', type: ParamType.text, defaultValue: 'hello'),
      ],
    ),
    ModuleDef(
      id: 'adb.key',
      name: '按键',
      category: 'adb shell',
      icon: '🔘',
      params: [
        ParamDef(id: 'code', label: 'keycode', type: ParamType.number, defaultValue: 4,
            hint: '4=返回, 3=Home, 26=电源'),
      ],
    ),
    ModuleDef(
      id: 'adb.start',
      name: '启动应用',
      category: 'adb shell',
      icon: '🚀',
      params: [
        ParamDef(id: 'package', label: '包名', type: ParamType.text, defaultValue: 'com.termux'),
      ],
    ),
    ModuleDef(
      id: 'adb.stop',
      name: '强制停止应用',
      category: 'adb shell',
      icon: '⏹',
      params: [
        ParamDef(id: 'package', label: '包名', type: ParamType.text, defaultValue: 'com.termux'),
      ],
    ),
    ModuleDef(
      id: 'adb.screencap',
      name: '截图',
      category: 'adb shell',
      icon: '📷',
      params: [
        ParamDef(id: 'path', label: '保存路径', type: ParamType.text,
            defaultValue: '/sdcard/iwphone/shot.png'),
      ],
    ),
    ModuleDef(
      id: 'adb.raw',
      name: '原始 shell 命令',
      category: 'adb shell',
      icon: '⌨',
      dangerous: true,
      params: [
        ParamDef(id: 'cmd', label: '命令（执行前二次确认）', type: ParamType.text, defaultValue: 'id'),
      ],
    ),

    // ---------- 模块动作 ----------
    ModuleDef(
      id: 'module.run',
      name: '运行 iwphone 模块',
      category: '模块',
      icon: '📦',
      params: [
        ParamDef(id: 'module', label: '模块名', type: ParamType.text, defaultValue: ''),
        ParamDef(id: 'op', label: '操作', type: ParamType.enumValue,
            options: ['run', 'stop', 'install', 'uninstall'], defaultValue: 'run'),
      ],
    ),

    // ---------- 界面识别 / 提示（复用无障碍服务，不引入 OCR 依赖） ----------
    ModuleDef(
      id: 'system.toast',
      name: '显示 Toast 提示',
      category: '界面识别',
      icon: '💬',
      params: [
        ParamDef(id: 'message', label: '消息内容', type: ParamType.text,
            defaultValue: '你好'),
      ],
    ),
    ModuleDef(
      id: 'ui.text',
      name: '读取界面文字',
      category: '界面识别',
      icon: '📄',
      params: [
        ParamDef(id: 'filter', label: '筛选（正则，留空=全部）', type: ParamType.text,
            defaultValue: '', hint: '只保留匹配到的文字行'),
        ParamDef(id: 'max', label: '最多扫描节点', type: ParamType.number,
            defaultValue: 300, min: 20, max: 1000),
      ],
    ),
    ModuleDef(
      id: 'ui.find',
      name: '查找控件并点击',
      category: '界面识别',
      icon: '🔍',
      params: [
        ParamDef(id: 'text', label: '控件文字', type: ParamType.text,
            defaultValue: '', hint: '与内容描述也会匹配；留空则只看 viewId'),
        ParamDef(id: 'viewId', label: '控件 ID', type: ParamType.text,
            defaultValue: '', hint: '如 com.android.settings:id/title'),
        ParamDef(id: 'match', label: '匹配方式', type: ParamType.enumValue,
            options: ['contains', 'exact', 'starts_with', 'regex'],
            defaultValue: 'contains'),
        ParamDef(id: 'click', label: '找到后点击中心点', type: ParamType.boolean,
            defaultValue: true),
        ParamDef(id: 'max', label: '最多扫描节点', type: ParamType.number,
            defaultValue: 300, min: 20, max: 1000),
      ],
    ),
    ModuleDef(
      id: 'ui.waitText',
      name: '等待文字出现/消失',
      category: '界面识别',
      icon: '⏳',
      params: [
        ParamDef(id: 'text', label: '目标文字', type: ParamType.text, defaultValue: ''),
        ParamDef(id: 'viewId', label: '控件 ID（可选）', type: ParamType.text,
            defaultValue: ''),
        ParamDef(id: 'match', label: '匹配方式', type: ParamType.enumValue,
            options: ['contains', 'exact', 'starts_with', 'regex'],
            defaultValue: 'contains'),
        ParamDef(id: 'appear', label: '等待出现（关掉则等待消失）',
            type: ParamType.boolean, defaultValue: true),
        ParamDef(id: 'timeoutMs', label: '超时(ms)', type: ParamType.number,
            defaultValue: 5000, min: 100, max: 60000),
        ParamDef(id: 'intervalMs', label: '轮询间隔(ms)', type: ParamType.number,
            defaultValue: 300, min: 50, max: 5000),
      ],
    ),

    // ---------- 开发者能力（默认隐藏，开启开发者模式才显示） ----------
    // ★ 这些积木不授予任何系统权限；权限仍由用户点系统弹窗。
    ModuleDef(
      id: 'dev.notification',
      name: '读取最近通知',
      category: '开发者能力',
      icon: '🔔',
      developer: true,
      params: [
        ParamDef(id: 'package', label: '包名筛选（留空=全部）', type: ParamType.text,
            defaultValue: ''),
        ParamDef(id: 'limit', label: '最多几条', type: ParamType.number,
            defaultValue: 10, min: 1, max: 100),
      ],
    ),
    ModuleDef(
      id: 'dev.sms',
      name: '读取收件箱短信',
      category: '开发者能力',
      icon: '✉️',
      developer: true,
      dangerous: true,
      params: [
        ParamDef(id: 'sender', label: '号码筛选（留空=全部）', type: ParamType.text,
            defaultValue: ''),
        ParamDef(id: 'limit', label: '最多几条', type: ParamType.number,
            defaultValue: 10, min: 1, max: 50),
      ],
    ),
    ModuleDef(
      id: 'dev.location',
      name: '读取最后已知位置',
      category: '开发者能力',
      icon: '📍',
      developer: true,
      dangerous: true,
    ),

    // ---------- 逻辑 ----------
    ModuleDef(
      id: 'logic.delay',
      name: '延时等待',
      category: '逻辑',
      icon: '⏱',
      params: [
        ParamDef(id: 'ms', label: '毫秒', type: ParamType.number, defaultValue: 1000, min: 0, max: 60000),
      ],
    ),
    ModuleDef(
      id: 'flow.run',
      name: '调用其它工作流',
      category: '逻辑',
      icon: '🔗',
      params: [
        ParamDef(id: 'workflow', label: '工作流 ID', type: ParamType.text, defaultValue: ''),
      ],
    ),
  ];

  static ModuleDef? find(String id) {
    for (final m in all) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// 可以往流程里加的积木：**不含**触发器。
  ///
  /// 触发器现在是工作流的头部属性（见 [Workflow.trigger]），不再是步骤 ——
  /// 以前的 `trigger.event` 步骤让用户以为「触发器是第一步动作」，
  /// 选了却不知道到底什么时候跑，正是「事件触发看不懂」的根源。
  /// 旧数据里的 trigger.* 步骤仍在 [all] 里，只做展示兼容，不进选择器。
  static List<ModuleDef> get actions => all.where((m) => !m.trigger).toList();

  /// 积木选择器用：默认不显示开发者能力。
  static List<ModuleDef> actionsFor({bool includeDeveloper = false}) => all
      .where((m) => !m.trigger && (includeDeveloper || !m.developer))
      .toList();

  static List<ModuleDef> byCategory(String category,
          {bool includeDeveloper = false}) =>
      actionsFor(includeDeveloper: includeDeveloper)
          .where((m) => m.category == category)
          .toList();

  static List<String> get categories =>
      actionsFor().map((m) => m.category).toSet().toList();

  static List<String> categoriesFor({bool includeDeveloper = false}) =>
      actionsFor(includeDeveloper: includeDeveloper)
          .map((m) => m.category)
          .toSet()
          .toList();
}
