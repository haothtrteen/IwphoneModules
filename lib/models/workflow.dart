/// 可视化工作流模型（借鉴 vFlow 的 ActionStep / InputDefinition）。

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
  });

  final String id;
  final String name;
  final String category;
  final String icon;
  final List<ParamDef> params;
  final bool trigger;
  final bool dangerous;
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
  }) : steps = steps ?? <WorkflowStep>[];

  final String id;
  final String name;
  final List<WorkflowStep> steps;
  final bool stopOnError;
  final int updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'steps': steps.map((s) => s.toJson()).toList(),
        'stopOnError': stopOnError,
        'updatedAt': updatedAt,
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
      );
}
