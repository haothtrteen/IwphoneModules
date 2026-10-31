import 'package:flutter/services.dart';

import '../i18n/app_strings.dart';

/// 开机自启的当前状态快照（原生侧 `shellmgr/autostart` 的 `getStatus` 返回值）。
class AutostartStatus {
  const AutostartStatus({
    required this.enabled,
    required this.provisioned,
    required this.notifyGranted,
    required this.lastTime,
    required this.lastOk,
    required this.lastMsg,
    required this.port,
    required this.portFixed,
    required this.frameDir,
  });

  /// 用户是否开启了「开机自启」。
  final bool enabled;

  /// 是否已完成一次性配置（adb 密钥存在）。
  ///
  /// 注意：密钥存在 ≠ 已被 adbd 授权。真正能否连上要等执行一次才知道，
  /// 所以设置页把它显示为「已生成密钥」，而不是「已配置完成」。
  final bool provisioned;

  /// 是否已获得通知权限（Android 13+ 需运行时申请）。
  final bool notifyGranted;

  /// 上次自启尝试的时间（毫秒时间戳，0 = 从未执行）。
  final int lastTime;

  /// 上次自启是否成功。
  final bool lastOk;

  /// 上次自启的结果说明。
  final String lastMsg;

  /// 固定的 ADB TCP 端口。
  final int port;

  /// 端口是否已固定（persist.adb.tcp.port == port）。
  ///
  /// 自启能否成立看的是它，而不是此刻有没有监听 —— 只有它跨重启保持。
  final bool portFixed;

  /// 框架源目录（用于在界面上说明「会拉起什么」）。
  final String frameDir;

  /// 从未执行过自启。
  bool get neverRun => lastTime <= 0;

  /// 上次执行时间；从未执行时返回 null。
  DateTime? get lastRunAt => neverRun
      ? null
      : DateTime.fromMillisecondsSinceEpoch(lastTime);

  static const AutostartStatus unknown = AutostartStatus(
    enabled: false,
    provisioned: false,
    notifyGranted: false,
    lastTime: 0,
    lastOk: false,
    lastMsg: '',
    port: 5555,
    portFixed: false,
    frameDir: '',
  );

  factory AutostartStatus.fromMap(Map<dynamic, dynamic> m) {
    return AutostartStatus(
      enabled: m['enabled'] == true,
      provisioned: m['provisioned'] == true,
      notifyGranted: m['notifyGranted'] == true,
      lastTime: (m['lastTime'] as num?)?.toInt() ?? 0,
      lastOk: m['lastOk'] == true,
      lastMsg: (m['lastMsg'] as String?) ?? '',
      port: (m['port'] as num?)?.toInt() ?? 5555,
      portFixed: m['portFixed'] == true,
      frameDir: (m['frameDir'] as String?) ?? '',
    );
  }
}

/// 「开机自启」的 Dart 侧封装。
///
/// ## 这套机制为什么存在
///
/// iwphone 框架是 shell 脚本集合，以 **shell 身份**运行，本身没有任何自启能力。
/// 而 Android 上非 root 应用无法凭空获得 shell —— 必须借 ADB。
///
/// 本项目把一份 Android NDK 编译的 `adb` 可执行文件随 APK 携带
/// （打包为 `jniLibs/arm64-v8a/libadb.so`），由 App **自己连自己**：
///
/// 1. **一次性配置**（用户在设置页完成）
///    - 打开开发者选项里的「无线调试」，取配对码与配对端口
///    - [pair] 用配对码完成配对 → adbd 记住本 App 的公钥
///    - [ensurePort] 下发 `adb tcpip 5555`，把端口固定下来
/// 2. **每次开机**（全自动，无需用户操作）
///    - `adb tcpip 5555` 写下的 `persist.adb.tcp.port` 跨重启保持，
///      开机后 adbd 自动监听 `*:5555`
///    - 密钥同样跨重启保持，所以是**静默重认证**，不需要再配对
///    - App 连上后以 shell 身份拉起框架，并发通知告知用户
///
/// ## 已知约束
///
/// - **不能在本方案之外重启 adbd**（`adb usb` / `adb tcpip` / 开关无线调试）。
///   adbd 退出会清理自己 spawn 的进程树，框架会被连带杀掉 ——
///   即使框架已 reparent 到 init、且用了 setsid + nohup。
///   因此「拉起框架后再关掉 5555 端口」不可行。
/// - MIUI/HyperOS 默认拦截开机广播，需用户在系统的「自启动管理」里放行，
///   见 [openAutostartSettings]。
///
/// 实现走 Flutter 内置 MethodChannel，不引入任何第三方依赖；
/// 原生侧见 `android/.../AutostartChannel.kt` 与 `AdbBootstrap.kt`。
class AutostartService {
  AutostartService._();

