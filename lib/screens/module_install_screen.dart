import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
import '../models/iwphone_module.dart';
import '../services/autostart_service.dart';
import '../services/iwphone_service.dart';
import '../services/storage_permission_service.dart';
import '../theme/app_theme.dart';
import '../widgets/back_icon_button.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/screen_app_bar.dart';
import 'module_store_screen.dart';

/// 模块安装页 —— 独立页面（自带 Scaffold）。
///
/// ## 为什么单独做一个页面
///
/// 1. **自服务闭环缺的一环**：安装的数据源是框架 `module/` 目录里已有的包，
///    而包得先用电脑 adb push 放进去。本页的「本地导入」用系统文件选择器
///    （SAF）把手机存储里的包经 App 的 adb 通道推到设备 —— 从此装新模块
///    不需要电脑。这个交互放不进底部弹层。
/// 2. **安装前需要决策信息**：兼容层引入后，安装前要知道这是什么格式
///    （iwphone 原生 / Magisk·KernelSU·AxManager 兼容）、声明了哪些独占资源
///    （会改哪些系统资源）、会不会和已装模块冲突。弹层只放得下包名。
/// 3. 安装是 60 秒级长操作，需要进度态与结果展示。
///
/// 数据源仍是框架的 `module/` 目录 —— 导入只是把用户选的文件推过去，
/// 之后由现有安装流水线接管（含 Magisk 式模块的兼容层自动适配）。
class ModuleInstallScreen extends StatefulWidget {
  const ModuleInstallScreen({super.key, required this.service});

  final IwphoneService service;

  @override
  State<ModuleInstallScreen> createState() => _ModuleInstallScreenState();
}

