import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/framework_missing_screen.dart';
import 'screens/home_screen.dart';
import 'screens/logs_screen.dart';
import 'screens/modules_screen.dart';
import 'screens/settings_screen.dart';
import 'services/app_prefs.dart';
import 'services/autostart_service.dart';
import 'services/iwphone_service.dart';
import 'services/storage_permission_service.dart';
import 'services/webui_token.dart';
import 'theme/app_theme.dart';
import 'widgets/bottom_nav_bar.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 先把本地缓存的访问密钥装进 HTTP 客户端 —— 之后所有请求才带得上 X-Token。
  // 只读一次 SharedPreferences，开销可忽略；不这样做的话首屏请求必然 403。
  await WebuiTokenManager.instance.init();
  // 主题 / 语言也要在首帧前就位，否则会先闪一下默认主题再跳变。
  await AppPrefs.instance.load();
  // 使用系统自带的状态栏与导航栏，不再自绘 StatusBar（避免与系统 UI 重复）。
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const ShellManagerApp());
}

/// 应用根：把「主题模式 / 语言」的变化接进整棵树。
///
/// 主题色与文案是全局状态（`AppColors` / `AppStrings`），
/// 它们变了必须让所有页面重新 build —— 所以这里监听 [AppPrefs] 并 setState，
/// 由框架重建整棵树，而不是在每个页面里各自订阅。
class ShellManagerApp extends StatefulWidget {
  const ShellManagerApp({super.key});

  @override
  State<ShellManagerApp> createState() => _ShellManagerAppState();
}

class _ShellManagerAppState extends State<ShellManagerApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppPrefs.instance.addListener(_onPrefsChanged);
  }

  @override
  void dispose() {
    AppPrefs.instance.removeListener(_onPrefsChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onPrefsChanged() {
    if (mounted) setState(() {});
  }

  /// 系统深浅色变化时也要重建（「跟随系统」模式下靠它生效）。
  @override
  void didChangePlatformBrightness() {
    if (mounted) setState(() {});
  }

  /// 当前实际生效的亮度：跟随系统时取系统值。
  Brightness _effectiveBrightness() {
    switch (AppPrefs.instance.themeMode) {
      case 'light':
        return Brightness.light;
      case 'dark':
        return Brightness.dark;
      default:
        return WidgetsBinding.instance.platformDispatcher.platformBrightness;
    }
  }

  /// 状态栏 / 导航栏跟随主题。
  ///
  /// edgeToEdge 下页面会延伸到系统栏下方，图标颜色必须与背景相反才看得清 ——
  /// 浅色主题用深色图标，深色主题用浅色图标。
  void _applySystemUi(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
        statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: AppColors.bg,
        systemNavigationBarIconBrightness:
            isDark ? Brightness.light : Brightness.dark,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 语言可能被系统语言影响（「跟随系统」模式），每次构建同步一次。
    AppPrefs.instance.syncLanguage();

    final brightness = _effectiveBrightness();
    AppColors.applyBrightness(brightness);
    _applySystemUi(brightness);

    return MaterialApp(
      title: 'Shell Manager',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: brightness,
        scaffoldBackgroundColor: AppColors.bg,
        fontFamily: 'Inter', // 未打包字体文件时自动回退系统字体
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.accent,
          brightness: brightness,
        ).copyWith(surface: AppColors.surface),
      ),
      // 没有独立引导页了 —— 框架在不在由 ShellManagerHomePage 内部判定：
      // 没装就只渲染安装页，装了就进四页主界面。
      // 这样"引导状态"和"真实安装状态"不会各说各话。
      home: const ShellManagerHomePage(),
    );
  }
}

/// 应用根页面：四页内容（IndexedStack 保持各页状态）+ 底部导航
class ShellManagerHomePage extends StatefulWidget {
  const ShellManagerHomePage({super.key});

  @override
  State<ShellManagerHomePage> createState() => _ShellManagerHomePageState();
}