  static final AutostartService instance = AutostartService._();

  static const MethodChannel _channel = MethodChannel('shellmgr/autostart');

  /// 查询状态。任何异常压平为 [AutostartStatus.unknown]。
  Future<AutostartStatus> status() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('getStatus');
      if (raw == null) return AutostartStatus.unknown;
      return AutostartStatus.fromMap(raw);
    } catch (_) {
      return AutostartStatus.unknown;
    }
  }

  /// 开关「开机自启」。开启时原生侧会顺带排一次任务，本次开机内即可见效。
  Future<bool> setEnabled(bool value) async {
    try {
      final raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('setEnabled', {'value': value});
      return raw?['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 申请通知权限（Android 13+ 才需要）。低版本直接返回 true。
  Future<bool> requestNotification() async {
    try {
      return await _channel.invokeMethod<bool>('requestNotification') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 用无线调试的配对码完成配对。
  ///
  /// [port] 是「使用配对码配对设备」界面上显示的**配对端口**，
  /// 不是无线调试主页那个连接端口。
  Future<({bool ok, String msg})> pair({
    required String port,
    required String code,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'pair',
        {'port': port, 'code': code},
      );
      return (ok: raw?['ok'] == true, msg: (raw?['msg'] as String?) ?? '');
    } catch (_) {
      return (ok: false, msg: AppStrings.t('service.callFailed'));
    }
  }

  /// 把 ADB 端口固定为 5555（下发 `adb tcpip`）。
  /// 这一步是整套自启的地基，不做的话重启后不会有 5555 可连。
  Future<({bool ok, String msg})> ensurePort() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('ensurePort');
      return (ok: raw?['ok'] == true, msg: (raw?['msg'] as String?) ?? '');
    } catch (_) {
      return (ok: false, msg: AppStrings.t('service.callFailed'));
    }
  }

  /// 立即执行一次自启流程（重认证 + 拉起框架）。
  /// 用于让用户当场验证配置是否有效，不必等到下次开机。
  Future<({bool ok, String msg, bool skipped})> runNow() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('runNow');
      return (
        ok: raw?['ok'] == true,
        msg: (raw?['msg'] as String?) ?? '',
        skipped: raw?['skipped'] == true,
      );
    } catch (_) {
      return (ok: false, msg: AppStrings.t('service.callFailed'), skipped: false);
    }
  }

  /// 框架是否已部署在设备上（以 Main.sh 是否存在为准）。
  Future<bool> frameworkInstalled() async {
    try {
      final raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('frameworkInstalled');
      return raw?['installed'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 部署 / 修复框架：把 APK 内置的框架包推到设备并解压。
  ///
  /// 幂等且可反复执行 —— 框架被改坏、被误删，再跑一次就是全新状态。
  /// 这是「用户全程不碰电脑」的关键一环：配对 → 部署 → 启动，闭环都在 App 里。
  ///
  /// 耗时可达一两分钟（12MB 传输 + 解压），调用方需显示进行中状态。
  Future<({bool ok, String msg})> deployFramework() async {
    try {
      final raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('deployFramework');
      return (ok: raw?['ok'] == true, msg: (raw?['msg'] as String?) ?? '');
    } catch (_) {
      return (ok: false, msg: AppStrings.t('service.callFailed'));
    }
  }

  /// 完全卸载框架（ADB 直连通道）。
  ///
  /// WebUI 不可达时（守护进程已停、框架接口没起来）HTTP 通道用不了，
  /// 这里直接以 shell 身份执行框架自带的 uninstall.sh，行为与 WebUI 通道一致：
  /// 先停 WebUI / 守护进程 / 全部模块，再删运行时目录、日志与状态镜像。
  Future<({bool ok, String msg})> uninstallFrameworkAdb() async {
    try {
      final raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('uninstallFramework');
      return (ok: raw?['ok'] == true, msg: (raw?['msg'] as String?) ?? '');
    } catch (_) {
      return (ok: false, msg: AppStrings.t('service.callFailed'));
    }
  }

  /// 发起「通知栏输入配对码」流程。
  ///
  /// 返回 `needPermission=true` 表示通知权限还没给（Android 13+），
  /// 调用方应先申请权限再重试一次。`ok=true` 时通知已发出，
  /// 用户填码提交后的配对结果会以通知形式反馈，页面回到前台后
  /// 重新拉 [status] 即可看到密钥状态变化。
  Future<({bool ok, bool needPermission, String msg})> startPairingFlow() async {
    try {
      final raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('startPairingFlow');
      return (
        ok: raw?['ok'] == true,
        needPermission: raw?['needPermission'] == true,
        msg: (raw?['msg'] as String?) ?? '',
      );
    } catch (_) {
      return (ok: false, needPermission: false, msg: AppStrings.t('service.callFailed'));
    }
  }

  /// 打开系统的开发者选项页（无线调试入口在这里）。
  Future<bool> openWirelessDebug() async {
    try {
      return await _channel.invokeMethod<bool>('openWirelessDebug') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 把 App 缓存里的模块包导入设备 module/ 目录（需已配对并连接）。
  Future<({bool ok, String msg})> importPackage({
    required String path,
    required String name,
  }) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'importPackage',
        {'path': path, 'name': name},
      );
      return (ok: raw?['ok'] == true, msg: (raw?['msg'] as String?) ?? '');
    } catch (_) {
      return (ok: false, msg: AppStrings.t('service.callFailed'));
    }
  }

  /// 打开模块自带 WebUI（App 内 WebView，注入 ksu 桥）。
  Future<bool> openModuleWebUI(String name) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'openModuleWebUI',
        {'name': name},
      );
      return raw?['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  // ---------------- 界面偏好：主题 / 语言 / 首次引导 ----------------

  /// 读取界面偏好。失败时返回默认值（跟随系统 / 未完成引导）。
  Future<
      ({
        String themeMode,
        String locale,
        bool onboardingDone,
        bool tokenPromptDismissed
      })> loadUiPrefs() async {
    try {
      final raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('loadUiPrefs');
      if (raw == null) {
        return (
          themeMode: 'system',
          locale: 'system',
          onboardingDone: false,
          tokenPromptDismissed: false,
        );
      }
      return (
        themeMode: (raw['themeMode'] as String?) ?? 'system',
        locale: (raw['locale'] as String?) ?? 'system',
        onboardingDone: raw['onboardingDone'] == true,
        tokenPromptDismissed: raw['tokenPromptDismissed'] == true,
      );
    } catch (_) {
      return (
        themeMode: 'system',
        locale: 'system',
        onboardingDone: false,
        tokenPromptDismissed: false,
      );
    }
  }

  /// 保存界面偏好（只传需要改的字段）。
  Future<void> saveUiPrefs({
    String? themeMode,
    String? locale,
    bool? onboardingDone,
    bool? tokenPromptDismissed,
  }) async {
    try {
      await _channel.invokeMethod<Map<dynamic, dynamic>>('saveUiPrefs', {
        if (themeMode != null) 'themeMode': themeMode,
        if (locale != null) 'locale': locale,
        if (onboardingDone != null) 'onboardingDone': onboardingDone,
        if (tokenPromptDismissed != null)
          'tokenPromptDismissed': tokenPromptDismissed,
      });
    } catch (_) {
      // 存不上不阻塞使用 —— 下次启动退回默认值
    }
  }

  /// 用系统浏览器打开链接（关于页的项目地址）。
  Future<bool> openUrl(String url) async {
    try {
      return await _channel.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
    } catch (_) {
      return false;
    }
  }

  // ---------------- WebUI 访问密钥（APatch 式：用户自己设）----------------

  /// 设备上是否已设访问密钥（决定 WebUI 现在能不能用）。
  Future<bool> webuiTokenSet() async {
    try {
      final raw =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('webuiTokenSet');
      return raw?['set'] == true;
    } catch (_) {
      return false;
    }
  }

  /// 设密钥：校验 → 暂存 → push 到设备（600）→ 复核；成功同时存本地。
  ///
  /// 密钥写进文件内容而不经过命令行参数，避免出现在 ps 里。
  Future<({bool ok, String msg})> setWebuiToken(String token) async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'setWebuiToken',
        {'token': token},
      );
      return (ok: raw?['ok'] == true, msg: (raw?['msg'] as String?) ?? '');
    } catch (_) {
      return (ok: false, msg: AppStrings.t('service.callFailed'));
    }
  }

  /// 读取 App 本地缓存的密钥（启动时用来配 X-Token 头）。
  Future<String> loadWebuiToken() async {
    try {
      final raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('loadWebuiToken');
      return (raw?['token'] as String?) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 清掉本地缓存（设备侧文件不动；用于密钥对不上时重置）。
  Future<void> clearWebuiToken() async {
    try {
      await _channel.invokeMethod<Map<dynamic, dynamic>>('clearWebuiToken');
    } catch (_) {
      // 忽略
    }
  }

  /// 跳系统的「自启动管理」页（MIUI/HyperOS 默认拦截开机广播）。
  Future<bool> openAutostartSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openAutostartSettings') ?? false;
    } catch (_) {
      return false;
    }
  }
}