class _ModuleInstallScreenState extends State<ModuleInstallScreen> {
  List<IwphonePackage> _packages = const [];
  bool _loading = true;
  bool _installing = false;
  String? _installingName;
  final Set<String> _importedNames = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final pkgs = await widget.service.listPackages();
    if (!mounted) return;
    setState(() {
      _packages = pkgs;
      _loading = false;
    });
  }

  void _toast(String text, {bool ok = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: ok ? null : AppColors.iconRed,
      ),
    );
  }

  // ---------------- 本地导入 ----------------

  /// SAF 选文件 → App 缓存 → 推到设备 module/ 目录。
  Future<void> _import() async {
    if (_installing) return;

    final pick = await StoragePermissionService.instance.pickFile();
    if (!mounted) return;
    if (!pick.ok) {
      if (pick.msg.isNotEmpty && pick.msg != '未选择文件') _toast(pick.msg, ok: false);
      return;
    }

    // 推到设备（需要已配对；未配对时原生侧会给出明确原因）
    setState(() => _installing = true);
    final imp = await AutostartService.instance.importPackage(
      path: pick.path,
      name: pick.name,
    );
    if (!mounted) return;
    setState(() => _installing = false);

    if (!imp.ok) {
      _toast('${AppStrings.t('install.importFailedPrefix')}${imp.msg}',
          ok: false);
      return;
    }

    _importedNames.add(pick.name);
    await _load();
    if (!mounted) return;
    _toast(
      '${AppStrings.t('install.importedPrefix')}${pick.name}'
      '${AppStrings.t('install.importedSuffix')}',
    );
  }

  // ---------------- 安装 / 重装 ----------------

  Future<void> _install(IwphonePackage pkg) async {
    if (_installing) return;
    final actionText = pkg.installed
        ? AppStrings.t('install.confirmReinstallPrefix')
        : AppStrings.t('install.confirmInstallPrefix');
    final note = pkg.installed
        ? AppStrings.t('install.confirmReinstallNote')
        : '';
    final message = '$actionText${pkg.name}'
        '${AppStrings.t('install.confirmNameSuffix')}'
        '$note${AppStrings.t('install.confirmBody')}';
    final ok = await showConfirmDialog(
      context,
      title: pkg.installed
          ? AppStrings.t('install.reinstallTitle')
          : AppStrings.t('install.installTitle'),
      message: message,
      danger: pkg.installed,
      confirmText: pkg.installed
          ? AppStrings.t('install.reinstall')
          : AppStrings.t('install.install'),
    );
    if (ok != true || !mounted) return;

    setState(() {
      _installing = true;
      _installingName = pkg.name;
    });
    final success = await widget.service.moduleInstall(pkg.name);
    if (!mounted) return;
    setState(() {
      _installing = false;
      _installingName = null;
    });

    if (success) {
      IwphoneService.instance.invalidate();
      await _load();
      if (!mounted) return;
      _toast(
        '${AppStrings.t('install.installedPrefix')}${pkg.name}'
        '${AppStrings.t('install.installedSuffix')}',
      );
    } else {
      _toast(
        '${AppStrings.t('install.installedPrefix')}${pkg.name}'
        '${AppStrings.t('install.installFailedSuffix')}',
        ok: false,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 16, 8),
              child: Row(
                children: [
                  const BackIconButton(),
                  const SizedBox(width: 4),
                  Expanded(
                    child: ScreenAppBar(
                      title: AppStrings.t('install.installTitle'),
                    ),
                  ),
                  IconButton(
                    onPressed: _loading || _installing ? null : _load,
                    icon: Icon(Icons.refresh,
                        size: 20, color: AppColors.textSecondary),
                    tooltip: AppStrings.t('common.refresh'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      children: [
                        _ImportCard(
                          importing: _installing,
                          onImport: _import,
                        ),
                        const SizedBox(height: 8),
                        _StoreEntryCard(
                          onTap: () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const ModuleStoreScreen(),
                              ),
                            );
                            // 从模块库回来可能有新装的包，刷新一下已装状态
                            if (mounted) await _load();
                          },
                        ),
                        const SizedBox(height: 16),
                        _sectionTitle(
                            AppStrings.t('install.sectionFramework')),
                        const SizedBox(height: 8),
                        if (_packages.isEmpty)
                          _EmptyCard(
                            text: AppStrings.t('install.emptyPackages'),
                          )
                        else
                          for (final p in _packages) ...[
                            _PackageCard(
                              pkg: p,
                              busy: _installing && _installingName == p.name,
                              enabled: !_installing,
                              onTap: () => _install(p),
                            ),
                            const SizedBox(height: 8),
                          ],
                        const SizedBox(height: 16),
                        Text(
                          AppStrings.t('install.footnote'),
                          style: AppText.desc12,
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Text(text, style: AppText.sectionTitle);
}

/// 本地导入卡片。
class _ImportCard extends StatelessWidget {
  const _ImportCard({required this.importing, required this.onImport});

  final bool importing;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.file_upload_outlined,
                size: 20, color: AppColors.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(AppStrings.t('install.importTitle'),
                    style: AppText.rowLabel),
                SizedBox(height: 3),
                Text(AppStrings.t('install.importHint'),
                    style: AppText.desc12),
              ],
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: importing ? null : onImport,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: importing ? AppColors.bg : AppColors.accentDim,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                importing
                    ? AppStrings.t('install.importing')
                    : AppStrings.t('install.chooseFile'),
                style: AppText.desc12.copyWith(
                  color: importing ? AppColors.textInactive : AppColors.accent,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 框架目录里的单个包。
class _PackageCard extends StatelessWidget {
  const _PackageCard({
    required this.pkg,
    required this.busy,
    required this.enabled,
    required this.onTap,
  });

  final IwphonePackage pkg;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final state = busy
        ? AppStrings.t('install.installing')
        : (pkg.installed
            ? AppStrings.t('install.installedHint')
            : AppStrings.t('install.notInstalledHint'));
    final color = busy
        ? AppColors.textSecondary
        : (pkg.installed ? AppColors.iconOrange : AppColors.accent);

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // ★ 整行可点。之前这里是纯 Container，函数收了 onTap 却从没绑定过，
        //   右侧那个 AppSwitch 又是个 onChanged: null 的占位 —— 点击当然没反应。
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.bg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  pkg.installed
                      ? Icons.inventory_2_outlined
                      : Icons.archive_outlined,
                  size: 20,
                  color: color,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(pkg.name, style: AppText.rowLabel),
                    const SizedBox(height: 3),
                    Text(state, style: AppText.desc12.copyWith(color: color)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // 明确的动作按钮，别再放一个"看起来能点其实不能"的假开关
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: !enabled
                      ? AppColors.bg
                      : (pkg.installed ? AppColors.bg : AppColors.accentDim),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  busy
                      ? AppStrings.t('install.installing')
                      : (pkg.installed
                          ? AppStrings.t('install.reinstall')
                          : AppStrings.t('install.install')),
                  style: AppText.desc12.copyWith(
                    color: !enabled
                        ? AppColors.textInactive
                        : (pkg.installed
                            ? AppColors.textSecondary
                            : AppColors.accent),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text, style: AppText.desc12, textAlign: TextAlign.center),
    );
  }
}

/// 「在线模块库」入口卡片。
///
/// 单独做成一张卡片而不是塞进标题栏：这是"从网络上取模块"的动作，
/// 和下面「框架自带的模块包」是两条不同的来源，视觉上要分得开。
class _StoreEntryCard extends StatelessWidget {
  const _StoreEntryCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.cloud_download_outlined,
                    size: 20, color: AppColors.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(AppStrings.t('store.entry'),
                        style: AppText.rowLabel),
                    const SizedBox(height: 3),
                    Text(AppStrings.t('store.entryHint'),
                        style: AppText.desc12),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: 20, color: AppColors.textInactive),
            ],
          ),
        ),
      ),
    );
  }
}
