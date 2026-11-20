/// 平台事件（对应 Kotlin 侧 PlatformEvent）。
class PlatformEvent {
  const PlatformEvent({
    required this.id,
    required this.kind,
    required this.from,
    required this.to,
    required this.reason,
    required this.severity,
    required this.ts,
  });

  final String id;
  final String kind;
  final String from;
  final String to;
  final String reason;
  final String severity;
  final int ts;

  DateTime get time => DateTime.fromMillisecondsSinceEpoch(ts);

  factory PlatformEvent.fromMap(Map<dynamic, dynamic> m) => PlatformEvent(
        id: (m['id'] as String?) ?? '',
        kind: (m['kind'] as String?) ?? 'state',
        from: (m['from'] as String?) ?? '',
        to: (m['to'] as String?) ?? '',
        reason: (m['reason'] as String?) ?? '',
        severity: (m['severity'] as String?) ?? 'info',
        ts: (m['ts'] as num?)?.toInt() ?? 0,
      );
}