class _ShellManagerHomePageState extends State<ShellManagerHomePage>
    with WidgetsBindingObserver {
  int _pageIndex = 0;

  /// 「开机自启」真实状态 —— 由原生侧持久化，这里只是镜像。
  bool _autoStart = false;

  // 存储权限状态（读取 /sdcard/iwphone/ 状态镜像所需）
  StoragePermissionStatus _storageStatus = StoragePermissionStatus.denied;

  // 切回对应页时递增，触发该页重新读取设备/框架数据
  int _homeReloadToken = 0;
  int _modulesReloadToken = 0;
  int _logsReloadToken = 0;

  /// 框架是否「确定没装」。为 true 时整个四页界面都不渲染 ——
  /// 只留 [FrameworkMissingScreen]，避免在没有数据来源的界面上点出各种错。
  bool _frameworkMissing = false;

  /// 首次探测完成前先不渲染任何一页，避免"先闪一下主界面再跳走"。
  bool _checkingFramework = true;

  @override
  void initState() {
    super.initState();
    // 监听生命周期：从系统设置页返回时需重新查询权限（该权限无法弹窗授予，
    // 用户是去系统设置里手动开的，回到 App 才能拿到真实结果）
    WidgetsBinding.instance.addObserver(this);
    _refreshStorageStatus();
    _refreshAutostart();
    _checkFramework();
  }

  /// 探测框架是否已部署，决定要不要走「未安装」门禁。
  ///
  /// 判定与首页一致：adb 查得到就以文件为准；查不到再看 WebUI 有没有应答。
  /// 只有「确定没有」或「查不到且 WebUI 也不通」才进未安装页 ——
  /// 后者意味着框架实际上不可用，继续显示四页界面只会点出各种无意义报错。
  Future<void> _checkFramework() async {
    try {
      final probe = await AutostartService.instance.probeFramework();
      final st = await IwphoneService.instance.getStatus();
      if (!mounted) return;
      setState(() {
        _frameworkMissing = probe.isMissing ||
            (probe.isUnknown && !st.daemonRunning);
        _checkingFramework = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _checkingFramework = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshStorageStatus();
      // 自启开关可能被「立即执行一次」等操作改变，回来对齐一次
      _refreshAutostart();
      // 用户可能刚在别处装好/卸载了框架，回来重新判定一次门禁
      _checkFramework();
    }
  }

  Future<void> _refreshStorageStatus() async {
    final s = await StoragePermissionService.instance.status();
    if (!mounted) return;
    setState(() => _storageStatus = s);
  }

  /// 读回原生侧持久化的自启开关。原生是唯一事实来源 ——
  /// Dart 侧不缓存，避免两边状态漂移。
  Future<void> _refreshAutostart() async {
    final st = await AutostartService.instance.status();
    if (!mounted) return;
    setState(() => _autoStart = st.enabled);
  }

  Future<void> _setAutostart(bool value) async {
    await AutostartService.instance.setEnabled(value);
    await _refreshAutostart();
  }

  Future<void> _requestStorage() async {
    await StoragePermissionService.instance.request();
    // 无论走哪条分支，回来后再查一次即可拿到真实状态
    await _refreshStorageStatus();
  }

  void _onPageChanged(int index) {
    setState(() {
      _pageIndex = index;
      if (index == 0) _homeReloadToken++;
      if (index == 1) _modulesReloadToken++;
      if (index == 2) _logsReloadToken++;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 首次探测未完成：先空着，避免先渲染主界面再跳走造成的闪动
    if (_checkingFramework) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    // ★ 门禁：框架没装就只显示这一页（KernelSU / Magisk 的做法）。
    //   框架不在时模块列表、日志、启停按钮都没有数据来源，继续渲染四页界面
    //   只会点出一堆无意义的报错。部署成功后再放行到主界面。
    if (_frameworkMissing) {
      return FrameworkMissingScreen(
        onRefresh: () {
          _checkFramework();
        },
        onInstalled: () {
          setState(() => _frameworkMissing = false);
          _homeReloadToken++;
          _modulesReloadToken++;
          _logsReloadToken++;
          _refreshAutostart();
        },
      );
    }

    return Scaffold(
      backgroundColor: AppColors.bg,
      // SafeArea 避让系统状态栏与底部导航栏 —— edgeToEdge 下页面会延伸到系统栏下方，
      // 顶部交给系统状态栏，底部是系统导航栏 + 自绘 BottomNavBar。
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: IndexedStack(
                index: _pageIndex,
                children: [
                  HomeScreen(
                    reloadToken: _homeReloadToken,
                    onFrameworkRemoved: () {
                      if (!mounted) return;
                      setState(() {
                        _frameworkMissing = true;
                        _checkingFramework = false;
                      });
                    },
                  ),
                  ModulesScreen(reloadToken: _modulesReloadToken),
                  LogsScreen(reloadToken: _logsReloadToken),
                  SettingsScreen(
                    autoStart: _autoStart,
                    storageStatus: _storageStatus,
                    onAutoStartChanged: _setAutostart,
                    onRequestStorage: _requestStorage,
                  ),
                ],
              ),
            ),
            BottomNavBar(
              currentIndex: _pageIndex,
              onChanged: _onPageChanged,
            ),
          ],
        ),
      ),
    );
  }
}
