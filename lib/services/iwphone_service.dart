import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/iwphone_module.dart';

/// iwphone modrunner v3 客户端：WebUI HTTP API 优先，sdcard 状态镜像兜底。
///
/// 设计原则：
/// 1. **零第三方依赖**：用 `dart:io` `HttpClient`，与 [ShellExecutor] 风格一致。
/// 2. **优雅失败**：WebUI 不可达 / 模块不存在 / 超时，全部压平成 `null` 或空列表，
///    调用方按需显示提示，绝不上抛异常。
/// 3. **可测试**：JSON 解析独立为 `parseStatus / parseModules` 静态方法。
class IwphoneService {
  IwphoneService._();
  static final IwphoneService instance = IwphoneService._();

  /// WebUI 默认端口与路径，与 webui_server.py 一致。
  static const String defaultHost = '127.0.0.1';
  static const int defaultPort = 8537;
  static const Duration defaultTimeout = Duration(seconds: 3);

  /// 默认 sdcard 镜像路径。`/sdcard/iwphone/state/` 是 sync.sh 写入的目标，
  /// 模块 prop 在 `state/work/<name>/iwphone.prop`。
  static const String defaultSdcardStateRoot = '/sdcard/iwphone/state';
  static const String defaultSdcardLogRoot = '/sdcard/iwphone/logs';

