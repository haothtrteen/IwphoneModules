import '../i18n/app_strings.dart';
import 'autostart_service.dart';
import 'iwphone_service.dart';

/// WebUI 访问密钥管理（APatch 式：用户自己设密钥）。
///
/// ## 为什么必须要有密钥
///
/// 框架的 WebUI 上挂着 `/api/shell`（以 shell 身份执行命令，等价 ADB 权限），
/// 而它监听在 `127.0.0.1` —— **同设备上任何有网络权限的应用都能访问**。
/// 没有密钥就等于把这套权限挂在环回口上裸奔。
///
/// ## 密钥存在两处，必须一致
///
/// - 设备侧 `state/webui_token`（600、shell 属主）—— 服务端据此鉴权，
///   按 mtime 读取，所以**改密钥不用重启 WebUI**
/// - App 私有 SharedPreferences —— 每次请求带 `X-Token` 头
///
/// App 进程本身读不到设备侧那个文件（600），只能经 adb（shell 身份）读写 ——
/// 这让「拿到密钥」天然依赖「已完成配对」，符合最小权限原则。
class WebuiTokenManager {
  WebuiTokenManager._();

  static final WebuiTokenManager instance = WebuiTokenManager._();

  /// 密钥最小长度。太短挡不住本机其他应用的暴力尝试。
  static const int minLength = 8;

  bool _initialized = false;

  /// 启动时调用一次：把本地缓存的密钥装进 HTTP 客户端。
  ///
  /// 不做成"每次请求前取一遍"是为了省掉反复的通道往返；
  /// 密钥变更时会立刻在 [set] 里重新配置。
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    final local = await AutostartService.instance.loadWebuiToken();
    if (local.isNotEmpty) {
      IwphoneService.instance.configure(token: local);
    }
  }

  /// 设备上是否已设密钥 —— 决定 WebUI 现在能不能用。
  Future<bool> isSetOnDevice() => AutostartService.instance.webuiTokenSet();

  /// 本地缓存的密钥（可能为空）。
  Future<String> localToken() => AutostartService.instance.loadWebuiToken();

  /// 校验用户输入。返回 null 表示合法，否则返回错误说明。
  static String? validate(String input) {
    final t = input.trim();
    if (t.isEmpty) return AppStrings.t('webuiToken.empty');
    if (t.length < minLength) {
      return '${AppStrings.t('webuiToken.tooShortPrefix')}$minLength'
          '${AppStrings.t('webuiToken.tooShortSuffix')}';
    }
    if (RegExp(r'\s').hasMatch(t)) {
      return AppStrings.t('webuiToken.hasWhitespace');
    }
    return null;
  }

  /// 下发密钥到设备；成功后同步配好 HTTP 客户端。
  Future<({bool ok, String msg})> set(String input) async {
    final t = input.trim();
    final err = validate(t);
    if (err != null) return (ok: false, msg: err);

    final r = await AutostartService.instance.setWebuiToken(t);
    if (!r.ok) return r;

    IwphoneService.instance.configure(token: t);
    IwphoneService.instance.invalidate();
    return (ok: true, msg: AppStrings.t('webuiToken.applied'));
  }
}
