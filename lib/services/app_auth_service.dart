import 'dart:convert';

import 'package:flutter/services.dart';

/// 应用授权（对外 broker 通道）的 Dart 侧封装。
///
/// 与原生 [BrokerProvider] 的分工：
///   - **BrokerProvider** 是给*别的应用*用的入口，校验 (包名, uid, 签名) 后转发给框架；
///   - **本文件** 只负责本应用界面要用的数据：授权清单、待审批、调用记录。
///
/// 两边共用原生侧的 `BrokerStore`，所以界面上撤销后立刻生效，不需要重启。
class AppAuthService {
  AppAuthService._();

  static final AppAuthService instance = AppAuthService._();

  static const MethodChannel _ch = MethodChannel('shellmgr/appauth');

  /// 已授权的应用。
  Future<List<AuthorizedApp>> listGrants() async {
    final raw = await _ch.invokeMethod<Map<dynamic, dynamic>>('listGrants');
    return _parse(raw, AuthorizedApp.fromJson);
  }

  /// 发起过调用但**还没被批准**的应用。
  ///
  /// 这是本机制的关键一环：Android 10+ 不允许后台进程弹窗，
  /// 所以「请求授权」只能落成一条记录，由用户主动来这个页面处理。
  Future<List<PendingApp>> listPending() async {
    final raw = await _ch.invokeMethod<Map<dynamic, dynamic>>('listPending');
    return _parse(raw, PendingApp.fromJson);
  }

  /// 被用户「记住并拒绝」的应用（不会弹窗，需在这里解除）。
  Future<List<AuthorizedApp>> listDenied() async {
    final raw = await _ch.invokeMethod<Map<dynamic, dynamic>>('listDenied');
    return _parse(raw, AuthorizedApp.fromJson);
  }

  /// 解除永久拒绝；[pkg] 为空时清空全部。
  Future<void> clearDenied([String? pkg]) =>
      _ch.invokeMethod<void>('clearDenied', {'pkg': pkg});

  /// 是否已获得「显示在其他应用上层」权限 —— 决定即时弹窗能否工作。
  Future<bool> overlayEnabled() async {
    final raw = await _ch.invokeMethod<Map<dynamic, dynamic>>('overlayState');
    return raw?['enabled'] == true;
  }

  /// 跳系统悬浮窗设置页。返回是否成功打开。
  Future<bool> openOverlaySettings() async {
    final raw = await _ch.invokeMethod<Map<dynamic, dynamic>>('openOverlaySettings');
    return raw?['ok'] == true;
  }

  /// 批准一个应用。返回 (ok, msg)。
  Future<({bool ok, String msg})> grant(String pkg) async {
    final raw = await _ch.invokeMethod<Map<dynamic, dynamic>>('grant', {'pkg': pkg});
    return (ok: raw?['ok'] == true, msg: (raw?['msg'] ?? '') as String? ?? '');
  }

  Future<void> revoke(String pkg) =>
      _ch.invokeMethod<void>('revoke', {'pkg': pkg});

  Future<void> revokeAll() => _ch.invokeMethod<void>('revokeAll');

  /// 清除待审批记录；[pkg] 为空时清空全部。
  Future<void> clearPending([String? pkg]) =>
      _ch.invokeMethod<void>('clearPending', {'pkg': pkg});

  Future<List<AuditEntry>> listAudit() async {
    final raw = await _ch.invokeMethod<Map<dynamic, dynamic>>('listAudit');
    return _parse(raw, AuditEntry.fromJson);
  }

  Future<void> clearAudit() => _ch.invokeMethod<void>('clearAudit');

  /// 可授权的应用（只含桌面有图标的应用）。
  Future<List<PickableApp>> installedApps() async {
    final raw = await _ch.invokeMethod<Map<dynamic, dynamic>>('installedApps');
    return _parse(raw, PickableApp.fromJson);
  }

  /// 当前是否已配置访问密钥。
  ///
  /// 没有密钥时框架的 `/api/shell` 对**同设备所有应用**开放，
  /// 本页面的授权控制会被完全绕过 —— 界面必须据此给出警告。
  Future<bool> hasToken() async {
    final raw = await _ch.invokeMethod<Map<dynamic, dynamic>>('tokenState');
    return raw?['hasToken'] == true;
  }

  // ---------------- 解析 ----------------

