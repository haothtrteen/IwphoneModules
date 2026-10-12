import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/home_screen.dart';
import 'screens/logs_screen.dart';
import 'screens/modules_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/settings_screen.dart';
import 'services/app_prefs.dart';
import 'services/autostart_service.dart';
import 'services/iwphone_service.dart';
import 'services/storage_permission_service.dart';
import 'services/webui_token.dart';
import 'theme/app_theme.dart';
import 'widgets/bottom_nav_bar.dart';

/// 框架是否已在设备上运行（决定要不要走首次引导）。
///
/// 判定用两级：先看框架目录是否已部署（快，一条 adb），
/// 已部署再看守护进程是否真活着（WebUI /api/status；
/// WebUI 没起来时连接会被立刻拒绝，不会拖慢启动）。
/// 任何一步拿不到结果都按「未激活」处理 —— 宁可多走一次引导，
/// 也不要因为探测失败把用户卡在门外面。
Future<bool> _probeFramework() async {
  try {
    final installed = await AutostartService.instance.frameworkInstalled();
    if (!installed) return false;
    final st = await IwphoneService.instance.getStatus();
    return st.daemonRunning;
  } catch (_) {
    return false;
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 先把本地缓存的访问密钥装进 HTTP 客户端 —— 之后所有请求才带得上 X-Token。
  // 只读一次 SharedPreferences，开销可忽略；不这样做的话首屏请求必然 403。
  await WebuiTokenManager.instance.init();
  // 主题 / 语言 / 首次引导状态也要在首帧前就位，否则会先闪一下默认主题再跳变。
  await AppPrefs.instance.load();
  // 探测框架是否已经活着：活着就别再打扰用户走引导
  // （重装 App / 换设备但框架已部署过的场景）。
  _frameworkActive = await _probeFramework();
  // 使用系统自带的状态栏与导航栏，不再自绘 StatusBar（避免与系统 UI 重复）。
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const ShellManagerApp());
}

/// 应用根：把「主题模式 / 语言 / 引导状态」的变化接进整棵树。
///
/// 主题色与文案是全局状态（`AppColors` / `AppStrings`），
/// 它们变了必须让所有页面重新 build —— 所以这里监听 [AppPrefs] 并 setState，
/// 由框架重建整棵树，而不是在每个页面里各自订阅。
/// 框架是否已在运行（[main] 里探测一次，之后不再变）。
bool _frameworkActive = false;

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
      // 门禁：没走过引导 **且** 框架没在跑 → 才进引导页。
      // 框架已在运行（比如重装 App、框架早先部署过）就直接进首页，
      // 免得每次都逼用户重走一遍配对/部署。
      home: (AppPrefs.instance.onboardingDone || _frameworkActive)
          ? const ShellManagerHomePage()
          : const OnboardingScreen(),
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

  @override
  void initState() {
    super.initState();
    // 监听生命周期：从系统设置页返回时需重新查询权限（该权限无法弹窗授予，
    // 用户是去系统设置里手动开的，回到 App 才能拿到真实结果）
    WidgetsBinding.instance.addObserver(this);
    _refreshStorageStatus();
    _refreshAutostart();
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
                  HomeScreen(reloadToken: _homeReloadToken),
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
