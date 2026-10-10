/// 极简多语言支持。
///
/// 为什么不用 `intl` / `flutter_localizations`：本项目约定**零第三方依赖**，
/// 而这里的诉求只是「一份文案表 + 运行时切换」，用不上 ICU 复数、性别等能力。
///
/// 用法：`Text(AppStrings.t('nav.home'))`。
/// 语言由 `AppPrefs` 决定，根组件在语言变化时重建整棵树。
///
/// 覆盖范围：导航、设置、主页、首次引导、关于 —— 即用户最常看到的面。
/// 终端、资源、模块配置这些深度页面的文案仍是中文，后续按同一张表增量补齐即可。
abstract final class AppStrings {
  AppStrings._();

  static String _lang = 'zh';

  /// 当前语言：'zh' 或 'en'。
  static String get lang => _lang;

  static bool get isEnglish => _lang == 'en';

  /// 由根组件调用。传入 system 时按系统语言判定。
  static void applyLanguage(String mode, {String? systemLang}) {
    if (mode == 'en') {
      _lang = 'en';
    } else if (mode == 'zh') {
      _lang = 'zh';
    } else {
      _lang = (systemLang ?? 'zh').toLowerCase().startsWith('zh') ? 'zh' : 'en';
    }
  }

  /// 取文案。找不到 key 时退回中文，再退回 key 本身 —— 便于开发期发现问题。
  static String t(String key) {
    final table = _tables[_lang] ?? _tables['zh']!;
    return table[key] ?? _tables['zh']![key] ?? key;
  }

