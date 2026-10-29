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
      'onboarding.activateTitle': '完成首次激活',
      'onboarding.activateDesc': '做完下面几步就能用了。没做完也能进 —— 剩下的在「设置」里随时继续。',
      'onboarding.permNotify': '通知权限',
      'onboarding.permNotifyDesc': '配对码在通知栏输入，没有这个权限走不下去',
      'onboarding.permStorage': '存储权限',
      'onboarding.permStorageDesc': '读取本地模块包、导出日志',
      'onboarding.optional': '可选',
      'onboarding.pair': '配对设备',
      'onboarding.pairDesc': '打开无线调试的配对界面，把配对码填进通知栏',
      'onboarding.deploy': '部署框架',
      'onboarding.deployDesc': 'App 内置框架包，一键部署到设备',
      'onboarding.token': '设置访问密钥',
      'onboarding.tokenOptionalDesc': '至少 8 位，用来挡住同设备其它应用（不设也能用，但回环口会开放）',
      'onboarding.autostartDesc': '开机自动连上设备并拉起框架（可稍后在设置里开）',
      'onboarding.pairFirst': '请先完成设备配对，再开启开机自启',
      'onboarding.tokenDesc': '至少 8 位，用来挡住同设备其它应用',
      'onboarding.action': '去完成',
      'onboarding.doneTag': '已完成',
      'onboarding.refresh': '刷新状态',
      'onboarding.notifyNeeded': '需要通知权限才能在通知栏输入配对码',
      'onboarding.pairSent': '通知已发出：打开「无线调试 → 使用配对码配对设备」，把配对码填进通知即可',
      'onboarding.pairSentManual': '通知已发出。请手动到 开发者选项 → 无线调试 打开配对界面',
      'onboarding.deployOk': '框架已部署',
      'onboarding.deployFail': '部署失败',
      'onboarding.enter': '进入应用',
      'onboarding.agree': '我已了解，开始使用',

      // ---- 设置页 ----
      'settings.title': '设置',
      'settings.section.shell': 'Shell',
      'settings.section.framework': '框架',
      'settings.section.shellFramework': 'Shell 与框架',
      'settings.tools': '框架工具',
      'settings.toolsHint': '内置终端 / 资源占用 / 历史快照',
      'settings.section.danger': '危险操作',
      'tools.title': '框架工具',
      'tools.section.diagnostics': '诊断',
      'tools.section.data': '数据',
      'settings.section.permissions': '权限',
      'settings.section.security': '安全',
      'settings.storageAllFiles': '所有文件访问',
      'settings.hideApp': '隐藏应用',
      'settings.biometric': '生物识别锁',
      'settings.uninstallTitle': '卸载 iwphone 框架',
      'settings.section.appearance': '外观',
      'settings.section.about': '关于',
      'settings.autostart': '开机自启',
      'settings.autostartSettings': '开机自启设置',
      'settings.autostartHint': '配对设备、固定端口、查看上次执行结果',
      'settings.mountNs': '挂载命名空间',
      'settings.mountNsValue': '全局',
      'settings.frameworkConfig': '框架配置',
      'settings.frameworkConfigHint': '轮询间隔 / 超时 / 沙箱 / 访问令牌',
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
          '框架的 shell 接口监听在本机回环口。设一把密钥可以挡住同设备其它应用；'
              '不设也能正常用，只是接口处于开放状态。',
      'home.tokenCardSkip': '暂不设置',
      'home.tokenCardAction': '去设置',
      'home.tokenSet': '访问密钥已生效，框架功能已解锁',

      // ---- 模块页 ----
      'modules.running': '运行中',
      'modules.installed': '已安装',
      'modules.resourceModule': '资源模块',
      'modules.conflictSeparator': '、',
      'modules.conflictPrefix': '资源冲突：与 ',
      'modules.conflictSuffix': ' 重复',
      'modules.startFailed': '启动失败：WebUI 未运行或网络受限',
      'modules.stopFailed': '停止失败：WebUI 未运行或网络受限',
      'modules.reinstallTitle': '重装模块',
      'modules.installTitle': '安装模块',
      'modules.reinstallConfirmPrefix': '将用模块包覆盖已安装的「',
      'modules.reinstallConfirmSuffix': '」。\n\n模块目录会被重新解压覆盖，若你手动改过其中文件，改动将丢失。\n\n确定要重装吗？',
      'modules.installConfirmPrefix': '将把「',
      'modules.installConfirmSuffix': '」安装到框架。\n\n安装后可在本页启动它。\n\n确定要安装吗？',
      'modules.reinstall': '重装',
      'modules.install': '安装',
      'modules.reinstalledToastPrefix': '已重装：',
      'modules.installedToastPrefix': '已安装：',
      'modules.installFailed': '操作失败：WebUI 不可达，或模块包不完整',
      'modules.actionOutputSuffix': ' · 动作输出',
      'modules.noOutput': '(无输出)',
      'modules.restoreFailedPrefix': '还原失败：',
      'modules.uninstallTitle': '卸载模块',
      'modules.uninstallIntroPrefix': '将卸载「',
      'modules.uninstallIntroSuffix': '」。\n\n该操作会：\n· 停止此模块（若正在运行）\n· 删除模块目录 ',
      'modules.uninstallRestoreSuffix': '\n· 清理它的锁、触发文件与日志\n\n这个模块改过系统设置（有写前快照）。建议同时还原，否则改动会留在系统里；快照会保留，之后也能在「设置 → 历史快照」里补还原。',
      'modules.uninstallConfirmSuffix': '\n· 清理它的锁、触发文件与日志\n\n卸载后需重新安装才能恢复。确定要卸载吗？',
      'modules.restoreSettingsToo': '同时还原系统设置',
      'modules.restoreSettingsTooHint': '先停模块再还原，然后卸载',
      'modules.uninstall': '卸载',
      'modules.uninstalledToastPrefix': '已卸载：',
      'modules.uninstallFailed': '卸载失败：WebUI 不可达，或模块已不存在',
      'modules.restoredSettings': '已还原系统设置。',
      'modules.snapshotRestoreFailedPrefix': '还原未成功（',
      'modules.snapshotRestoreFailedSuffix': '）—— 快照已保留，可在「设置 → 历史快照」重试。',
      'modules.actionFailedPrefix': '操作失败：',
      'modules.noStartableModules': '没有已停止、可启动的模块',
      'modules.startAllTitle': '启动全部模块',
      'modules.startAllConfirmPrefix': '将启动 ',
      'modules.startAllConfirmMiddle': ' 个已停止的模块：\n\n',
      'modules.startAllConfirmSuffix': '确定要启动吗？',
      'modules.startAll': '全部启动',
      'modules.startedCountPrefix': '已启动 ',
      'modules.startedCountSuffix': ' 个模块',
      'modules.title': '模块',
      'modules.filterAll': '全部',
      'modules.filterStopped': '已停止',
      'modules.stopAllTitle': '停止全部模块',
      'modules.stopAllConfirm':
          '将按框架锁逐个正常停止所有运行中的模块。\n\n'
              '⚠️ 若某模块已脱离锁管理（例如把主循环丢到后台自我 daemon 化），'
              '它的锁记录与真实进程对不上，这种方式停不掉 —— '
              '那种情况请改用「强制停止」。\n\n确定要停止吗？',
      'modules.stopAll': '全部停止',
      'modules.forceStopAllTitle': '强制停止全部模块',
      'modules.forceStopConfirm':
          '⚠️ 绕过框架锁，直接终止所有模块的进程树。\n\n'
              '与普通停止的区别：\n'
              '· 不依赖锁记录，按进程的实际工作目录识别\n'
              '· 连同子进程、孙进程一并终止\n'
              '· 模块来不及执行清理动作（例如退出 doze 状态）\n\n'
              '适用于模块卡死、锁丢失、进程脱离管理的场景。确定要强制停止吗？',
      'modules.forceStop': '强制停止',
      'modules.restartAllTitle': '重启全部模块',
      'modules.restartAllConfirm':
          '将先强制停止所有模块进程，再重新拉起「原先在运行」的那些。\n\n'
              '未运行的模块不会被顺带启动。\n\n确定要重启吗？',
      'modules.restartAll': '全部重启',
      'modules.loadingModules': '正在拉取模块列表…',
      'modules.notConnectedPrefix':
          '未连接到 iwphone WebUI（http://127.0.0.1:8537）。\n请先在终端执行：',
      'modules.noMatchingModules': '没有符合条件的模块',
      'modules.config': '配置',
      'modules.action': '动作',
      'modules.restore': '还原',
      'modules.conflictTitle': '资源冲突',
      'modules.conflictDesc':
          '该模块与下列模块声明了同一系统资源。同时运行时，后启动的一方会被框架拒绝，避免配置互相覆盖。',
      'modules.conflictModules': '冲突模块',
      'modules.conflictResources': '涉及资源',
      'modules.conflictAdvice': '如需运行本模块，请先停止上述模块。',
      'modules.compatOk': '预计兼容',
      'modules.compatBlocked': '需要 Root 环境，无法工作',
      'modules.compatUnknown': '无法自动判断，请自行确认',
      'modules.compatDetailTitle': '兼容性预检',
      'modules.noReasons': '（无说明）',
      'modules.compatDesc':
          '预检基于静态扫描，注释里的关键词也会命中（偏保守）。实际行为以模块运行结果为准。',
      'modules.reinstallHint': '用模块包覆盖当前版本，手动改动将丢失',
      'modules.uninstallHint': '删除模块目录与日志，不可恢复',

      // ---- 模块安装页 ----
      'install.importFailedPrefix': '导入失败：',
      'install.importedPrefix': '已导入 ',
      'install.importedSuffix': '，列表里点击即可安装',
      'install.confirmInstallPrefix': '将安装「',
      'install.confirmReinstallPrefix': '将覆盖重装「',
      'install.confirmNameSuffix': '」。\n\n',
      'install.confirmReinstallNote': '模块目录会被包内文件覆盖，手动改动会丢失。',
      'install.confirmBody':
          '安装时会自动识别模块格式（iwphone / Magisk·KernelSU·AxManager 兼容）。\n耗时可达数十秒，请耐心等待。',
      'install.reinstallTitle': '重装模块',
      'install.installTitle': '安装模块',
      'install.reinstall': '重装',
      'install.install': '安装',
      'install.installedPrefix': '「',
      'install.installedSuffix': '」安装完成',
      'install.installFailedSuffix': '」安装失败（详情见框架日志）',
      'install.sectionFramework': '框架包（module/ 目录）',
      'install.emptyPackages':
          '框架 module/ 目录里没有可安装的包。\n可以先用上方「本地导入」把 .iwp 或 Magisk 式模块 zip 推进来。',
      'install.footnote':
          '· 支持两种格式：iwphone 原生包（main.sh + iwphone.prop）与\n'
              '  Magisk / KernelSU / AxManager 式模块（module.prop + service.sh），\n'
              '  安装时自动识别并适配。\n'
              '· 安装 = 解压覆盖到 work/<模块名>/，装完即可在模块页启动。\n'
              '· 预装系统文件替换类的 Magisk 模块在免 root 环境无法工作。',
      'install.importTitle': '从手机存储导入',
      'install.importHint': '选择 .iwp 或 Magisk 式模块 zip，自动推到设备并进入列表',
      'install.importing': '导入中…',
      'install.chooseFile': '选择文件',
      'install.installing': '安装中…',
      'install.installedHint': '已安装 · 点击覆盖重装',
      'install.notInstalledHint': '未安装 · 点击安装',

      'common.delete': '删除',

      // ---- 日志页 ----
      'logs.title': '日志',
      'logs.sourceModule': '模块日志',
      'logs.sourceFramework': '框架日志',
      'logs.kindOverview': '执行概览',
      'logs.loadingModules': '正在加载模块列表…',
      'logs.webuiUnavailable': '未连接到 WebUI：无法读取模块元数据',
      'logs.noModules': '框架中暂无已安装模块',
      'logs.emptyLog': '（暂无日志）',
      'logs.selectModulePrompt': '请选择模块查看日志',
      'logs.selectModuleToClear': '请先选择要清空的模块',
      'logs.selectModuleToExport': '请先选择要导出的模块',
      'logs.scopeFramework': '框架守护日志',
      'logs.scopeModulePrefix': '模块「',
      'logs.scopeModuleSuffix': '」的日志',
      'logs.clearTitle': '清空日志',
      'logs.clearWhatFramework': '· 框架守护日志（modrunner_*.log）',
      'logs.clearMessagePrefix': '将清空 ',
      'logs.clearMessageSuffix': '：\n\n',
      'logs.clearWarning':
          '文件本身会保留（内容置空），正在运行的模块继续正常写日志。\n历史记录一旦清空无法找回。\n\n确定要清空吗？',
      'logs.clearConfirm': '清空',
      'logs.clearFailedPrefix': '清空失败：',
      'logs.exportSuccessTitle': '导出成功',
      'logs.exportHint':
          '可在「文件管理器 → 内部存储 → Download → iwphone_logs」中找到，方便发给别人或转存到电脑。',
      'logs.exportFailedPrefix': '导出失败：',
      'logs.gotIt': '知道了',

      // ---- 终端页 ----
      'terminal.title': '终端',
      'terminal.warning': '命令直接在设备上执行（框架黑名单与超时保护）',
      'terminal.chipFileOwner': '查询文件归属',
      'terminal.chipListModules': '列出模块',
      'terminal.chipLogTail': '框架日志尾部',
      'terminal.chipDeliverScript': '投递脚本',
      'terminal.chipFrameworkConfig': '查看框架配置',
      'terminal.emptyHint': '输入命令开始，或点上方快捷按钮',
      'terminal.inputHint': '输入命令…',
      'terminal.ownerDialogTitle': '查询文件所属应用',
      'terminal.ownerDialogDesc': '输入文件或目录路径，框架会反查它的所有者属于哪个应用。',
      'terminal.ownerDialogQuery': '查询',
      'terminal.running': '执行中…',
      'terminal.failed': '执行失败',
      'terminal.noOutput': '（无输出）',

      // ---- 资源占用页 ----
      'resources.title': '资源占用',
      'resources.conflictLog': '冲突记录',
      'resources.entriesUnit': '条',
      'resources.itemsUnit': '项',
      'resources.all': '全部',
      'resources.modulesUnit': '个模块',
      'resources.empty': '暂无资源占用记录。\n模块通过沙箱写入系统设置后，会在这里留下归属。',

      // ---- 历史快照页 ----
      'snapshot.orphanNote': '该模块已卸载，这里只还原它留下的系统设置改动。',
      'snapshot.restoreFailedPrefix': '还原失败：',
      'snapshot.deleteTitle': '删除快照',
      'snapshot.deleteMessagePrefix': '删除「',
      'snapshot.deleteMessageMiddle': '」的快照后，它改过的 ',
      'snapshot.deleteMessageSuffix':
          ' 项系统设置**将无法再一键还原**。\n\n如果你已经不需要回退（或打算一直保留当前状态），才建议删除。',
      'snapshot.uninstalledBadge': '模块已卸载',
      'snapshot.restorableUnit': '项可还原',
      'snapshot.manualUnit': '项需手动处理',
      'snapshot.restore': '还原',
      'snapshot.empty':
          '还没有任何快照。\n\n快照会在模块**首次修改系统设置**时自动生成 —— 启动一个会改设置的模块（比如动画调速）之后回来就能看到。',
      'snapshot.notes':
          '· 快照在模块**首次写入**某系统资源时自动生成，记录写入前的原值。\n'
              '· 模块卸载后快照会保留 —— 它改过的设置仍然可以还原。\n'
              '· 还原会先停止该模块（避免守卫循环把值改回去），成功后快照归档，模块重新启动会生成新快照。',

      // ---- 资源概览组件 ----
      'resourceSummary.noConflict': '无资源冲突',
      'resourceSummary.detectedPrefix': '检测到 ',
      'resourceSummary.conflictCountSuffix': ' 项资源冲突',
      'resourceSummary.conflictResources': '冲突资源',
      'resourceSummary.usedResources': '占用资源',
      'resourceSummary.conflictLog': '冲突记录',
      'resourceSummary.conflictHint':
          '同一资源被多个模块写入时，先启动的模块会赢，后写入的值可能被覆盖。如需长期稳定运行，建议只保留一个模块操作该资源。',
      'resourceSummary.checking': '正在检查资源占用…',
      'resourceSummary.healthy': '资源占用正常',
      'resourceSummary.empty': '暂无资源占用',
      'resourceSummary.detailLoading': '读取模块的资源声明与运行记录',
      'resourceSummary.occupiedPrefix': '共占用 ',
      'resourceSummary.tapDetailsSuffix': ' 项资源，点击查看冲突详情',
      'resourceSummary.noDuplicateSuffix': ' 项资源，无重复声明',
      'resourceSummary.emptyDetail': '模块写入系统配置后，这里会显示归属',
      'resourceSummary.conflictBadge': '冲突',

      // ---- 快照还原弹层 ----
      'snapshotSheet.title': '还原系统设置',
      'snapshotSheet.restorePrefix': '将把 ',
      'snapshotSheet.restoreMid': ' 项恢复到该模块**首次写入之前**的原值',
      'snapshotSheet.alsoPrefix': '（另有 ',
      'snapshotSheet.alsoSuffix': ' 项需手动处理）',
      'snapshotSheet.restoreEnd': '。\n执行前会先停止该模块，否则守卫循环会把设置又改回去。',
      'snapshotSheet.noRestorable': '无可还原项',
      'snapshotSheet.restoreButtonPrefix': '还原 ',
      'snapshotSheet.restoreButtonSuffix': ' 项',
      'snapshotSheet.unknownResource': '(未识别资源)',
      'snapshotSheet.emptyValue': '(空)',
      'snapshotSheet.currentPrefix': '当前 ',
      'snapshotSheet.arrowRestore': '  →  还原为 ',
      'snapshotSheet.manualNeeded': '沙箱未记录该写法，需手动处理',

      // ---- 框架配置页 ----
      'config.loading': '正在读取框架配置…',
      'config.unavailable': '未连接到 iwphone WebUI（127.0.0.1:8537）。\n请先确认框架与 WebUI 正在运行。',
      'config.empty': '框架未返回任何可配置项',
      'config.footer': '配置写入框架的 env.sh（修改前会自动备份）',
      'config.pendingBadge': '待生效',
      'config.newValueHint': '输入新值',
      'config.rangeLabel': '取值范围 ',
      'config.updateFailPrefix': '修改失败：',
      'config.restartNeededPre': '有 ',
      'config.restartNeededPost': ' 项改动需要重启框架才会生效',
      'config.restartMessage':
          '配置改动需要重启守护进程才会生效。\n\n重启会打断当前轮询周期，已在运行的模块不受影响。\n\n确定要重启吗？',
      'config.restartConfirm': '重启',
      'config.restartOk': '框架已重启，配置已生效',
      'config.restartFail': '重启失败：WebUI 不可达',

      // ---- 模块配置页 ----
      'modConfig.loadFailed': '读取配置失败：WebUI 不可达',
      'modConfig.saved': '配置已保存',
      'modConfig.saveFailPrefix': '保存失败：',
      'modConfig.resetTitle': '恢复默认值',
      'modConfig.resetMessage':
          '把本模块的所有配置项还原为模块声明的默认值。\n\n这只是改回界面上的取值，需要点「保存」才会真正写入。',
      'modConfig.emptyState':
          '这个模块没有可配置的选项。\n（模块需要提供 config.prop 才会出现配置项）',
      'modConfig.dirty': '有改动尚未保存',
      'modConfig.upToDate': '已是最新',
      'modConfig.saving': '保存中…',
      'modConfig.saveAction': '保存配置',

      // ---- 开机自启页 ----
      'autostart.notConnectedTitle': '还没连接上框架',
      'autostart.pairGuideBody':
          '现在开始配对吗？\n\n'
              '流程：点「开始配对」→ 通知栏会出现输入框 → '
              '到 开发者选项 → 无线调试 打开「使用配对码配对设备」→ '
              '把配对码填进通知 → 完成。\n\n'
              '配对端口会自动发现，全程不用碰电脑。',
      'autostart.notNow': '稍后再说',
      'autostart.startPairing': '开始配对',
      'autostart.failedPrefix': '失败：',
      'autostart.successPrefix': '成功：',
      'autostart.repairFramework': '修复框架',
      'autostart.deployMsgHead': '把 App 内置的框架包推送到设备并解压到',
      'autostart.deployMsgTail':
          '已有文件会被覆盖（脚本被改坏、被误删都能一键还原），\n耗时约 1～2 分钟，期间请保持屏幕亮着。',
      'autostart.notifyDenied': '未获得通知权限，自启结果将无法通知你',
      'autostart.pairPermissionDenied': '通知权限未授予，无法发起配对',
      'autostart.pairStartFailed': '发起配对失败：',
      'autostart.manualPairBody':
          '手机上操作：设置 → 开发者选项 → 无线调试 → '
              '「使用配对码配对设备」。\n\n'
              '把弹窗里的两个数字填到下面（**保持那个配对弹窗打开**，'
              '一旦关掉端口就变了）。',
      'autostart.pairPortLabel': '配对端口',
      'autostart.pairPortHint': '如 37193',
      'autostart.pairCodeLabel': '配对码',
      'autostart.pairCodeHint': '如 123456',
      'autostart.pair': '配对',
      'autostart.bothRequired': '配对端口与配对码都要填',
      'autostart.pairedPortFixed': '配对成功，并已固定端口 ',
      'autostart.pairedPortFixFailed': '配对成功，但固定端口失败：',
      'autostart.alreadyRunning': '框架已经在运行，无需重复启动',
      'autostart.sectionSteps': '配置步骤',
      'autostart.sectionVerify': '验证',
      'autostart.sectionNotice': '重要提示',
      'autostart.stepNotifyDesc': '自启是后台静默完成的，没有通知你就无法确认它到底有没有生效。',
      'autostart.granted': '已授权',
      'autostart.grantAction': '去授权',
      'autostart.stepPairTitle': '设备配对',
      'autostart.stepPairDesc':
          '点「去配对」后在通知栏输入配对码即可 —— 配对端口会自动发现，不用手抄。只需做一次，密钥跨重启保持，之后每次开机都是静默重认证。',
      'autostart.paired': '已配对',
      'autostart.pairAction': '去配对',
      'autostart.manualEntry': '手动填入',
      'autostart.stepPortTitle': '固定 ADB 端口',
      'autostart.stepPortDescHead': '把端口固定为',
      'autostart.stepPortDescTail':
          '，这项设置跨重启保持，开机后系统会自动监听它 —— 这是全自动的前提。',
      'autostart.portFixedLabel': '已固定',
      'autostart.runAction': '执行',
      'autostart.runOnce': '立即执行一次',
      'autostart.running': '执行中…',
      'autostart.verifyHint':
          '不必等到下次开机 —— 这里会完整走一遍「重认证 → 取 shell → 拉起框架」并给出真实结果。',
      'autostart.autostartSettingsMissing': '未找到自启动管理页，请手动到系统设置里放行',
      'autostart.deploying': '部署中…',
      'autostart.deployed': '已部署',
      'autostart.notDeployed': '未部署',
      'autostart.detecting': '检测中…',
      'autostart.frameworkPackage': '框架包',
      'autostart.repair': '修复',
      'autostart.deployBtn': '部署',
      'autostart.frameworkDescHead': 'App 内置了整套框架（含 Python 运行时，约 12MB）。\n部署位置：',
      'autostart.frameworkDescTail':
          '重复点「修复」即可把框架还原成出厂状态 —— 脚本改坏了、删了都不怕。\n'
              '启动框架时若发现未部署，也会自动补上。',
      'autostart.neverRun': '尚未执行',
      'autostart.success': '成功',
      'autostart.failure': '失败',
      'autostart.statusEnabled': '开机自启已开启',
      'autostart.statusDisabled': '开机自启已关闭',
      'autostart.keyLabel': '密钥',
      'autostart.keyGenerated': '已生成（未授权则需配对）',
      'autostart.keyNotGenerated': '未生成',
      'autostart.portLabel': '固定端口',
      'autostart.lastRun': '上次自启',
      'autostart.noticeBody':
          '· 小米 / Redmi 机型默认拦截开机广播，需要在系统的「自启动管理」里放行本应用，'
              '否则自启不会生效，而且**不会有任何报错**。\n\n'
              '· 自启依赖固定端口，因此该端口会常驻监听。它需要 ADB 密钥才能连接，'
              '但同网络下的设备仍可尝试 —— 请勿在不可信网络下长期开启。\n\n'
              '· 请勿在框架运行期间切换 USB / 无线调试或执行 adb 模式切换命令：'
              '那会重启 ADB 服务，连带终止框架进程。',
      'autostart.openAutostartSettings': '打开系统自启动管理',

      // ---- 主页补充 ----
      'home.actionFailedSuffix': '失败：WebUI 不可达或框架未响应',
      'home.stopAction': '停止',
      'home.stopMessage':
          '将停止 iwphone 守护进程。\n\n'
              '停止后框架不再轮询触发目录；已在运行的模块不会被停止，'
              '但无法再通过 App 或触发文件启动新模块。\n\n确定要停止吗？',
      'home.stopDone': '框架已停止',
      'home.restartAction': '重启',
      'home.restartMessage':
          '将先停止、再启动 iwphone 守护进程。\n\n'
              '重启会打断当前轮询周期，期间无法响应模块启动请求；'
              '已在运行的模块不受影响。\n\n确定要重启吗？',
      'home.restartDone': '框架已重启',
      'home.syncAction': '同步',
      'home.syncMessage':
          '将把执行区状态镜像同步到 /sdcard/iwphone/state/。\n\n'
              '同步需遍历模块目录，模块较多时可能短暂变慢。\n\n确定要同步吗？',
      'home.syncDone': '同步完成',
      'home.probing': '正在探测 iwphone 框架…',
      'home.daemonRunning': 'iwphone modrunner v3 守护进程已启动',
      'home.daemonMissing': '请先在终端执行：\nadb shell sh /data/local/tmp/iwphone/Main.sh &',
      'home.webuiAddress': 'WebUI 地址',
      'home.runAs': '运行身份',

      // ---- 设置页补充 ----
      'settings.autostartNeedsPair': '还未完成设备配对，开机自启无法生效，开关保持关闭',
      'settings.permissionGranted': '已授权',
      'settings.permissionNotRequired': '无需授权',
      'settings.permissionGrant': '去授权',
      'settings.uninstallMessage':
          '⚠️ 最高危操作，不可撤销。\n\n'
              '将删除：\n'
              '· 运行时目录（全部已装模块、锁、触发文件）\n'
              '· 日志目录与状态镜像\n\n'
              '框架源文件目录会保留，可用一键启动脚本重新安装。\n'
              '卸载后 App 将无法连接框架。\n\n确定要继续吗？',
      'settings.uninstallQueued': '卸载已启动',
      'settings.uninstallFailedTitle': '卸载失败',

      // ---- 访问密钥对话框 ----
      'webuiToken.titleSet': '设置访问密钥',
      'webuiToken.titleChange': '修改访问密钥',
      'webuiToken.desc':
          '框架的 WebUI 上挂着 shell 权限接口，而它监听在本机回环口 —— '
              '同设备上任何应用都能访问，所以必须用一把密钥挡住它们。\n\n'
              '密钥由你自己想（至少 8 位）。设好之后：\n'
              '· App 会自动带着它访问框架\n'
              '· 想在浏览器里看 WebUI，用它拼地址即可\n\n'
              '密钥只存在你自己的手机里（框架侧文件权限 600）。',
      'webuiToken.label': '访问密钥',
      'webuiToken.setting': '设置中…',
      'webuiToken.empty': '请输入访问密钥',
      'webuiToken.tooShortPrefix': '至少 ',
      'webuiToken.tooShortSuffix': ' 位',
      'webuiToken.hasWhitespace': '不能包含空格或换行',
      'webuiToken.applied': '访问密钥已生效',

      // ---- 系统信息 ----
      'systemInfo.unknown': '未知',
      'systemInfo.enforcing': '强制',
      'systemInfo.permissive': '宽容',
      'systemInfo.disabled': '已关闭',

      // ---- 模块配置取值 ----
      'moduleConfig.on': '已开启',
      'moduleConfig.off': '已关闭',
      'moduleConfig.emptyValue': '（空）',

      // ---- 冲突类型标签 ----
      'conflictType.block': '启动拦截',
      'conflictType.writer': '多模块写入',
      'conflictType.drift': '值被改动',

      // ---- 服务层兜底提示 ----
      'service.callFailed': '调用失败',
      'iwphone.webuiUnreachable': 'WebUI 不可达',
      'iwphone.clearUnavailable': 'WebUI 不可达，无法清空日志',
      'iwphone.exportUnavailable': 'WebUI 不可达，无法导出日志',
      'iwphone.badResponse': '响应解析失败',
      'iwphone.saved': '已保存',
      'iwphone.saveFailed': '保存失败',
      'iwphone.executed': '已执行',
      'iwphone.execFailed': '执行失败',
      'iwphone.readFailed': '读取失败',
      'iwphone.readSnapshotFailed': '读取快照失败',
      'iwphone.readSnapshotListFailed': '读取快照列表失败',
      'iwphone.deleted': '已删除',
      'iwphone.deleteFailed': '删除失败',
      'iwphone.restored': '已还原',
      'iwphone.restoreFailed': '还原失败',
      'iwphone.shellUnavailable': 'WebUI 不可达（服务未启动，或框架已被卸载）',
      'snapshotItem.deleteItem': '（删除该项）',
      'snapshotItem.manual': '需手动处理',
      'snapshotItem.command': '按指令还原',
      'common.gotIt': '知道了',

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
      'onboarding.activateTitle': 'Finish setup',
      'onboarding.activateDesc': 'A few steps and you are ready. You can also skip them — finish later in Settings.',
      'onboarding.permNotify': 'Notification permission',
      'onboarding.permNotifyDesc': 'The pairing code is typed in a notification — required',
      'onboarding.permStorage': 'Storage permission',
      'onboarding.permStorageDesc': 'Read local module packages and export logs',
      'onboarding.optional': 'optional',
      'onboarding.pair': 'Pair device',
      'onboarding.pairDesc': 'Open wireless debugging pairing, then type the code in the notification',
      'onboarding.deploy': 'Deploy framework',
      'onboarding.deployDesc': 'The framework ships in the app — one tap',
      'onboarding.token': 'Set access key',
      'onboarding.tokenOptionalDesc': 'At least 8 chars to keep other apps out (optional — without it the loopback API stays open)',
      'onboarding.autostartDesc': 'Auto-connect and start the framework on boot (can be enabled later in Settings)',
      'onboarding.pairFirst': 'Please pair the device first, then enable autostart',
      'onboarding.tokenDesc': 'At least 8 chars, keeps other apps out',
      'onboarding.action': 'Do it',
      'onboarding.doneTag': 'Done',
      'onboarding.refresh': 'Refresh',
      'onboarding.notifyNeeded': 'Notification permission is required to type the pairing code',
      'onboarding.pairSent': 'Notification sent: open Wireless debugging → Pair device with pairing code, then type the code into the notification',
      'onboarding.pairSentManual': 'Notification sent. Please open Developer options → Wireless debugging → Pair device manually',
      'onboarding.deployOk': 'Framework deployed',
      'onboarding.deployFail': 'Deployment failed',
      'onboarding.enter': 'Enter app',
      'onboarding.agree': 'I understand — get started',

      // ---- settings ----
      'settings.title': 'Settings',
      'settings.section.shell': 'Shell',
      'settings.section.framework': 'Framework',
      'settings.section.shellFramework': 'Shell & framework',
      'settings.tools': 'Framework tools',
      'settings.toolsHint': 'Terminal / resources / snapshots',
      'settings.section.danger': 'Danger zone',
      'tools.title': 'Framework tools',
      'tools.section.diagnostics': 'Diagnostics',
      'tools.section.data': 'Data',
      'settings.section.permissions': 'Permissions',
      'settings.section.security': 'Security',
      'settings.storageAllFiles': 'All files access',
      'settings.hideApp': 'Hide app',
      'settings.biometric': 'Biometric lock',
      'settings.uninstallTitle': 'Uninstall iwphone framework',
      'settings.section.appearance': 'Appearance',
      'settings.section.about': 'About',
      'settings.autostart': 'Autostart',
      'settings.autostartSettings': 'Autostart settings',
      'settings.autostartHint': 'Pair device, fixed port, last run result',
      'settings.mountNs': 'Mount namespace',
      'settings.mountNsValue': 'Global',
      'settings.frameworkConfig': 'Framework config',
      'settings.frameworkConfigHint': 'Poll interval / timeout / sandbox / access key',
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
          'The framework shell API listens on the loopback interface. A key keeps other '
              'apps out; without one it still works, just stays open.',
      'home.tokenCardSkip': 'Skip',
      'home.tokenCardAction': 'Set now',
      'home.tokenSet': 'Access key active — framework unlocked',

      // ---- modules ----
      'modules.running': 'Running',
      'modules.installed': 'Installed',
      'modules.resourceModule': 'Resource module',
      'modules.conflictSeparator': ', ',
      'modules.conflictPrefix': 'Resource conflict with ',
      'modules.conflictSuffix': '',
      'modules.startFailed': 'Failed to start: WebUI is not running or the network is blocked',
      'modules.stopFailed': 'Failed to stop: WebUI is not running or the network is blocked',
      'modules.reinstallTitle': 'Reinstall module',
      'modules.installTitle': 'Install module',
      'modules.reinstallConfirmPrefix': 'Overwrite the installed "',
      'modules.reinstallConfirmSuffix':
          '".\n\nThe module folder is re-extracted and overwritten; if you edited any files in it, those changes will be lost.\n\nReinstall now?',
      'modules.installConfirmPrefix': 'Install "',
      'modules.installConfirmSuffix':
          '" into the framework.\n\nYou can start it from this page afterwards.\n\nInstall now?',
      'modules.reinstall': 'Reinstall',
      'modules.install': 'Install',
      'modules.reinstalledToastPrefix': 'Reinstalled: ',
      'modules.installedToastPrefix': 'Installed: ',
      'modules.installFailed':
          'Operation failed: WebUI unreachable or the package is incomplete',
      'modules.actionOutputSuffix': ' · Action output',
      'modules.noOutput': '(no output)',
      'modules.restoreFailedPrefix': 'Restore failed: ',
      'modules.uninstallTitle': 'Uninstall module',
      'modules.uninstallIntroPrefix': 'Uninstalling "',
      'modules.uninstallIntroSuffix':
          '".\n\nThis will:\n· Stop this module (if it is running)\n· Delete the module folder ',
      'modules.uninstallRestoreSuffix':
          '\n· Clean up its locks, trigger files and logs\n\nThis module changed system settings (it has a write-ahead snapshot). Restoring is recommended; otherwise the changes stay on the device. The snapshot is kept, so you can still restore it later in Settings → Snapshots.',
      'modules.uninstallConfirmSuffix':
          '\n· Clean up its locks, trigger files and logs\n\nThe module must be reinstalled to recover. Uninstall now?',
      'modules.restoreSettingsToo': 'Also restore system settings',
      'modules.restoreSettingsTooHint': 'Stops the module, restores, then uninstalls',
      'modules.uninstall': 'Uninstall',
      'modules.uninstalledToastPrefix': 'Uninstalled: ',
      'modules.uninstallFailed':
          'Uninstall failed: WebUI unreachable or the module no longer exists',
      'modules.restoredSettings': 'System settings restored.',
      'modules.snapshotRestoreFailedPrefix': 'Restore failed (',
      'modules.snapshotRestoreFailedSuffix':
          ') — the snapshot is kept; retry in Settings → Snapshots.',
      'modules.actionFailedPrefix': 'Operation failed: ',
      'modules.noStartableModules': 'No stopped modules to start',
      'modules.startAllTitle': 'Start all modules',
      'modules.startAllConfirmPrefix': 'Starting ',
      'modules.startAllConfirmMiddle': ' stopped module(s):\n\n',
      'modules.startAllConfirmSuffix': 'Start now?',
      'modules.startAll': 'Start all',
      'modules.startedCountPrefix': 'Started ',
      'modules.startedCountSuffix': ' modules',
      'modules.title': 'Modules',
      'modules.filterAll': 'All',
      'modules.filterStopped': 'Stopped',
      'modules.stopAllTitle': 'Stop all modules',
      'modules.stopAllConfirm':
          'Stops every running module cleanly, one by one, via the framework lock.\n\n'
              '⚠️ If a module has escaped lock management (e.g. it daemonized its main loop '
              'into the background), its lock record no longer matches the real process and '
              'this stop will not work — use "Force stop" instead.\n\nStop now?',
      'modules.stopAll': 'Stop all',
      'modules.forceStopAllTitle': 'Force stop all modules',
      'modules.forceStopConfirm':
          '⚠️ Bypasses the framework lock and kills the whole process tree of every module.\n\n'
              'Difference from a normal stop:\n'
              '· Does not rely on lock records — identifies modules by each process working directory\n'
              '· Terminates child and grandchild processes too\n'
              '· Modules get no chance to run cleanup (e.g. exiting doze state)\n\n'
              'Use this when a module is stuck, its lock is lost, or its process escaped '
              'management. Force stop now?',
      'modules.forceStop': 'Force stop',
      'modules.restartAllTitle': 'Restart all modules',
      'modules.restartAllConfirm':
          'Force-stops all module processes first, then relaunches the ones that were running before.\n\n'
              'Modules that were not running are not started.\n\nRestart now?',
      'modules.restartAll': 'Restart all',
      'modules.loadingModules': 'Loading modules…',
      'modules.notConnectedPrefix':
          'Not connected to the iwphone WebUI (http://127.0.0.1:8537).\nRun this in a terminal first: ',
      'modules.noMatchingModules': 'No modules match this filter',
      'modules.config': 'Config',
      'modules.action': 'Action',
      'modules.restore': 'Restore',
      'modules.conflictTitle': 'Resource conflict',
      'modules.conflictDesc':
          'This module declares the same system resources as the modules below. If they run at the '
              'same time, the framework rejects whichever starts later so their configs cannot '
              'overwrite each other.',
      'modules.conflictModules': 'Conflicting modules',
      'modules.conflictResources': 'Involved resources',
      'modules.conflictAdvice': 'To run this module, stop the modules above first.',
      'modules.compatOk': 'Likely compatible',
      'modules.compatBlocked': 'Requires root — will not work',
      'modules.compatUnknown': 'Cannot be determined automatically — please verify manually',
      'modules.compatDetailTitle': 'Compatibility pre-check',
      'modules.noReasons': '(no details)',
      'modules.compatDesc':
          'The pre-check is a static scan, so keywords inside comments match too (deliberately '
              'conservative). Actual behavior depends on how the module runs.',
      'modules.reinstallHint':
          'Overwrites the current version with the package; manual edits will be lost',
      'modules.uninstallHint': 'Deletes the module folder and logs — cannot be undone',

      // ---- module install ----
      'install.importFailedPrefix': 'Import failed: ',
      'install.importedPrefix': 'Imported ',
      'install.importedSuffix': ' — tap it in the list to install',
      'install.confirmInstallPrefix': 'Install "',
      'install.confirmReinstallPrefix': 'Overwrite the installed "',
      'install.confirmNameSuffix': '".\n\n',
      'install.confirmReinstallNote':
          'The module folder will be overwritten by the package; manual edits will be lost.',
      'install.confirmBody':
          'The module format (iwphone native / Magisk·KernelSU·AxManager compatible) is detected automatically.\n'
              'It can take tens of seconds — please wait.',
      'install.reinstallTitle': 'Reinstall module',
      'install.installTitle': 'Install module',
      'install.reinstall': 'Reinstall',
      'install.install': 'Install',
      'install.installedPrefix': '"',
      'install.installedSuffix': '" installed successfully',
      'install.installFailedSuffix': '" failed to install (see framework logs)',
      'install.sectionFramework': 'Framework packages (module/ folder)',
      'install.emptyPackages':
          'No installable packages in the framework module/ folder.\n'
              'Use Local import above to push in an .iwp or Magisk-style module zip first.',
      'install.footnote':
          '· Two formats supported: iwphone native packages (main.sh + iwphone.prop) and\n'
              '  Magisk / KernelSU / AxManager style modules (module.prop + service.sh);\n'
              '  the format is detected and adapted automatically on install.\n'
              '· Install = extract over work/<module name>/; once done, start it on the Modules page.\n'
              '· Magisk modules that replace preinstalled system files will not work without root.',
      'install.importTitle': 'Import from device storage',
      'install.importHint':
          'Pick an .iwp or Magisk-style module zip — it is pushed to the device and added to the list',
      'install.importing': 'Importing…',
      'install.chooseFile': 'Choose file',
      'install.installing': 'Installing…',
      'install.installedHint': 'Installed · Tap to reinstall',
      'install.notInstalledHint': 'Not installed · Tap to install',

      'common.delete': 'Delete',

      // ---- logs ----
      'logs.title': 'Logs',
      'logs.sourceModule': 'Module logs',
      'logs.sourceFramework': 'Framework logs',
      'logs.kindOverview': 'Execution overview',
      'logs.loadingModules': 'Loading modules…',
      'logs.webuiUnavailable': 'WebUI unreachable — cannot read module metadata',
      'logs.noModules': 'No modules installed in the framework',
      'logs.emptyLog': '(No logs yet)',
      'logs.selectModulePrompt': 'Select a module to view logs',
      'logs.selectModuleToClear': 'Select a module to clear first',
      'logs.selectModuleToExport': 'Select a module to export first',
      'logs.scopeFramework': 'Framework daemon log',
      'logs.scopeModulePrefix': 'Logs of module "',
      'logs.scopeModuleSuffix': '"',
      'logs.clearTitle': 'Clear logs',
      'logs.clearWhatFramework': '· Framework daemon logs (modrunner_*.log)',
      'logs.clearMessagePrefix': 'You are about to clear ',
      'logs.clearMessageSuffix': ':\n\n',
      'logs.clearWarning':
          'The files are kept (contents emptied); running modules keep logging normally.\n'
              'Cleared history cannot be recovered.\n\nClear now?',
      'logs.clearConfirm': 'Clear',
      'logs.clearFailedPrefix': 'Clear failed: ',
      'logs.exportSuccessTitle': 'Export successful',
      'logs.exportHint':
          'Find it in Files → Internal storage → Download → iwphone_logs — easy to share or copy to a PC.',
      'logs.exportFailedPrefix': 'Export failed: ',
      'logs.gotIt': 'Got it',

      // ---- terminal ----
      'terminal.title': 'Terminal',
      'terminal.warning':
          'Commands run directly on the device (framework blacklist and timeout apply)',
      'terminal.chipFileOwner': 'Find file owner',
      'terminal.chipListModules': 'List modules',
      'terminal.chipLogTail': 'Framework log tail',
      'terminal.chipDeliverScript': 'Deliver script',
      'terminal.chipFrameworkConfig': 'Framework config',
      'terminal.emptyHint': 'Type a command, or tap a shortcut above',
      'terminal.inputHint': 'Type a command…',
      'terminal.ownerDialogTitle': 'Find the app that owns a file',
      'terminal.ownerDialogDesc':
          'Enter a file or directory path; the framework traces its owner back to an app.',
      'terminal.ownerDialogQuery': 'Look up',
      'terminal.running': 'Running…',
      'terminal.failed': 'Execution failed',
      'terminal.noOutput': '(No output)',

      // ---- resources ----
      'resources.title': 'Resource usage',
      'resources.conflictLog': 'Conflict log',
      'resources.entriesUnit': 'entries',
      'resources.itemsUnit': 'items',
      'resources.all': 'All',
      'resources.modulesUnit': 'modules',
      'resources.empty':
          'No resource usage recorded yet.\nOnce a module writes system settings through the sandbox, its ownership will appear here.',

      // ---- snapshots ----
      'snapshot.orphanNote':
          'This module is uninstalled — only the system-setting changes it left behind will be restored.',
      'snapshot.restoreFailedPrefix': 'Restore failed: ',
      'snapshot.deleteTitle': 'Delete snapshot',
      'snapshot.deleteMessagePrefix': 'Deleting the snapshot for "',
      'snapshot.deleteMessageMiddle': '" — the ',
      'snapshot.deleteMessageSuffix':
          ' system settings it changed will **no longer be restorable with one tap**.\n\nOnly delete it if you no longer need to roll back (or plan to keep the current state).',
      'snapshot.uninstalledBadge': 'Uninstalled',
      'snapshot.restorableUnit': 'to restore',
      'snapshot.manualUnit': 'needs manual handling',
      'snapshot.restore': 'Restore',
      'snapshot.empty':
          'No snapshots yet.\n\nA snapshot is created automatically when a module **first changes a system setting** — start a module that modifies settings (e.g. animation speed) and come back.',
      'snapshot.notes':
          '· Snapshots are created automatically the first time a module **writes** a system resource, '
              'recording the original value beforehand.\n'
              '· Snapshots are kept after a module is uninstalled — the settings it changed can still be restored.\n'
              '· Restoring stops the module first (so its guard loop cannot write the values back); '
              'on success the snapshot is archived and a new one is created when the module restarts.',

      // ---- resource summary ----
      'resourceSummary.noConflict': 'No resource conflicts',
      'resourceSummary.detectedPrefix': 'Detected ',
      'resourceSummary.conflictCountSuffix': ' resource conflicts',
      'resourceSummary.conflictResources': 'Conflicting resources',
      'resourceSummary.usedResources': 'Resources in use',
      'resourceSummary.conflictLog': 'Conflict log',
      'resourceSummary.conflictHint':
          'When several modules write the same resource, the one started first wins and later writes may be '
              'overwritten. For stable long-term operation, keep only one module handling that resource.',
      'resourceSummary.checking': 'Checking resource usage…',
      'resourceSummary.healthy': 'Resource usage normal',
      'resourceSummary.empty': 'No resource usage',
      'resourceSummary.detailLoading': 'Reading module resource declarations and runtime records',
      'resourceSummary.occupiedPrefix': 'Uses ',
      'resourceSummary.tapDetailsSuffix': ' resources — tap to see conflict details',
      'resourceSummary.noDuplicateSuffix': ' resources, no duplicate declarations',
      'resourceSummary.emptyDetail': 'Module ownership appears here once modules write system settings',
      'resourceSummary.conflictBadge': 'Conflict',

      // ---- snapshot sheet ----
      'snapshotSheet.title': 'Restore system settings',
      'snapshotSheet.restorePrefix': 'Will restore ',
      'snapshotSheet.restoreMid':
          ' items to the original values from **before the module first wrote them**',
      'snapshotSheet.alsoPrefix': ' (another ',
      'snapshotSheet.alsoSuffix': ' items need manual handling)',
      'snapshotSheet.restoreEnd':
          '.\nThe module is stopped first, otherwise its guard loop would write the settings back.',
      'snapshotSheet.noRestorable': 'Nothing to restore',
      'snapshotSheet.restoreButtonPrefix': 'Restore ',
      'snapshotSheet.restoreButtonSuffix': ' items',
      'snapshotSheet.unknownResource': '(Unknown resource)',
      'snapshotSheet.emptyValue': '(empty)',
      'snapshotSheet.currentPrefix': 'Current ',
      'snapshotSheet.arrowRestore': '  →  restore to ',
      'snapshotSheet.manualNeeded': 'The sandbox did not record this value — handle it manually',

      // ---- framework config ----
      'config.loading': 'Reading framework config…',
      'config.unavailable':
          'Not connected to the iwphone WebUI (127.0.0.1:8537).\nMake sure the framework and WebUI are running.',
      'config.empty': 'The framework returned no configurable items',
      'config.footer': 'Config is written to the framework env.sh (backed up automatically before changes)',
      'config.pendingBadge': 'Pending',
      'config.newValueHint': 'Enter a new value',
      'config.rangeLabel': 'Valid range ',
      'config.updateFailPrefix': 'Update failed: ',
      'config.restartNeededPre': '',
      'config.restartNeededPost': ' change(s) need a framework restart to take effect',
      'config.restartMessage':
          'Config changes take effect only after the daemon restarts.\n\n'
              'Restarting interrupts the current polling cycle; running modules are not affected.\n\n'
              'Restart now?',
      'config.restartConfirm': 'Restart',
      'config.restartOk': 'Framework restarted — config applied',
      'config.restartFail': 'Restart failed: WebUI unreachable',

      // ---- module config ----
      'modConfig.loadFailed': 'Failed to load config: WebUI unreachable',
      'modConfig.saved': 'Config saved',
      'modConfig.saveFailPrefix': 'Save failed: ',
      'modConfig.resetTitle': 'Restore defaults',
      'modConfig.resetMessage':
          'Reset all options in this module to the defaults declared by the module.\n\n'
              'This only changes the values shown here — press "Save" to actually write them.',
      'modConfig.emptyState':
          'This module has no configurable options.\n(A module must provide config.prop to expose config options)',
      'modConfig.dirty': 'Unsaved changes',
      'modConfig.upToDate': 'Up to date',
      'modConfig.saving': 'Saving…',
      'modConfig.saveAction': 'Save config',

      // ---- autostart ----
      'autostart.notConnectedTitle': 'Not connected to the framework yet',
      'autostart.pairGuideBody':
          'Start pairing now?\n\n'
              'Flow: tap "Start pairing" → a text field appears in the notification shade → '
              'go to Developer options → Wireless debugging and open "Pair device with pairing code" → '
              'type the pair code into the notification → done.\n\n'
              'The pairing port is discovered automatically — no PC needed at any point.',
      'autostart.notNow': 'Not now',
      'autostart.startPairing': 'Start pairing',
      'autostart.failedPrefix': 'Failed: ',
      'autostart.successPrefix': 'Succeeded: ',
      'autostart.repairFramework': 'Repair framework',
      'autostart.deployMsgHead':
          'Push the framework bundle included in the app to the device and extract it to',
      'autostart.deployMsgTail':
          'Existing files will be overwritten (a damaged or accidentally deleted script can be restored '
              'in one tap).\nThis takes about 1–2 minutes — keep the screen on.',
      'autostart.notifyDenied':
          'Notification permission not granted — autostart results cannot be reported to you',
      'autostart.pairPermissionDenied':
          'Notification permission not granted — cannot start pairing',
      'autostart.pairStartFailed': 'Failed to start pairing: ',
      'autostart.manualPairBody':
          'On the phone: Settings → Developer options → Wireless debugging → '
              '"Pair device with pairing code".\n\n'
              'Enter the two numbers from the dialog below (**keep that pairing dialog open** — '
              'the port changes once it closes).',
      'autostart.pairPortLabel': 'Pairing port',
      'autostart.pairPortHint': 'e.g. 37193',
      'autostart.pairCodeLabel': 'Pair code',
      'autostart.pairCodeHint': 'e.g. 123456',
      'autostart.pair': 'Pair',
      'autostart.bothRequired': 'Both the pairing port and the pair code are required',
      'autostart.pairedPortFixed': 'Paired — port fixed to ',
      'autostart.pairedPortFixFailed': 'Paired, but fixing the port failed: ',
      'autostart.alreadyRunning': 'The framework is already running — no need to start it again',
      'autostart.sectionSteps': 'Setup steps',
      'autostart.sectionVerify': 'Verify',
      'autostart.sectionNotice': 'Important',
      'autostart.stepNotifyDesc':
          'Autostart runs silently in the background — without notifications you cannot tell whether it worked.',
      'autostart.granted': 'Granted',
      'autostart.grantAction': 'Grant',
      'autostart.stepPairTitle': 'Device pairing',
      'autostart.stepPairDesc':
          'Tap "Pair" and type the pair code into the notification — the pairing port is found automatically, '
              'no copying needed. Do this once: the key survives reboots, so every later boot re-authenticates silently.',
      'autostart.paired': 'Paired',
      'autostart.pairAction': 'Pair',
      'autostart.manualEntry': 'Enter manually',
      'autostart.stepPortTitle': 'Fix ADB port',
      'autostart.stepPortDescHead': 'Pin the port to',
      'autostart.stepPortDescTail':
          '. This setting survives reboots and the system listens on it after boot — that is what makes it fully automatic.',
      'autostart.portFixedLabel': 'Fixed',
      'autostart.runAction': 'Apply',
      'autostart.runOnce': 'Run once now',
      'autostart.running': 'Running…',
      'autostart.verifyHint':
          'No need to wait for the next boot — this runs the whole chain (re-authenticate → grab a shell → '
              'start the framework) and shows the real result.',
      'autostart.autostartSettingsMissing':
          'Autostart manager page not found — allow the app manually in system settings',
      'autostart.deploying': 'Deploying…',
      'autostart.deployed': 'Deployed',
      'autostart.notDeployed': 'Not deployed',
      'autostart.detecting': 'Detecting…',
      'autostart.frameworkPackage': 'Framework bundle',
      'autostart.repair': 'Repair',
      'autostart.deployBtn': 'Deploy',
      'autostart.frameworkDescHead':
          'The app ships the whole framework (including a Python runtime, about 12MB).\nInstall location:',
      'autostart.frameworkDescTail':
          'Tap "Repair" again to restore the framework to factory state — a broken or deleted script is no problem.\n'
              'If the framework is missing at startup, it is deployed automatically.',
      'autostart.neverRun': 'Never run',
      'autostart.success': 'Success',
      'autostart.failure': 'Failed',
      'autostart.statusEnabled': 'Autostart is on',
      'autostart.statusDisabled': 'Autostart is off',
      'autostart.keyLabel': 'ADB key',
      'autostart.keyGenerated': 'Generated (pair if not yet authorized)',
      'autostart.keyNotGenerated': 'Not generated',
      'autostart.portLabel': 'Fixed port',
      'autostart.lastRun': 'Last run',
      'autostart.noticeBody':
          '· Xiaomi / Redmi devices block the boot broadcast by default — allow this app in the system '
              '"Autostart manager", otherwise autostart does nothing, **with no error at all**.\n\n'
              '· Autostart relies on a fixed port, so that port stays listening. Connecting still requires '
              'the ADB key, but devices on the same network can still try — do not leave it on for long '
              'on untrusted networks.\n\n'
              '· While the framework is running, do not switch USB / wireless debugging or run adb '
              'mode-switch commands: that restarts the ADB service and kills the framework process with it.',
      'autostart.openAutostartSettings': 'Open system autostart manager',

      // ---- home extras ----
      'home.actionFailedSuffix':
          ' failed: WebUI unreachable or the framework is not responding',
      'home.stopAction': 'Stop',
      'home.stopMessage':
          'Stops the iwphone daemon.\n\n'
              'After stopping, the framework no longer polls the trigger directory; running modules '
              'keep running, but you cannot start new modules from the app or trigger files.\n\nStop now?',
      'home.stopDone': 'Framework stopped',
      'home.restartAction': 'Restart',
      'home.restartMessage':
          'Stops and then starts the iwphone daemon.\n\n'
              'Restarting interrupts the current polling cycle, so module start requests are not '
              'answered meanwhile; running modules are not affected.\n\nRestart now?',
      'home.restartDone': 'Framework restarted',
      'home.syncAction': 'Sync',
      'home.syncMessage':
          'Mirrors the runtime state to /sdcard/iwphone/state/.\n\n'
              'Syncing walks every module folder and may be briefly slower with many modules.\n\nSync now?',
      'home.syncDone': 'Sync complete',
      'home.probing': 'Detecting the iwphone framework…',
      'home.daemonRunning': 'The iwphone modrunner v3 daemon is running',
      'home.daemonMissing':
          'Run this in a terminal first:\nadb shell sh /data/local/tmp/iwphone/Main.sh &',
      'home.webuiAddress': 'WebUI address',
      'home.runAs': 'Running as',

      // ---- settings extras ----
      'settings.autostartNeedsPair':
          'Device pairing is not finished yet — autostart cannot work, the switch stays off',
      'settings.permissionGranted': 'Granted',
      'settings.permissionNotRequired': 'Not required',
      'settings.permissionGrant': 'Grant',
      'settings.uninstallMessage':
          '⚠️ The most dangerous operation — irreversible.\n\n'
              'This will delete:\n'
              '· The runtime directory (all installed modules, locks, trigger files)\n'
              '· The log directory and state mirror\n\n'
              'The framework source folder is kept and can be reinstalled with the one-tap script.\n'
              'After uninstalling, the app cannot connect to the framework.\n\nContinue?',
      'settings.uninstallQueued': 'Uninstall started',
      'settings.uninstallFailedTitle': 'Uninstall failed',

      // ---- access key dialog ----
      'webuiToken.titleSet': 'Set access key',
      'webuiToken.titleChange': 'Change access key',
      'webuiToken.desc':
          'The framework WebUI exposes a shell-privileged API and listens on the loopback interface — '
              'any app on this device can reach it, so a key is required to keep them out.\n\n'
              'Choose your own key (at least 8 characters). Once set:\n'
              '· The app sends it automatically\n'
              '· Use it in the WebUI URL to open it in a browser\n\n'
              'The key only lives on your phone (file mode 600 on the framework side).',
      'webuiToken.label': 'Access key',
      'webuiToken.setting': 'Applying…',
      'webuiToken.empty': 'Enter an access key',
      'webuiToken.tooShortPrefix': 'At least ',
      'webuiToken.tooShortSuffix': ' characters',
      'webuiToken.hasWhitespace': 'Must not contain spaces or line breaks',
      'webuiToken.applied': 'Access key is now active',

      // ---- system info ----
      'systemInfo.unknown': 'Unknown',
      'systemInfo.enforcing': 'Enforcing',
      'systemInfo.permissive': 'Permissive',
      'systemInfo.disabled': 'Disabled',

      // ---- module config values ----
      'moduleConfig.on': 'On',
      'moduleConfig.off': 'Off',
      'moduleConfig.emptyValue': '(empty)',

      // ---- conflict type labels ----
      'conflictType.block': 'Start blocked',
      'conflictType.writer': 'Multiple writers',
      'conflictType.drift': 'Value changed',

      // ---- service fallback messages ----
      'service.callFailed': 'Call failed',
      'iwphone.webuiUnreachable': 'WebUI unreachable',
      'iwphone.clearUnavailable': 'WebUI unreachable — cannot clear logs',
      'iwphone.exportUnavailable': 'WebUI unreachable — cannot export logs',
      'iwphone.badResponse': 'Failed to parse the response',
      'iwphone.saved': 'Saved',
      'iwphone.saveFailed': 'Save failed',
      'iwphone.executed': 'Executed',
      'iwphone.execFailed': 'Execution failed',
      'iwphone.readFailed': 'Failed to read',
      'iwphone.readSnapshotFailed': 'Failed to read the snapshot',
      'iwphone.readSnapshotListFailed': 'Failed to read the snapshot list',
      'iwphone.deleted': 'Deleted',
      'iwphone.deleteFailed': 'Delete failed',
      'iwphone.restored': 'Restored',
      'iwphone.restoreFailed': 'Restore failed',
      'iwphone.shellUnavailable':
          'WebUI unreachable (the service is not running, or the framework was uninstalled)',
      'snapshotItem.deleteItem': '(delete this item)',
      'snapshotItem.manual': 'Needs manual handling',
      'snapshotItem.command': 'Restore by command',
      'common.gotIt': 'Got it',

      // ---- about ----
      'about.description': 'Root-free Android module manager',
      'about.github': 'https://github.com/haothtrteen/IwphoneModules',
      'about.license': 'GPL-3.0',
    },
  };
}
