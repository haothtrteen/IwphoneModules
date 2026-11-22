/// 可视化工作流模型（借鉴 vFlow 的 ActionStep / InputDefinition）。
///
/// 两个来源共用一套结构：
/// - **本地工作流**：App 里搭的，存 SharedPreferences，可编辑可删；
/// - **模块自带**：`.iwp` 包里的 automation.json，扫描时注入
///   `source` / `module` 且 `readonly = true`，只能运行或「复制为我的一份」。
library;

import '../services/trigger_catalog.dart';

enum ParamType { text, number, boolean, enumValue }

class ParamDef {
  const ParamDef({
    required this.id,
    required this.label,
    required this.type,
    this.defaultValue,
    this.options = const [],
    this.min,
    this.max,
    this.hint = '',
  });

  final String id;
  final String label;
  final ParamType type;
  final Object? defaultValue;
  final List<String> options;
  final num? min;
  final num? max;
  final String hint;
}

class ModuleDef {
  const ModuleDef({
    required this.id,
    required this.name,
    required this.category,
    required this.icon,
    this.params = const [],
    this.trigger = false,
    this.dangerous = false,
    this.developer = false,
  });

  final String id;
  final String name;
  final String category;
  final String icon;
  final List<ParamDef> params;

  /// 旧版的「触发器步骤」。触发器已挪到工作流头部，这里只为兼容旧数据保留。
  final bool trigger;
  final bool dangerous;

  /// 开发者模式专属：默认不出现在积木选择器里，且原生侧也会拒绝执行。
  final bool developer;
}

class WorkflowStep {
  WorkflowStep({required this.moduleId, Map<String, dynamic>? params, this.disabled = false})
      : params = params ?? {};

  final String moduleId;
  final Map<String, dynamic> params;
  bool disabled;

  Map<String, dynamic> toJson() => {
        'moduleId': moduleId,
        'params': params,
        'disabled': disabled,
      };

  factory WorkflowStep.fromJson(Map<String, dynamic> j) => WorkflowStep(
        moduleId: j['moduleId'] as String? ?? '',
        params: (j['params'] as Map?)?.cast<String, dynamic>() ?? {},
        disabled: j['disabled'] == true,
      );
}

class Workflow {
  Workflow({
    required this.id,
    required this.name,
    List<WorkflowStep>? steps,
    this.stopOnError = true,
    this.updatedAt = 0,
    this.trigger = TriggerCatalog.manual,
    this.source = '',
    this.module = '',
    this.readonly = false,
  }) : steps = steps ?? <WorkflowStep>[];

  final String id;
  final String name;
  final List<WorkflowStep> steps;
  final bool stopOnError;
  final int updatedAt;

  /// 触发器预设 key（见 [TriggerCatalog]）。
  final String trigger;

  /// 来源描述，例如「iwphone 模块 · mymod」；本地工作流为空。
  final String source;

  /// 模块名（模块自带时非空）。
  final String module;

  /// 只读：模块带来的流程不允许就地编辑（改了下一次更新模块就被覆盖）。
  final bool readonly;

  bool get isFromModule => readonly || module.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'steps': steps.map((s) => s.toJson()).toList(),
        'stopOnError': stopOnError,
        'updatedAt': updatedAt,
        'trigger': trigger,
        if (source.isNotEmpty) 'source': source,
        if (module.isNotEmpty) 'module': module,
        if (readonly) 'readonly': true,
      };

  factory Workflow.fromJson(Map<String, dynamic> j) => Workflow(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        steps: (j['steps'] as List?)
                ?.whereType<Map>()
                .map((m) => WorkflowStep.fromJson(m.cast<String, dynamic>()))
                .toList() ??
            [],
        stopOnError: j['stopOnError'] != false,
        updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
        trigger: (j['trigger'] as String?)?.isNotEmpty == true
            ? j['trigger'] as String
            : TriggerCatalog.manual,
        source: j['source'] as String? ?? '',
        module: j['module'] as String? ?? '',
        readonly: j['readonly'] == true,
      );

  Workflow copy() => Workflow.fromJson(toJson());
}