  String _host = defaultHost;
  int _port = defaultPort;
  String _token = '';
  Duration _timeout = defaultTimeout;

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2)
    ..idleTimeout = const Duration(seconds: 5);

  /// 是否曾检测到 WebUI 不可达（短缓存避免每次发起请求）。
  bool _knownUnavailable = false;

  // ---------------- 配置 ----------------

  void configure({String? host, int? port, String? token, Duration? timeout}) {
    if (host != null) _host = host;
    if (port != null) _port = port;
    if (token != null) _token = token;
    if (timeout != null) _timeout = timeout;
  }

  /// 强制下次重新探测 WebUI（用户手动点重试）。
  void invalidate() {
    _knownUnavailable = false;
  }

  String get baseUrl => 'http://$_host:$_port';

  // ---------------- WebUI HTTP ----------------

  /// 探测 WebUI 是否在线。失败立即返回 false（不抛异常）。
  ///
  /// 仅做最轻量的 `GET /api/status` 探测：用 2s connection timeout，
  /// 已知不可达时直接跳过，避免每次进页面都跑满 3s。
  Future<bool> checkAvailable() async {
    if (_knownUnavailable) return false;
    try {
      final res = await _getJson('/api/status');
      if (res != null) {
        return true;
      }
    } catch (_) {
      // 计时器超时 / socket 拒绝 / 等
    }
    _knownUnavailable = true;
    return false;
  }

  /// 拉取整体状态，失败返回 [IwphoneStatus.unavailable]。
  Future<IwphoneStatus> getStatus() async {
    final json = await _getJson('/api/status');
    if (json == null) {
      _knownUnavailable = true;
      return IwphoneStatus.unavailable;
    }
    return IwphoneStatus.fromJson(json);
  }

  /// 列出已安装模块，失败回退 sdcard 镜像。
  ///
  /// WebUI 优先（带 running 状态）；不可达时扫 `/sdcard/iwphone/state/work/*/iwphone.prop`。
  Future<List<IwphoneModule>> listModules() async {
    final json = await _getJson('/api/modules');
    if (json != null) {
      final list = (json['modules'] as List?) ?? const [];
      return list
          .whereType<Map>()
          .map((m) => IwphoneModule.fromJson(m.cast<String, dynamic>()))
          .toList();
    }
    _knownUnavailable = true;
    return _readModulesFromSdcard();
  }

  /// 列出可安装 .iwp 包（来自框架 `module/` 目录）。
  Future<List<IwphonePackage>> listPackages() async {
    final json = await _getJson('/api/packages');
    if (json == null) {
      _knownUnavailable = true;
      return const [];
    }
    final list = (json['packages'] as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((p) => IwphonePackage.fromJson(p.cast<String, dynamic>()))
        .toList();
  }

  /// 拉取模块日志；type=log 取执行概览，type=out/err 取原始 stdout/stderr 尾部。
  Future<String> moduleLog(String name, IwphoneLogKind kind, {int tail = 200}) async {
    final qs = '?type=${kind.queryValue}&tail=$tail';
    final json = await _getJson('/api/module/$name/log$qs');
    if (json != null) {
      final text = json['text'];
      if (text is String) return text;
    }
    _knownUnavailable = true;
    // 兜底：直接从 sdcard 日志目录读尾部
    return _tailFile('$defaultSdcardLogRoot/modules/$name/$name.${kind.queryValue}', tail);
  }

  /// 清空日志内容（后端是**截断**而非删除，正在运行的模块不受影响）。
  ///
  /// [framework] 为 true 时清框架守护日志；否则清 [moduleId] 的日志。
  /// [kind] 传 null 表示清该模块的全部日志（含 launcher.log）。
  Future<({bool ok, String msg})> clearLogs({
    required bool framework,
    String? moduleId,
    IwphoneLogKind? kind,
  }) async {
    final buf = StringBuffer('/api/log/clear?scope=');
    buf.write(framework ? 'runner' : 'module');
    if (!framework && moduleId != null) {
      buf.write('&name=${Uri.encodeQueryComponent(moduleId)}');
    }
    if (!framework && kind != null) {
      buf.write('&kind=${kind.queryValue}');
    }
    final body = await _request('POST', buf.toString());
    if (body == null) return (ok: false, msg: 'WebUI 不可达，无法清空日志');
    return _parseOkMsg(body);
  }

  /// 导出日志副本到设备 `/sdcard/Download/iwphone_logs/`。
  ///
  /// 复制动作由 WebUI（root）完成 —— App 进程是 untrusted_app，
  /// 自己写 Download 目录需要额外存储权限，交给 root 侧更稳。
  /// 成功时 [path] 返回落盘路径，便于提示用户去哪儿找。
  Future<({bool ok, String msg, String path})> exportLog({
    required bool framework,
    String? moduleId,
    IwphoneLogKind kind = IwphoneLogKind.log,
  }) async {
    final buf = StringBuffer('/api/log/export?scope=');
    buf.write(framework ? 'runner' : 'module');
    if (!framework && moduleId != null) {
      buf.write('&name=${Uri.encodeQueryComponent(moduleId)}');
      buf.write('&kind=${kind.queryValue}');
    }
    final body = await _request('POST', buf.toString());
    if (body == null) {
      return (ok: false, msg: 'WebUI 不可达，无法导出日志', path: '');
    }
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      return (
        ok: json['ok'] == true,
        msg: (json['msg'] as String?) ?? '',
        path: (json['path'] as String?) ?? '',
      );
    } catch (_) {
      return (ok: false, msg: '响应解析失败', path: '');
    }
  }

  // ---------------- 控制（仅 WebUI，失败返回 false） ----------------

  /// 守护进程启停。后端 restart 内含 2 秒等待（要等 PID 文件释放），
  /// 加上进程启动时间，3 秒默认超时不够用。
  static const Duration _runnerTimeout = Duration(seconds: 30);

  Future<bool> runnerStart() =>
      _postOk('/api/runner/start', timeout: _runnerTimeout);
  Future<bool> runnerStop() =>
      _postOk('/api/runner/stop', timeout: _runnerTimeout);

  /// 重启守护进程（后端行为：先停后启，中间留出释放 PID/锁的间隔）。
  /// 会中断当前的轮询周期，但已启动的模块不受影响。
  Future<bool> runnerRestart() =>
      _postOk('/api/runner/restart', timeout: _runnerTimeout);

  /// 读取模块的通用配置（声明 + 当前值）。
  ///
  /// 模块没有 config.prop 时返回 `has=false`，调用方据此决定是否显示配置入口。
  Future<ModuleConfig?> moduleConfig(String name) async {
    try {
      final body = await _request(
        'GET',
        '/api/module/${Uri.encodeComponent(name)}/config',
      );
      if (body == null) return null;
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;
      return ModuleConfig.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  /// 保存模块配置。
  ///
  /// 只传需要改动的键即可，后端会用 spec 校验并忽略未声明的键。
  Future<({bool ok, String msg})> setModuleConfig(
    String name,
    Map<String, String> values,
  ) async {
    final q = StringBuffer();
    var first = true;
    for (final e in values.entries) {
      q.write(first ? '?' : '&');
      first = false;
      q.write('${Uri.encodeQueryComponent(e.key)}='
          '${Uri.encodeQueryComponent(e.value)}');
    }
    try {
      final body = await _request(
        'POST',
        '/api/module/${Uri.encodeComponent(name)}/config$q',
        timeout: const Duration(seconds: 15),
      );
      if (body == null) return (ok: false, msg: 'WebUI 不可达');
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['ok'] == true) {
        return (ok: true, msg: (decoded['msg'] as String?) ?? '已保存');
      }
      return (
        ok: false,
        msg: (decoded is Map ? decoded['msg'] as String? : null) ?? '保存失败',
      );
    } catch (_) {
      return (ok: false, msg: '保存失败');
    }
  }

  /// 启动模块。
  ///
  /// 超时给到 15 秒（默认只有 3 秒）：后端要先分离进程、再轮询锁确认模块
  /// 真的起来了才返回（通常 1 秒内，但慢设备上可能更久）。
  /// 用默认的 3 秒会太紧 —— 表现就是「模块其实起来了，App 却报启动失败」。
  Future<bool> moduleStart(String name) => _postOk(
        '/api/module/$name/run',
        timeout: const Duration(seconds: 15),
      );

  /// 执行模块的「动作」（action.sh，Magisk/KernelSU/AxManager 式模块）。
  /// 一次性任务，同步执行；输出通过 [moduleActionResult] 拉取太绕，
  /// 这里直接返回 ok 与输出文本。
  Future<({bool ok, String msg})> runModuleAction(String name) async {
    try {
      final body = await _request(
        'POST',
        '/api/module/${Uri.encodeComponent(name)}/action',
        timeout: const Duration(seconds: 70),
      );
      if (body == null) return (ok: false, msg: 'WebUI 不可达');
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['ok'] == true) {
        return (ok: true, msg: (decoded['msg'] as String?) ?? '已执行');
      }
      return (
        ok: false,
        msg: (decoded is Map ? decoded['msg'] as String? : null) ?? '执行失败',
      );
    } catch (_) {
      return (ok: false, msg: '执行失败');
    }
  }

  /// 读取模块快照（还原前预览用）。
  ///
  /// 返回每项的资源名、当前值、还原指令、是否可自动还原 ——
  /// 用户点「还原」之前能看清到底会改什么，而不是盲还原。
  Future<({bool ok, String msg, List<SnapshotItem> items})> moduleSnapshot(
    String name,
  ) async {
    try {
      final body = await _request(
        'GET',
        '/api/module/${Uri.encodeComponent(name)}/snapshot',
        timeout: const Duration(seconds: 30),
      );
      if (body == null) return (ok: false, msg: 'WebUI 不可达', items: <SnapshotItem>[]);
      final decoded = jsonDecode(body);
      if (decoded is! Map || decoded['ok'] != true) {
        return (
          ok: false,
          msg: (decoded is Map ? decoded['msg'] as String? : null) ?? '读取失败',
          items: <SnapshotItem>[],
        );
      }
      final list = (decoded['items'] as List? ?? [])
          .whereType<Map>()
          .map((e) => SnapshotItem.fromJson(e.cast<String, dynamic>()))
          .toList();
      return (ok: true, msg: '', items: list);
    } catch (_) {
      return (ok: false, msg: '读取快照失败', items: <SnapshotItem>[]);
    }
  }

  /// 列出所有快照（含已卸载模块留下的「孤儿快照」）。
  ///
  /// 孤儿快照是兜底的关键：模块被卸载了，但它改过的设置仍能还原 ——
  /// 前提是这些快照找得到。
  Future<({bool ok, String msg, List<SnapshotInfo> items})> listSnapshots() async {
    try {
      final body = await _request('GET', '/api/snapshots',
          timeout: const Duration(seconds: 20));
      if (body == null) {
        return (ok: false, msg: 'WebUI 不可达', items: <SnapshotInfo>[]);
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map || decoded['ok'] != true) {
        return (ok: false, msg: '读取失败', items: <SnapshotInfo>[]);
      }
      final list = (decoded['items'] as List? ?? [])
          .whereType<Map>()
          .map((e) => SnapshotInfo.fromJson(e.cast<String, dynamic>()))
          .toList();
      return (ok: true, msg: '', items: list);
    } catch (_) {
      return (ok: false, msg: '读取快照列表失败', items: <SnapshotInfo>[]);
    }
  }

  /// 删除某个快照（用户确认不再需要还原时清理）。
  Future<({bool ok, String msg})> deleteSnapshot(String name) async {
    try {
      final body = await _request(
        'POST',
        '/api/snapshot/${Uri.encodeComponent(name)}/delete',
        timeout: const Duration(seconds: 20),
      );
      if (body == null) return (ok: false, msg: 'WebUI 不可达');
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['ok'] == true) {
        return (ok: true, msg: (decoded['msg'] as String?) ?? '已删除');
      }
      return (
        ok: false,
        msg: (decoded is Map ? decoded['msg'] as String? : null) ?? '删除失败',
      );
    } catch (_) {
      return (ok: false, msg: '删除失败');
    }
  }

  /// 还原模块快照：把该系统资源恢复到模块首次写入前的原值。
  ///
  /// 服务端会**先停模块再还原** —— 常驻模块的守卫循环会周期性把值改回去，
  /// 不停就还原等于白还原。
  Future<({bool ok, String msg})> restoreModuleSnapshot(String name) async {
    try {
      final body = await _request(
        'POST',
        '/api/module/${Uri.encodeComponent(name)}/restore',
        timeout: const Duration(seconds: 130),
      );
      if (body == null) return (ok: false, msg: 'WebUI 不可达');
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['ok'] == true) {
        return (ok: true, msg: (decoded['msg'] as String?) ?? '已还原');
      }
      return (
        ok: false,
        msg: (decoded is Map ? decoded['msg'] as String? : null) ?? '还原失败',
      );
    } catch (_) {
      return (ok: false, msg: '还原失败');
    }
  }

  /// 停止模块。停止要走框架的 stop 流程（可能涉及等待进程退出），同样放宽。
  Future<bool> moduleStop(String name) => _postOk(
        '/api/module/$name/stop',
        timeout: const Duration(seconds: 15),
      );

  /// 安装 / 重装模块。
  /// 后端 mod_install.sh 用 `unzip -o` 覆盖解压，因此对已存在的模块
  /// 重复执行即为「重装」，无需单独接口。解压耗时随包大小增长，给 60 秒。
  Future<bool> moduleInstall(String name) => _postOk(
        '/api/module/$name/install',
        timeout: const Duration(seconds: 60),
      );

  /// 卸载模块：停止 → 删除模块目录 → 清理锁 / 触发文件 / 日志。
  /// **不可撤销**，调用方必须先做二次确认。
  Future<bool> moduleUninstall(String name) => _postOk(
        '/api/module/$name/uninstall',
        timeout: const Duration(seconds: 30),
      );

  /// 触发一次执行区 → /sdcard 状态镜像同步。
  /// 需遍历模块目录，模块多时较慢，放宽到 60 秒。
  Future<bool> triggerSync() =>
      _postOk('/api/sync', timeout: const Duration(seconds: 60));

  // ---------------- 框架配置（env.sh 白名单项） ----------------

  /// 读取框架可配置项及其当前值。
  Future<List<IwphoneConfigItem>> getConfig() async {
    final json = await _getJson('/api/config');
    if (json == null) {
      _knownUnavailable = true;
      return const [];
    }
    final list = (json['items'] as List?) ?? const [];
    return list
        .whereType<Map>()
        .map((e) => IwphoneConfigItem.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  /// 修改一项配置，返回是否成功与提示文本。
  Future<({bool ok, String msg})> setConfig(String key, String value) async {
    final body = await _request(
      'POST',
      '/api/config?key=${Uri.encodeComponent(key)}'
      '&value=${Uri.encodeComponent(value)}',
    );
    if (body == null) return (ok: false, msg: 'WebUI 不可达');
    return _parseOkMsg(body);
  }

  // ---------------- 内置终端 ----------------

  /// 执行一条 shell 命令。
  /// 框架侧会做黑名单拦截与超时限制，因此这里不需要再过滤。
  Future<ShellResult> runShell(
    String cmd, {
    String? cwd,
    int? timeoutSec,
  }) async {
    final qs = StringBuffer('/api/shell?cmd=${Uri.encodeComponent(cmd)}');
    if (cwd != null && cwd.isNotEmpty) {
      qs.write('&cwd=${Uri.encodeComponent(cwd)}');
    }
    if (timeoutSec != null) qs.write('&timeout=$timeoutSec');

    final body = await _request('POST', qs.toString());
    if (body == null) {
      return const ShellResult(
        ok: false,
        message: 'WebUI 不可达（服务未启动，或框架已被卸载）',
      );
    }
    try {
      return ShellResult.fromJson(jsonDecode(body) as Map<String, dynamic>);
    } catch (_) {
      return const ShellResult(ok: false, message: '响应解析失败');
    }
  }

  // ---------------- 框架运行日志 ----------------

  /// 框架自身日志：守护扫描、模块启动、超时强杀、黑名单拒绝等。
  /// 与 [moduleLog] 的区别是这里不限定某个模块。
  Future<String> runnerLog({int tail = 200}) async {
    final json = await _getJson('/api/runner/log?tail=$tail');
    if (json == null) {
      _knownUnavailable = true;
      return '';
    }
    return (json['text'] as String?) ?? '';
  }

  // ---------------- 资源冲突 ----------------

  /// 拉取冲突报告：冲突记录 + 资源占用图。
  /// WebUI 不可达时返回 [ConflictReport.empty]。
  Future<ConflictReport> getConflicts({int tail = 200}) async {
    final json = await _getJson('/api/conflicts?tail=$tail');
    if (json == null) {
      _knownUnavailable = true;
      return ConflictReport.empty;
    }
    return ConflictReport.fromJson(json);
  }

  /// 仅拉取资源占用图（不含日志）。
  Future<List<ResourceUsage>> getResources() async {
    final json = await _getJson('/api/resources');
    if (json == null) {
      _knownUnavailable = true;
      return const [];
    }
    final list = json['resources'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => ResourceUsage.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  // ---------------- 模块批量控制 ----------------

  /// 按锁逐个正常停止全部模块（会写模块日志）。
  Future<BulkResult> stopAllModules() => _bulk('/api/modules/stop-all');

  /// 强制停止全部模块进程 —— 不依赖锁，直接终止进程树。
  /// 用于锁丢失、模块脱离框架管理的情况。
  Future<BulkResult> forceStopAllModules() =>
      _bulk('/api/modules/force-stop-all');

  /// 重启全部「原先在运行」的模块（先强制全停，再逐个拉起）。
  Future<BulkResult> restartAllModules() => _bulk('/api/modules/restart-all');

  // ---------------- 整体卸载框架 ----------------

  /// 卸载整个框架：删除运行时目录（模块/锁/触发文件）、日志与状态镜像。
  /// **不可撤销**；后端延迟 3 秒执行，之后 App 会与 WebUI 断开。
  Future<({bool ok, String msg})> uninstallFramework() async {
    final body = await _request('POST', '/api/uninstall');
    if (body == null) return (ok: false, msg: 'WebUI 不可达');
    return _parseOkMsg(body);
  }

  // ---------------- 内部工具 ----------------

  /// 解析形如 `{"ok": bool, "msg": "..."}` 的响应。
  ({bool ok, String msg}) _parseOkMsg(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      return (ok: json['ok'] == true, msg: (json['msg'] as String?) ?? '');
    } catch (_) {
      return (ok: false, msg: '响应解析失败');
    }
  }

  Future<BulkResult> _bulk(String path) async {
    // 批量操作要逐个停/启所有模块，后端还会 sleep 等待，给足 60 秒
    final body = await _request('POST', path,
        timeout: const Duration(seconds: 60));
    if (body == null) {
      return const BulkResult(ok: false, message: 'WebUI 不可达');
    }
    try {
      return BulkResult.fromJson(jsonDecode(body) as Map<String, dynamic>);
    } catch (_) {
      return const BulkResult(ok: false, message: '响应解析失败');
    }
  }

  // ---------------- HTTP 包装 ----------------

  Future<Map<String, dynamic>?> _getJson(String path) async {
    try {
      final body = await _request('GET', path);
      if (body == null) return null;
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _postOk(String path, {Duration? timeout}) async {
    try {
      final body = await _request('POST', path, timeout: timeout);
      if (body == null) return false;
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['ok'] == true) return true;
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _request(String method, String path, {Duration? timeout}) async {
    final t = timeout ?? _timeout;
    final url = Uri.parse('$baseUrl$path');
    try {
      final request = await _client.openUrl(method, url).timeout(t);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (_token.isNotEmpty) {
        request.headers.set('X-Token', _token);
      }
      final response = await request.close().timeout(t);
      if (response.statusCode ~/ 100 != 2) {
        return null;
      }
      final body = await response.transform(utf8.decoder).join();
      return body.isEmpty ? null : body;
    } on TimeoutException {
      return null;
    } on SocketException {
      return null;
    } on HttpException {
      return null;
    } on HandshakeException {
      return null;
    } catch (_) {
      return null;
    }
  }

  // ---------------- sdcard 兜底 ----------------

  /// 解析 sdcard 镜像目录列表文本。
  ///
  /// 输入形如
  /// ```
  /// dir|work1
  /// file|work1/iwphone.prop
  /// file|work2/iwphone.prop
  /// ```
  /// 由 `ls -la` 在 [ShellExecutor] 之外执行；这里只负责解析与找 prop 内容。
  /// 拆成纯函数，便于脱离设备做单元测试。
  static List<IwphoneModule> parseModulesFromSdcardListing(
    String listing,
    Map<String, String> propFiles,
  ) {
    final result = <IwphoneModule>[];
    for (final entry in listing.split('\n')) {
      final parts = entry.split('|');
      if (parts.length < 2) continue;
      if (parts[0] != 'dir') continue;
      final dirName = parts[1].split('/').last;
      if (dirName.isEmpty) continue;
      final propKey = 'work/$dirName/iwphone.prop';
      final prop = propFiles[propKey];
      if (prop == null) continue;
      result.add(IwphoneModule.fromProp(dirName, prop));
    }
    result.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return result;
  }

  Future<List<IwphoneModule>> _readModulesFromSdcard() async {
    // sdcard 读用普通 shell 即可（不需要 root）。
    // 用 `ls` 抓目录/文件清单，再按 prop 路径 cat。
    // 用普通字符串 + \$ 转义，避免 raw string 里 \" 提前闭合。
    final dirLister = await Process.run('sh', [
      '-c',
      'cd "$defaultSdcardStateRoot" 2>/dev/null && ls -la work 2>/dev/null | '
          "awk '{print \$1\"|\"\$NF}'",
    ]).timeout(const Duration(seconds: 4));
    if (dirLister.exitCode != 0) return const [];
    final listing = (dirLister.stdout as String).trim();

    // 提取候选目录名
    final dirs = <String>[];
    for (final line in listing.split('\n')) {
      final parts = line.split('|');
      if (parts.length < 2) continue;
      if (parts[0].startsWith('d')) {
        final n = parts[1];
        if (n.isEmpty || n == '.' || n == '..') continue;
        dirs.add(n);
      }
    }

    if (dirs.isEmpty) return const [];

    // 一次性 cat 所有 prop 文件
    final expr = dirs
        .map((d) => '[ -f "work/$d/iwphone.prop" ] && echo "===work/$d/iwphone.prop===" && cat "work/$d/iwphone.prop"')
        .join(' ; ');
    final catRes = await Process.run('sh', [
      '-c',
      'cd "$defaultSdcardStateRoot" 2>/dev/null && $expr',
    ]).timeout(const Duration(seconds: 4));
    if (catRes.exitCode != 0) return const [];

    final propFiles = splitPropFiles((catRes.stdout as String));
    return parseModulesFromSdcardListing(
      dirs.map((d) => 'dir|work/$d').join('\n'),
      propFiles,
    );
  }

  /// 把单次 cat 输出按 `===path===` 头切回 (path -> content) 字典。
  ///
  /// 仅做字符串拆分，可独立单测。
  static Map<String, String> splitPropFiles(String raw) {
    final result = <String, String>{};
    final lines = raw.split('\n');
    String? currentPath;
    final buf = <String>[];
    for (final line in lines) {
      if (line.startsWith('===') && line.endsWith('===')) {
        if (currentPath != null) {
          result[currentPath] = buf.join('\n');
        }
        currentPath = line.substring(3, line.length - 3);
        buf.clear();
      } else if (currentPath != null) {
        buf.add(line);
      }
    }
    if (currentPath != null) {
      result[currentPath] = buf.join('\n');
    }
    return result;
  }

  /// sdcard 单文件 tail。不存在或读取失败返回空串。
  static Future<String> _tailFile(String path, int n) async {
    try {
      final res = await Process.run('sh', [
        '-c',
        'tail -n $n "$path" 2>/dev/null',
      ]).timeout(const Duration(seconds: 2));
      if (res.exitCode != 0) return '';
      return (res.stdout as String).trim();
    } catch (_) {
      return '';
    }
  }
}

/// 快照里的一项：某个系统资源的还原信息。
class SnapshotItem {
  const SnapshotItem({
    required this.resource,
    required this.cmd,
    required this.current,
    required this.restorable,
  });

  /// 资源名，如 `global.window_animation_scale`。
  final String resource;

  /// 还原指令（原样执行）。
  final String cmd;

  /// 该资源当前的值。
  final String current;

  /// 能否自动还原（false = 模块用了沙箱拦不到的写法）。
  final bool restorable;

  factory SnapshotItem.fromJson(Map<String, dynamic> json) => SnapshotItem(
        resource: (json['resource'] as String?) ?? '',
        cmd: (json['cmd'] as String?) ?? '',
        current: (json['current'] as String?) ?? '',
        restorable: json['restorable'] == true,
      );

  /// 从还原指令里抽出「将还原为」的值，用于界面展示。
  String get targetValue {
    // settings put <ns> <k> 'V'  → V
    final put = RegExp(r"settings put \S+ \S+ '([^']*)'").firstMatch(cmd);
    if (put != null) return put.group(1) ?? '';
    if (cmd.contains('settings delete')) return '（删除该项）';
    if (cmd.startsWith('setprop')) {
      final sp = RegExp(r"setprop \S+ '([^']*)'").firstMatch(cmd);
      if (sp != null) return sp.group(1) ?? '';
    }
    if (cmd.startsWith('#')) return '需手动处理';
    return '按指令还原';
  }
}

/// 快照列表里的一项（用于「历史快照」页面）。
class SnapshotInfo {
  const SnapshotInfo({
    required this.name,
    required this.restorable,
    required this.skipped,
    required this.orphan,
    required this.mtime,
  });

  final String name;
  final int restorable;
  final int skipped;

  /// true = 对应模块已被卸载（孤儿快照），是兜底最需要保住的那种。
  final bool orphan;
  final int mtime;

  factory SnapshotInfo.fromJson(Map<String, dynamic> json) => SnapshotInfo(
        name: (json['name'] as String?) ?? '',
        restorable: (json['restorable'] as num?)?.toInt() ?? 0,
        skipped: (json['skipped'] as num?)?.toInt() ?? 0,
        orphan: json['orphan'] == true,
        mtime: (json['mtime'] as num?)?.toInt() ?? 0,
      );
}