  static const Map<String, Map<String, String>> _tables = {
    'zh': {
      // ---- 导航 ----
      'nav.home': '主页',
      'nav.modules': '模块',
      'nav.logs': '日志',
      'nav.settings': '设置',

      // ---- 通用 ----
      'common.cancel': '取消',
      'common.confirm': '确定',
      'common.save': '保存',
      'common.done': '完成',
      'common.next': '下一步',
      'common.back': '上一步',
      'common.skip': '跳过',
      'common.retry': '重试',
      'common.refresh': '刷新',
      'common.followSystem': '跟随系统',

      // ---- 首次引导 ----
      'onboarding.welcomeTitle': '欢迎使用 Shell Manager',
      'onboarding.welcomeDesc':
          '不用刷机、不用解锁 Bootloader。\n通过系统自带的「无线调试」取得 shell 权限，'
              '再用一套自带运行时、带沙箱与写前快照的框架来跑免 root 模块。',
      'onboarding.welcomePoint1': '全程在手机内完成，不需要电脑',
      'onboarding.welcomePoint2': '模块可管、可回滚 —— 改坏了能一键还原',
      'onboarding.welcomePoint3': '兼容 Magisk / KernelSU / AxManager 式模块',
      'onboarding.step2Title': '三步就能用起来',
      'onboarding.step2Desc': '在「设置 → 开机自启设置」里按顺序完成：',
      'onboarding.stepPair': '配对设备',
      'onboarding.stepPairDesc': '通知栏输入配对码，端口由 mDNS 自动发现',
      'onboarding.stepDeploy': '部署框架',
      'onboarding.stepDeployDesc': 'App 内置框架包，点一下即可',
      'onboarding.stepToken': '设置访问密钥',
      'onboarding.stepTokenDesc': '自己设一把（至少 8 位），挡住同设备其它应用',
      'onboarding.step3Title': '开始之前，先说清楚风险',
      'onboarding.step3Desc':
          '本项目通过 ADB 权限进行系统级操作，可能影响设备稳定性。\n'
              '安装模块前请先了解它做什么；作者不对设备损坏、数据丢失或保修问题负责。',
      'onboarding.agree': '我已了解，开始使用',

      // ---- 设置页 ----
      'settings.title': '设置',
      'settings.section.shell': 'Shell',
      'settings.section.framework': '框架',
      'settings.section.appearance': '外观',
      'settings.section.about': '关于',
      'settings.autostart': '开机自启',
      'settings.autostartSettings': '开机自启设置',
      'settings.autostartHint': '配对设备、固定端口、查看上次执行结果',
      'settings.mountNs': '挂载命名空间',
      'settings.mountNsValue': '全局',
      'settings.frameworkConfig': '框架配置',
      'settings.frameworkConfigHint': '日志保留、WebUI 端口、模块目录等',
      'settings.terminal': '内置终端',
      'settings.terminalHint': '执行 shell 命令、反查文件归属',
      'settings.resources': '资源占用',
      'settings.resourcesHint': '各模块占用的系统资源与冲突记录',
      'settings.snapshots': '历史快照',
      'settings.snapshotsHint': '各模块改动过的设置原值，可一键还原',
      'settings.webuiToken': '访问密钥',
      'settings.webuiTokenHint': '框架 shell 接口的密钥，可修改',
      'settings.theme': '主题',
      'settings.themeSystem': '跟随系统',
      'settings.themeLight': '浅色',
      'settings.themeDark': '深色',
      'settings.language': '语言',
      'settings.languageSystem': '跟随系统',
      'settings.languageZh': '简体中文',
      'settings.languageEn': 'English',
      'settings.projectHome': '项目地址',
      'settings.author': '作者',
      'settings.version': '版本',
      'settings.uninstallFramework': '卸载框架',
      'settings.uninstallFrameworkHint': '删除全部模块、锁与日志（源文件保留）',
      'settings.permissions': '权限',
      'settings.storage': '存储权限',
      'settings.storageHint': '用于读取本地模块包与导出日志',
      'settings.notification': '通知',
      'settings.notificationHint': '配对码输入与自启结果通知',
      'settings.tokenUpdated': '访问密钥已更新',
      'settings.linkFailed': '打不开链接，请手动访问',
      'settings.languageChanged': '语言已切换',

      // ---- 主页 ----
      'home.title': 'Shell Manager',
      'home.framework': 'iwphone 框架',
      'home.running': '运行中',
      'home.stopped': '已停止',
      'home.notInstalled': '未安装',
      'home.checking': '检查中…',
      'home.detecting': '检测中',
      'home.notRunning': '未运行',
      'home.notConnected': '未连接',
      'home.modulesTotal': '模块总数',
      'home.modulesRunning': '运行中',
      'home.selinux': 'SELinux',
      'home.arch': '架构',
      'home.systemInfo': '系统信息',
      'home.androidVersion': 'Android 版本',
      'home.kernel': '内核',
      'home.device': '设备型号',
      'home.start': '启动框架',
      'home.stop': '停止框架',
      'home.restart': '重启框架',
      'home.sync': '同步状态',
      'home.deploy': '部署框架',
      'home.tokenCardTitle': '先设置访问密钥',
      'home.tokenCardDesc':
          '框架的 shell 接口监听在本机回环口，需要一把密钥才能对外开放。'
              '设好之前，模块列表 / 配置 / 日志都用不了。',
      'home.tokenCardAction': '去设置',
      'home.tokenSet': '访问密钥已生效，框架功能已解锁',

      // ---- 关于 ----
      'about.description': '免 root 的 Android 模块管理器',
      'about.github': 'https://github.com/haothtrteen/IwphoneModules',
      'about.license': 'GPL-3.0',
    },
    'en': {
      // ---- nav ----
      'nav.home': 'Home',
      'nav.modules': 'Modules',
      'nav.logs': 'Logs',
      'nav.settings': 'Settings',

      // ---- common ----
      'common.cancel': 'Cancel',
      'common.confirm': 'OK',
      'common.save': 'Save',
      'common.done': 'Done',
      'common.next': 'Next',
      'common.back': 'Back',
      'common.skip': 'Skip',
      'common.retry': 'Retry',
      'common.refresh': 'Refresh',
      'common.followSystem': 'Follow system',

      // ---- onboarding ----
      'onboarding.welcomeTitle': 'Welcome to Shell Manager',
      'onboarding.welcomeDesc':
          'No flashing, no bootloader unlock. It obtains shell privileges through '
              'the built-in wireless debugging, then runs root-free modules on a '
              'bundled runtime with a sandbox and write-ahead snapshots.',
      'onboarding.welcomePoint1': 'Everything happens on the phone — no PC needed',
      'onboarding.welcomePoint2':
          'Modules are manageable and reversible — one tap to roll back',
      'onboarding.welcomePoint3':
          'Compatible with Magisk / KernelSU / AxManager style modules',
      'onboarding.step2Title': 'Three steps to get going',
      'onboarding.step2Desc': 'Do these in Settings → Autostart settings:',
      'onboarding.stepPair': 'Pair the device',
      'onboarding.stepPairDesc':
          'Enter the pairing code from the notification; the port is found via mDNS',
      'onboarding.stepDeploy': 'Deploy the framework',
      'onboarding.stepDeployDesc': 'The framework ships inside the app — one tap',
      'onboarding.stepToken': 'Set an access key',
      'onboarding.stepTokenDesc':
          'Pick your own (8+ chars) to keep other apps on the device out',
      'onboarding.step3Title': 'Before you start — the risks',
      'onboarding.step3Desc':
          'This project performs system-level operations through ADB privileges and '
              'may affect device stability.\nLearn what a module does before installing it. '
              'The author is not liable for device damage, data loss, or warranty issues.',
      'onboarding.agree': 'I understand — get started',

      // ---- settings ----
      'settings.title': 'Settings',
      'settings.section.shell': 'Shell',
      'settings.section.framework': 'Framework',
      'settings.section.appearance': 'Appearance',
      'settings.section.about': 'About',
      'settings.autostart': 'Autostart',
      'settings.autostartSettings': 'Autostart settings',
      'settings.autostartHint': 'Pair device, fixed port, last run result',
      'settings.mountNs': 'Mount namespace',
      'settings.mountNsValue': 'Global',
      'settings.frameworkConfig': 'Framework config',
      'settings.frameworkConfigHint': 'Log retention, WebUI port, module dir',
      'settings.terminal': 'Built-in terminal',
      'settings.terminalHint': 'Run shell commands, trace file ownership',
      'settings.resources': 'Resource usage',
      'settings.resourcesHint': 'Resources held by modules and conflict log',
      'settings.snapshots': 'Snapshots',
      'settings.snapshotsHint': 'Original values changed by modules, one-tap restore',
      'settings.webuiToken': 'Access key',
      'settings.webuiTokenHint': 'Key for the framework shell API — changeable',
      'settings.theme': 'Theme',
      'settings.themeSystem': 'Follow system',
      'settings.themeLight': 'Light',
      'settings.themeDark': 'Dark',
      'settings.language': 'Language',
      'settings.languageSystem': 'Follow system',
      'settings.languageZh': '简体中文',
      'settings.languageEn': 'English',
      'settings.projectHome': 'Project',
      'settings.author': 'Author',
      'settings.version': 'Version',
      'settings.uninstallFramework': 'Uninstall framework',
      'settings.uninstallFrameworkHint':
          'Delete all modules, locks and logs (source files kept)',
      'settings.permissions': 'Permissions',
      'settings.storage': 'Storage',
      'settings.storageHint': 'To read local module packages and export logs',
      'settings.notification': 'Notifications',
      'settings.notificationHint': 'Pairing code input and autostart results',
      'settings.tokenUpdated': 'Access key updated',
      'settings.linkFailed': 'Cannot open the link — please visit it manually',
      'settings.languageChanged': 'Language switched',

      // ---- home ----
      'home.title': 'Shell Manager',
      'home.framework': 'iwphone framework',
      'home.running': 'Running',
      'home.stopped': 'Stopped',
      'home.notInstalled': 'Not installed',
      'home.checking': 'Checking…',
      'home.detecting': 'Detecting',
      'home.notRunning': 'Not running',
      'home.notConnected': 'Not connected',
      'home.modulesTotal': 'Modules',
      'home.modulesRunning': 'Running',
      'home.selinux': 'SELinux',
      'home.arch': 'Arch',
      'home.systemInfo': 'System info',
      'home.androidVersion': 'Android',
      'home.kernel': 'Kernel',
      'home.device': 'Device',
      'home.start': 'Start',
      'home.stop': 'Stop',
      'home.restart': 'Restart',
      'home.sync': 'Sync',
      'home.deploy': 'Deploy',
      'home.tokenCardTitle': 'Set an access key first',
      'home.tokenCardDesc':
          'The framework shell API listens on the loopback interface and needs a key '
              'to stay closed to other apps. Until then, modules / config / logs are unavailable.',
      'home.tokenCardAction': 'Set now',
      'home.tokenSet': 'Access key active — framework unlocked',

      // ---- about ----
      'about.description': 'Root-free Android module manager',
      'about.github': 'https://github.com/haothtrteen/IwphoneModules',
      'about.license': 'GPL-3.0',
    },
  };
}
