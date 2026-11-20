import '../models/workflow.dart';

/// 内置模块目录 —— 可视化编辑器的"积木库"。
///
/// 借鉴 vFlow：模块只声明 id / 名称 / 分类 / 输入参数定义，
/// 编辑器据此动态生成表单，宿主不认识具体模块也能编辑。
/// 新增模块只需在这里加一条 + Kotlin WorkflowStore.executeStep 加一个分支。
class ModuleCatalog {
  static const List<ModuleDef> all = [
    // ---------- 触发器 ----------
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

  static List<ModuleDef> byCategory(String category) =>
      all.where((m) => m.category == category).toList();

  static List<String> get categories =>
      all.map((m) => m.category).toSet().toList();
}
