import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/monitor_event.dart';
import '../models/workflow.dart';

/// 监视器状态摘要。
class MonitorInfo {
  const MonitorInfo({required this.id, required this.state, this.subscribers = 0});
  final String id;
  final String state;
  final int subscribers;

  factory MonitorInfo.fromJson(Map<String, dynamic> j) => MonitorInfo(
        id: j['id'] as String? ?? '',
        state: j['state'] as String? ?? 'UNKNOWN',
        subscribers: (j['subscribers'] as num?)?.toInt() ?? 0,
      );
}

/// 监视器 / 事件服务（P0，只读状态与即时事件流）。
class MonitorService {
  MonitorService._();
  static final MonitorService instance = MonitorService._();

  static const MethodChannel _method = MethodChannel('shellmgr/monitors');
  static const EventChannel _event = EventChannel('shellmgr/events');

  StreamSubscription<dynamic>? _subscription;
  final List<PlatformEvent> _events = [];
  static const int _maxEvents = 200;

  List<PlatformEvent> get events => List.unmodifiable(_events);

  Future<List<MonitorInfo>> list() async {
    try {
      final raw = await _method.invokeMethod<String>('list');
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((m) => MonitorInfo.fromJson(m.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<List<Workflow>> workflows() async {
    try {
      final raw = await _method.invokeMethod<String>('workflowList');
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((m) => Workflow.fromJson(m.cast<String, dynamic>()))
          .toList();
    } catch (_) { return const []; }
  }

  Future<bool> saveWorkflow(Workflow w) async {
    try {
      return await _method.invokeMethod<bool>('workflowSave', {'json': jsonEncode(w.toJson())}) ?? false;
    } catch (_) { return false; }
  }

  Future<void> deleteWorkflow(String id) async {
    try { await _method.invokeMethod<void>('workflowDelete', {'id': id}); } catch (_) {}
  }

  Future<({bool ok, String msg})> runWorkflow(String id) async {
    try {
      final r = await _method.invokeMethod<Map<dynamic, dynamic>>('workflowRun', {'id': id});
      return (ok: r?['ok'] == true, msg: (r?['msg'] as String?) ?? '');
    } catch (e) { return (ok: false, msg: e.toString()); }
  }

  // ------------------------------------------------------------------
  // 模块自带的自动化（.iwp 包里的 automation.json）
  // ------------------------------------------------------------------

  /// 扫出所有已装模块自带的流程（只读）。
  ///
  /// 原生侧一次 adb 调用扫全部并带 30 秒缓存；[force] 用于「刚装完模块」后刷新。
  Future<List<Workflow>> moduleWorkflows({bool force = false}) async {
    try {
      final raw = await _method
          .invokeMethod<String>('moduleWorkflows', {'force': force});
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((m) => Workflow.fromJson(m.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<String> moduleAutomationError() async {
    try {
      return await _method.invokeMethod<String>('moduleAutomationError') ?? '';
    } catch (_) {
      return '';
    }
  }

  // ------------------------------------------------------------------
  // 武装 / 解除（触发器挂载）
  // ------------------------------------------------------------------

  /// 已武装的工作流：id -> trigger key。原生侧持久化，重启后自动恢复。
  Future<Map<String, String>> armedWorkflows() async {
    try {
      final raw = await _method.invokeMethod<String>('workflowArmed');
      if (raw == null || raw.isEmpty) return const {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      return const {};
    }
  }

  Future<bool> armWorkflow(String id, String trigger) async {
    try {
      return await _method.invokeMethod<bool>(
              'workflowArm', {'id': id, 'trigger': trigger}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> disarmWorkflow(String id) async {
    try {
      await _method.invokeMethod<void>('workflowDisarm', {'id': id});
    } catch (_) {}
  }

  /// 把工作流打包成 `.iwp` 推到设备的 iwphone/module/（之后到模块页安装）。
  Future<({bool ok, String msg})> exportWorkflow(String id, String name) async {
    try {
      final r = await _method.invokeMethod<Map<dynamic, dynamic>>(
          'workflowExport', {'id': id, 'name': name});
      return (ok: r?['ok'] == true, msg: (r?['msg'] as String?) ?? '');
    } catch (e) {
      return (ok: false, msg: e.toString());
    }
  }

  Future<List<AutomationInfo>> automations() async {
    try {
      final raw = await _method.invokeMethod<String>('automations');
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((m) => AutomationInfo.fromJson(m.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<bool> automationLoad(String module) async {
    try {
      return await _method.invokeMethod<bool>('automationLoad', {'module': module}) ?? false;
    } catch (_) { return false; }
  }

  Future<bool> automationArm(String id) async {
    try {
      return await _method.invokeMethod<bool>('automationArm', {'id': id}) ?? false;
    } catch (_) { return false; }
  }

  Future<void> automationDisarm(String id) async {
    try { await _method.invokeMethod<void>('automationDisarm', {'id': id}); } catch (_) {}
  }

  Future<bool> automationRun(String id) async {
    try {
      return await _method.invokeMethod<bool>('automationRun', {'id': id}) ?? false;
    } catch (_) { return false; }
  }

  Future<List<CapabilityInfo>> capabilities() async {
    try {
      final raw = await _method.invokeMethod<String>('capabilities');
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((m) => CapabilityInfo.fromJson(m.cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<Map<String, String>> allStates() async {
    try {
      final raw = await _method.invokeMethod<String>('all');
      if (raw == null || raw.isEmpty) return const {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      return const {};
    }
  }

  Future<String?> probe(String id) async {
    try {
      return await _method.invokeMethod<String>('probe', {'id': id});
    } catch (_) {
      return null;
    }
  }

  /// 订阅事件流。先清空本地缓存（事件不粘滞，晚订阅者不该看到历史事件）。
  void startListening(void Function(PlatformEvent) onEvent) {
    _events.clear();
    _subscription ??= _event.receiveBroadcastStream().listen((dynamic raw) {
      if (raw is! Map) return;
      final e = PlatformEvent.fromMap(raw);
      _events.insert(0, e);
      if (_events.length > _maxEvents) _events.removeRange(_maxEvents, _events.length);
      onEvent(e);
    });
  }

  void stopListening() {
    _subscription?.cancel();
    _subscription = null;
  }

  void clear() => _events.clear();
}


/// 能力可用性摘要。
class CapabilityInfo {
  const CapabilityInfo({required this.id, required this.name, required this.availability});
  final String id;
  final String name;
  final String availability;

  factory CapabilityInfo.fromJson(Map<String, dynamic> j) => CapabilityInfo(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        availability: j['availability'] as String? ?? 'UNKNOWN',
      );
}


/// 自动化脚本摘要（模块 automation.prop 声明的那一类）。
class AutomationInfo {
  const AutomationInfo({
    required this.id, required this.state,
    required this.trigger, required this.action,
    this.triggerLabel = '',
  });
  final String id;
  final String state;
  final String trigger;

  /// 原生侧翻译好的中文触发器名；缺失时回退到原始 trigger 串。
  final String triggerLabel;
  final String action;

  factory AutomationInfo.fromJson(Map<String, dynamic> j) => AutomationInfo(
        id: j['id'] as String? ?? '',
        state: j['state'] as String? ?? 'UNINSTALLED',
        trigger: j['trigger'] as String? ?? 'manual',
        triggerLabel: j['triggerLabel'] as String? ?? '',
        action: j['action'] as String? ?? '',
      );
}
