import 'dart:io';

/// 极简 shell 执行器 —— 不依赖任何第三方插件，直接用 `dart:io` 调用 `/system/bin/sh`。
///
/// 为什么不用 platform channel：本项目坚持零第三方依赖，
/// 而读取设备信息所需的命令（getprop / uname / ls）用普通 shell 就能完成，
/// 只有需要 root 的目录（`/data/adb`）才需要走 su。
class ShellExecutor {
  ShellExecutor._();

  static final ShellExecutor instance = ShellExecutor._();

  static const Duration defaultTimeout = Duration(seconds: 8);

  bool? _rooted;

  /// 执行 shell 命令并返回原始结果。
  ///
  /// 任何异常（命令不存在、超时、权限不足）都被压平成退出码 -1，
  /// 绝不向上抛异常 —— 设备环境差异很大，调用方不应为某条命令失败而崩溃。
  Future<ProcessResult> run(
    String command, {
    Duration timeout = defaultTimeout,
  }) async {
    try {
      return await Process.run('sh', ['-c', command]).timeout(timeout);
    } catch (_) {
      return ProcessResult(0, -1, '', '');
    }
  }

  /// 执行命令并返回 stdout 文本；退出码非 0、输出为空或异常时返回 null。
  Future<String?> text(
    String command, {
    Duration timeout = defaultTimeout,
  }) async {
    final result = await run(command, timeout: timeout);
    if (result.exitCode != 0) return null;
    final out = (result.stdout as String).trim();
    return out.isEmpty ? null : out;
  }

  /// 仅关心成功与否（不看输出）。用于 `test -e` 这类无输出只靠退出码的命令。
  Future<bool> ok(
    String command, {
    Duration timeout = defaultTimeout,
  }) async {
    final result = await run(command, timeout: timeout);
    return result.exitCode == 0;
  }

  /// 以 root 身份执行，返回 stdout 文本。未授权或失败返回 null。
  ///
  /// 注意：这里会真正触发一次 su 授权，因此搭配 [hasRoot] 的缓存使用，
  /// 避免同一会话内反复弹授权框。
  Future<String?> rootText(
    String command, {
    Duration timeout = defaultTimeout,
  }) async {
    return text(_asRoot(command), timeout: timeout);
  }

  /// 以 root 身份执行，只看成功与否。
  Future<bool> rootOk(
    String command, {
    Duration timeout = defaultTimeout,
  }) async {
    return ok(_asRoot(command), timeout: timeout);
  }

  /// 是否已获得 root。
  ///
  /// 必须真的用 su 执行 `id -u` 并拿回 0 才算通过 ——
  /// 仅判断 su 二进制是否存在并不可靠（不少 ROM 预装 su 但不会授权）。
  /// 结果缓存，避免反复触发授权弹窗。
  Future<bool> get hasRoot async {
    final cached = _rooted;
    if (cached != null) return cached;
    final uid = await rootText('id -u');
    _rooted = uid == '0';
    return _rooted!;
  }

  /// 清除 root 判定缓存（例如用户在 Magisk 里撤销了授权后重新进入应用）。
  void resetRootCache() => _rooted = null;

  /// 把命令包进 `su -c '...'`，并对单引号做 POSIX 转义。
  ///
  /// 不转义的话，命令里出现单引号就会截断，轻则失效，重则被拼接执行额外命令。
  static String _asRoot(String command) {
    final escaped = command.replaceAll("'", "'\\''");
    return "su -c '$escaped'";
  }
}
