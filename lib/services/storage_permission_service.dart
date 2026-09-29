import 'package:flutter/services.dart';

/// 存储权限状态。
enum StoragePermissionStatus {
  /// 已获得（Android 11+ 表示「所有文件访问」已开启）
  granted,

  /// 未获得
  denied,

  /// 系统版本较低，无需该权限
  notRequired,
}

/// 「所有文件访问」权限的 Dart 侧封装。
///
/// 为什么需要它：iwphone 框架把模块状态镜像写在 `/sdcard/iwphone/state/`，
/// 该目录属主是框架侧（另一个 App）。在 Android 11+ 的 scoped storage 下，
/// 要读它必须持有 MANAGE_EXTERNAL_STORAGE —— 即系统设置里的「所有文件访问」。
///
/// 注意：该权限**无法通过运行时弹窗授予**，只能跳系统设置页由用户手动开启，
/// 因此 [request] 返回 true 仅代表「已把用户送去授权流程」，而非「已授权」。
/// 真实结果请在 App 回到前台后重新调用 [status] 查询。
///
/// 实现走 Flutter 内置 MethodChannel（`shellmgr/storage`），不引入第三方插件；
/// 原生侧见 `android/.../MainActivity.kt`。
class StoragePermissionService {
  StoragePermissionService._();

  static final StoragePermissionService instance = StoragePermissionService._();

  static const MethodChannel _channel = MethodChannel('shellmgr/storage');

  /// 查询当前状态。任何异常都压平成 [StoragePermissionStatus.denied]，
  /// 与项目其他 service「优雅失败、不上抛」的风格保持一致。
  Future<StoragePermissionStatus> status() async {
    try {
      final raw = await _channel.invokeMethod<String>('getStatus');
      switch (raw) {
        case 'granted':
          return StoragePermissionStatus.granted;
        case 'notRequired':
          return StoragePermissionStatus.notRequired;
        default:
          return StoragePermissionStatus.denied;
      }
    } catch (_) {
      return StoragePermissionStatus.denied;
    }
  }

  /// 发起授权。
  ///
  /// - Android 11+：跳系统设置页，返回 true 表示已成功跳转
  /// - Android 6–10：弹常规权限框，返回用户的选择结果
  /// - 更低版本：直接返回 true（无需申请）
  Future<bool> request() async {
    try {
      final ok = await _channel.invokeMethod<bool>('request');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 打开系统文件选择器，把选中的模块包复制进 App 缓存。
  ///
  /// 返回 `{ok, path, name}`：path 是缓存路径，交给
  /// [AutostartService.importPackage] 推到设备；name 是规范化后的文件名。
  Future<({bool ok, String path, String name, String msg})> pickFile() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('pickFile');
      return (
        ok: raw?['ok'] == true,
        path: (raw?['path'] as String?) ?? '',
        name: (raw?['name'] as String?) ?? '',
        msg: (raw?['msg'] as String?) ?? '',
      );
    } catch (_) {
      return (ok: false, path: '', name: '', msg: '调用失败');
    }
  }

  /// 是否已就绪（granted 或 notRequired）。用于决定是否还需提示用户授权。
  Future<bool> get isReady async {
    final s = await status();
    return s != StoragePermissionStatus.denied;
  }

  /// 该状态是否需要在界面上提醒用户去开启。
  static bool needsAttention(StoragePermissionStatus s) =>
      s == StoragePermissionStatus.denied;
}