  static List<T> _parse<T>(
    Map<dynamic, dynamic>? raw,
    T Function(Map<String, dynamic>) build,
  ) {
    final s = raw?['items'] as String?;
    if (s == null || s.isEmpty) return const [];
    final list = jsonDecode(s);
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((m) => build(m.cast<String, dynamic>()))
        .toList();
  }

  /// 图标是原生侧编好的 PNG（base64）。解码失败就返回 null，界面回退到占位图标。
  static Uint8List? decodeIcon(String? b64) {
    if (b64 == null || b64.isEmpty) return null;
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }
}

/// 一个已授权/待授权的应用。字段与原生 `BrokerProvider` 返回的 JSON 对应。
class AuthorizedApp {
  const AuthorizedApp({
    required this.pkg,
    required this.label,
    required this.uid,
    required this.sig,
    required this.icon,
    required this.grantedAt,
    required this.lastUsed,
    required this.calls,
  });

  final String pkg;
  final String label;
  final int uid;

  /// 签名哈希前 32 位 —— 界面上显示出来，让用户能核对「是不是同一个开发者」。
  final String sig;
  final Uint8List? icon;
  final DateTime? grantedAt;
  final DateTime? lastUsed;
  final int calls;

  factory AuthorizedApp.fromJson(Map<String, dynamic> j) => AuthorizedApp(
        pkg: j['pkg'] as String? ?? '',
        label: j['label'] as String? ?? '',
        uid: (j['uid'] as num?)?.toInt() ?? -1,
        sig: j['sig'] as String? ?? '',
        icon: AppAuthService.decodeIcon(j['icon'] as String?),
        grantedAt: _time(j['grantedAt']),
        lastUsed: _time(j['lastUsed']),
        calls: (j['calls'] as num?)?.toInt() ?? 0,
      );
}

class PendingApp {
  const PendingApp({
    required this.pkg,
    required this.label,
    required this.sig,
    required this.icon,
    required this.firstAt,
    required this.lastAt,
    required this.tries,
  });

  final String pkg;
  final String label;
  final String sig;
  final Uint8List? icon;
  final DateTime? firstAt;
  final DateTime? lastAt;

  /// 被拒绝/未授权的调用次数。
  final int tries;

  factory PendingApp.fromJson(Map<String, dynamic> j) => PendingApp(
        pkg: j['pkg'] as String? ?? '',
        label: j['label'] as String? ?? '',
        sig: j['sig'] as String? ?? '',
        icon: AppAuthService.decodeIcon(j['icon'] as String?),
        firstAt: _time(j['firstAt']),
        lastAt: _time(j['lastAt']),
        tries: (j['tries'] as num?)?.toInt() ?? 0,
      );
}

/// 「添加应用」列表里的一项。
class PickableApp {
  const PickableApp({
    required this.pkg,
    required this.label,
    required this.icon,
    required this.granted,
  });

  final String pkg;
  final String label;
  final Uint8List? icon;
  final bool granted;

  factory PickableApp.fromJson(Map<String, dynamic> j) => PickableApp(
        pkg: j['pkg'] as String? ?? '',
        label: j['label'] as String? ?? '',
        icon: AppAuthService.decodeIcon(j['icon'] as String?),
        granted: j['granted'] == true,
      );
}

/// 一条调用记录。
class AuditEntry {
  const AuditEntry({
    required this.time,
    required this.pkg,
    required this.cmd,
    required this.code,
    required this.exitCode,
    required this.ms,
  });

  final DateTime? time;
  final String pkg;
  final String cmd;

  /// OK / NEED_APPROVAL / REJECTED / FRAMEWORK_DOWN / NO_TOKEN / IO_ERROR …
  final String code;
  final int exitCode;
  final int ms;

  /// 是否真正执行成功（退出码 0 且通道正常）。
  bool get succeeded => code == 'OK' && exitCode == 0;

  factory AuditEntry.fromJson(Map<String, dynamic> j) => AuditEntry(
        time: _time(j['t']),
        pkg: j['pkg'] as String? ?? '',
        cmd: j['cmd'] as String? ?? '',
        code: j['code'] as String? ?? '',
        exitCode: (j['exit'] as num?)?.toInt() ?? -1,
        ms: (j['ms'] as num?)?.toInt() ?? 0,
      );
}

DateTime? _time(dynamic v) {
  final ms = (v as num?)?.toInt() ?? 0;
  if (ms <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(ms);
}
