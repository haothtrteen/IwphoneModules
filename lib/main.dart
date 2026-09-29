import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/home_screen.dart';
import 'screens/logs_screen.dart';
import 'screens/modules_screen.dart';
import 'screens/settings_screen.dart';
import 'services/autostart_service.dart';
import 'services/storage_permission_service.dart';
import 'services/webui_token.dart';
import 'theme/app_theme.dart';
import 'widgets/bottom_nav_bar.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 先把本地缓存的访问密钥装进 HTTP 客户端 —— 之后所有请求才带得上 X-Token。
  // 只读一次 SharedPreferences，开销可忽略；不这样做的话首屏请求必然 403。
  await WebuiTokenManager.instance.init();
  // 使用系统自带的状态栏与导航栏，不再自绘 StatusBar（避免与系统 UI 重复）。
  // edgeToEdge：内容延伸到系统栏之下，由 SafeArea 负责避让 ——
  // 既保留沉浸观感，又不会出现"两个顶栏"。
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      // 状态栏透明，让页面背景自然延伸上去
      statusBarColor: Colors.transparent,
      // 深色背景 → 亮色图标。
      // Android 依据 statusBarIconBrightness，iOS 依据 statusBarBrightness，两者都设。
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      // 底部系统导航栏跟随主题配色
      systemNavigationBarColor: AppColors.bg,
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarDividerColor: Colors.transparent,
    ),
  );
  runApp(const ShellManagerApp());
}

class ShellManagerApp extends StatelessWidget {
  const ShellManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Shell Manager',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.bg,
        fontFamily: 'Inter', // 未打包字体文件时自动回退系统字体
      ),
      home: const ShellManagerHomePage(),
    );
  }
}

/// 应用根页面：自绘状态栏 + 四页内容（IndexedStack 保持各页状态）+ 底部导航
class ShellManagerHomePage extends StatefulWidget {
  const ShellManagerHomePage({super.key});

  @override
  State<ShellManagerHomePage> createState() => _ShellManagerHomePageState();
}

class _ShellManagerHomePageState extends State<ShellManagerHomePage>
    with WidgetsBindingObserver {
  int _pageIndex = 0;

  // 设置项开关（对应设计稿）
  bool _darkTheme = true;
  /// 「开机自启」真实状态 —— 由原生侧持久化，这里只是镜像。
  bool _autoStart = false;
  bool _hideApp = false;
  bool _biometricLock = true;

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
                    darkTheme: _darkTheme,
                    autoStart: _autoStart,
                    hideApp: _hideApp,
                    biometricLock: _biometricLock,
                    storageStatus: _storageStatus,
                    onDarkThemeChanged: (v) => setState(() => _darkTheme = v),
                    onAutoStartChanged: _setAutostart,
                    onHideAppChanged: (v) => setState(() => _hideApp = v),
                    onBiometricLockChanged: (v) => setState(() => _biometricLock = v),
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
