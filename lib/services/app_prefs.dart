import 'package:flutter/widgets.dart';

import '../i18n/app_strings.dart';
import 'autostart_service.dart';

/// 界面偏好：主题模式、语言、是否已完成首次引导。
///
/// 用 [ChangeNotifier] 是为了让根组件能重建成整棵树 ——
/// 主题色与文案都是全局状态（`AppColors` / `AppStrings`），
/// 变了必须让所有页面重新 build 一次才生效。
class AppPrefs extends ChangeNotifier {
  AppPrefs._();

  static final AppPrefs instance = AppPrefs._();

  /// 'system' | 'light' | 'dark'
  String themeMode = 'system';

  /// 'system' | 'zh' | 'en'
  String locale = 'system';

  bool onboardingDone = false;

  /// 是否已从原生读过一次（未读完时不要渲染主界面，避免闪一下默认主题）。
  bool loaded = false;

  Future<void> load() async {
    final r = await AutostartService.instance.loadUiPrefs();
    themeMode = r.themeMode;
    locale = r.locale;
    onboardingDone = r.onboardingDone;
    loaded = true;
    _applyLanguage();
    notifyListeners();
  }

  Future<void> setThemeMode(String value) async {
    if (themeMode == value) return;
    themeMode = value;
    notifyListeners();
    await AutostartService.instance.saveUiPrefs(themeMode: value);
  }

  Future<void> setLocale(String value) async {
    if (locale == value) return;
    locale = value;
    _applyLanguage();
    notifyListeners();
    await AutostartService.instance.saveUiPrefs(locale: value);
  }

  Future<void> setOnboardingDone() async {
    if (onboardingDone) return;
    onboardingDone = true;
    notifyListeners();
    await AutostartService.instance.saveUiPrefs(onboardingDone: true);
  }

  /// 把「跟随系统」解析成具体语言。
  void _applyLanguage() {
    AppStrings.applyLanguage(
      locale,
      systemLang: WidgetsBinding.instance.platformDispatcher.locale.languageCode,
    );
  }

  /// 根组件在构建前调用：把当前语言再同步一次（系统语言可能变了）。
  void syncLanguage() => _applyLanguage();
}
