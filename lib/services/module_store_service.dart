import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/module_catalog.dart';
import 'sha256.dart';

/// 云端模块库：从 GitHub 仓库拉取清单与模块包。
///
/// 三个约束叠在一起，决定了这里的写法：
/// 1. **零第三方依赖** —— 用 `dart:io` 的 HttpClient，不引 dio/http。
/// 2. **国内网络** —— `raw.githubusercontent.com` 经常连不上，所以准备了一组
///    镜像，按「国内可达性」排序，逐个试，第一个成功就用它。
/// 3. **完整性** —— 清单里带 sha256，下载后必须校验，不匹配就拒绝安装。
class ModuleStoreService {
  ModuleStoreService._();
  static final ModuleStoreService instance = ModuleStoreService._();

  /// 清单与模块包的来源仓库。
  static const String repo = 'haothtrteen/IwphoneModules';
  static const String branch = 'main';

  /// 仓库根目录里的清单文件名。
  static const String catalogFile = 'modules.catalog.json';

  /// 镜像前缀，按"国内大概率能用"排序；官方 raw 放最后兜底。
  ///
  /// 2026-11 实测（国内网络）：
  /// - `gh-proxy.com`  ✅ 200
  /// - `jsdelivr`      ✅ 200（只认仓库里的静态文件，够用）
  /// - `raw.githubusercontent.com` ❌ 被解析到 127.0.0.1，但失败得很快，留作兜底
  /// 曾经加过 `raw.gitmirror.com`，现已 DNS 不解析，删掉免得白等超时。
  static final List<String> mirrorBases = [
    'https://gh-proxy.com/https://raw.githubusercontent.com/$repo/$branch/',
    'https://cdn.jsdelivr.net/gh/$repo@$branch/',
    'https://raw.githubusercontent.com/$repo/$branch/',
  ];

  /// 上一次成功使用的镜像前缀，下次优先生效，省掉一轮试探。
  String? lastGoodBase;

  ModuleCatalog? _cached;
  DateTime? _cachedAt;

  /// 内存缓存的有效期。清单更新不频繁，5 分钟足够。
  static const Duration _cacheTtl = Duration(minutes: 5);

  /// 拉取清单。失败返回 null 并把原因写进 [lastError]。
  Future<ModuleCatalog?> loadCatalog({bool refresh = false}) async {
    if (!refresh &&
        _cached != null &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < _cacheTtl) {
      return _cached;
    }

    final bytes = await _fetch(catalogFile, timeout: const Duration(seconds: 8));
    if (bytes == null) {
      lastError = 'catalog';
      return null;
    }
    try {
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final catalog = ModuleCatalog.fromJson(json);
      _cached = catalog;
      _cachedAt = DateTime.now();
      lastError = '';
      return catalog;
    } catch (_) {
      lastError = 'parse';
      return null;
    }
  }

  /// 最近一次失败的原因：`catalog` / `parse` / `download` / `checksum` / 空串。
  String lastError = '';

  /// 下载模块包并校验完整性。
  ///
  /// 返回 null 表示失败，原因见 [lastError]。
  Future<Uint8List?> downloadModule(StoreModule module) async {
    final bytes =
        await _fetch(module.packagePath, timeout: const Duration(seconds: 30));
    if (bytes == null) {
      lastError = 'download';
      return null;
    }
    if (module.sha256.isNotEmpty) {
      final actual = Sha256.hex(bytes);
      if (actual != module.sha256) {
        lastError = 'checksum';
        return null;
      }
    }
    lastError = '';
    return bytes;
  }

  /// 本次运行中已经确认不通的镜像，后续直接跳过，避免每次都白等超时。
  final Set<String> _deadBases = {};

  /// 逐个镜像尝试，第一个成功的返回内容。
  Future<Uint8List?> _fetch(String relativePath, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final bases = <String>[
      if (lastGoodBase != null && !_deadBases.contains(lastGoodBase))
        lastGoodBase!,
      ...mirrorBases.where(
        (b) => b != lastGoodBase && !_deadBases.contains(b),
      ),
    ];

    for (final base in bases) {
      final client = HttpClient()
        ..connectionTimeout = timeout
        ..userAgent = 'ShellManager';
      try {
        final uri = Uri.parse('$base$relativePath');
        final request = await client.getUrl(uri).timeout(timeout);
        request.headers.set(HttpHeaders.acceptHeader, '*/*');
        final response = await request.close().timeout(timeout);
        if (response.statusCode ~/ 100 != 2) {
          await response.drain<void>();
          _deadBases.add(base);
          continue;
        }
        final builder = BytesBuilder(copy: false);
        await for (final chunk in response.timeout(timeout)) {
          builder.add(chunk);
        }
        final bytes = builder.takeBytes();
        if (bytes.isNotEmpty) {
          lastGoodBase = base;
          _deadBases.remove(base);
          return bytes;
        }
        _deadBases.add(base);
      } catch (_) {
        // 换下一个镜像，不在这里报错
        _deadBases.add(base);
      } finally {
        client.close(force: true);
      }
    }
    return null;
  }

  /// 清掉内存缓存（下拉刷新时用）。
  void invalidate() {
    _cached = null;
    _cachedAt = null;
    // 手动刷新时给所有镜像一次翻身的机会（网络环境可能刚变过）
    _deadBases.clear();
  }
}
