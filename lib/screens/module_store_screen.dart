import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app_info.dart';
import '../i18n/app_strings.dart';
import '../models/iwphone_module.dart';
import '../models/module_catalog.dart';
import '../services/autostart_service.dart';
import '../services/iwphone_service.dart';
import '../services/module_store_service.dart';
import '../theme/app_theme.dart';
import '../widgets/back_icon_button.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/module_icon.dart';

/// 云端模块库：从 GitHub 仓库拉清单，按需下载 `.iwp` 并安装。
///
/// 设计要点：
/// - 清单只读一次（内存缓存 5 分钟），下拉即刷新
/// - 下载后按清单里的 sha256 校验，不匹配直接拒绝
/// - 安装复用「本地导入 + moduleInstall」这条已经验证过的链路
class ModuleStoreScreen extends StatefulWidget {
  const ModuleStoreScreen({super.key});

  @override
  State<ModuleStoreScreen> createState() => _ModuleStoreScreenState();
}

class _ModuleStoreScreenState extends State<ModuleStoreScreen> {
  bool _loading = true;
  String _error = '';
  ModuleCatalog? _catalog;

  /// 已安装模块的 id 集合，用来显示「已安装 / 更新」。
  Set<String> _installed = {};

  /// 正在处理的模块 id。
  String? _busyId;
  String _busyLabel = '';

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
  }

  Future<void> _load({bool refresh = false}) async {
    setState(() {
      _loading = true;
      _error = '';
    });
    if (refresh) ModuleStoreService.instance.invalidate();

    // 本地已装列表失败不阻断 —— 拿不到就当全都没装
    final local = await IwphoneService.instance.listModules();
    final installed = <String>{for (final IwphoneModule m in local) m.id};

    final catalog = await ModuleStoreService.instance.loadCatalog(refresh: refresh);

    if (!mounted) return;
    setState(() {
      _installed = installed;
      _catalog = catalog;
      _loading = false;
      if (catalog == null) {
        _error = ModuleStoreService.instance.lastError;
      }
    });
  }

  Future<void> _install(StoreModule m) async {
    if (_busyId != null) return;

    final already = _installed.contains(m.id);
    final ok = await showConfirmDialog(
      context,
      title: already
          ? AppStrings.t('store.reinstallTitle')
          : AppStrings.t('store.installTitle'),
      message: '${AppStrings.t('store.confirmPrefix')}${m.name}'
          '${AppStrings.t('store.confirmVersion')}${m.version}\n\n'
          '${AppStrings.t('store.confirmBody')}',
      confirmText: already
          ? AppStrings.t('store.reinstall')
          : AppStrings.t('store.install'),
      danger: already,
    );
    if (ok != true || !mounted) return;

    setState(() {
      _busyId = m.id;
      _busyLabel = AppStrings.t('store.downloading');
    });

    final Uint8List? bytes =
        await ModuleStoreService.instance.downloadModule(m);
    if (!mounted) return;
    if (bytes == null) {
      final reason = ModuleStoreService.instance.lastError;
      setState(() {
        _busyId = null;
        _busyLabel = '';
      });
      _toast(
        reason == 'checksum'
            ? AppStrings.t('store.checksumFail')
            : AppStrings.t('store.downloadFail'),
        ok: false,
      );
      return;
    }

    setState(() => _busyLabel = AppStrings.t('store.installing'));

    final imp = await AutostartService.instance.importPackageBytes(
      bytes: bytes,
      name: '${m.id}.iwp',
    );
    if (!mounted) return;
    if (!imp.ok) {
      setState(() {
        _busyId = null;
        _busyLabel = '';
      });
      _toast('${AppStrings.t('store.installFail')}${imp.msg}', ok: false);
      return;
    }

    final installedOk = await IwphoneService.instance.moduleInstall(m.id);
    if (!mounted) return;
    setState(() {
      _busyId = null;
      _busyLabel = '';
    });

    if (installedOk) {
      IwphoneService.instance.invalidate();
      setState(() => _installed = {..._installed, m.id});
      _toast('${AppStrings.t('store.installedPrefix')}${m.name}');
    } else {
      _toast('${AppStrings.t('store.installFail')}${m.name}', ok: false);
    }
  }

  void _toast(String text, {bool ok = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(text),
      backgroundColor: ok ? null : AppColors.iconRed,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
              child: Row(
                children: [
                  const BackIconButton(),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      AppStrings.t('store.title'),
                      style: AppText.appTitle,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                    color: AppColors.textSecondary,
                    onPressed: _loading ? null : () => _load(refresh: true),
                    tooltip: AppStrings.t('store.refresh'),
                  ),
                ],
              ),
            ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: 12),
            Text(AppStrings.t('store.loading'), style: AppText.desc12),
          ],
        ),
      );
    }

    if (_catalog == null) {
      return _errorCard();
    }

    final modules = _catalog!.modules;
    if (modules.isEmpty) {
      return Center(
        child: Text(AppStrings.t('store.empty'), style: AppText.desc12),
      );
    }

    return RefreshIndicator(
      color: AppColors.accent,
      backgroundColor: AppColors.surface,
      onRefresh: () => _load(refresh: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          Text(
            '${AppStrings.t('store.updatedAt')}${_catalog!.updatedAt}',
            style: AppText.desc12,
          ),
          const SizedBox(height: 12),
          for (final m in modules) ...[
            _StoreCard(
              module: m,
              installed: _installed.contains(m.id),
              busy: _busyId == m.id,
              busyLabel: _busyLabel,
              enabled: _busyId == null,
              onTap: () => _install(m),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 8),
          Text(
            '${AppStrings.t('store.mirrorHint')}\n'
            '${AppStrings.t('store.versionHint')}$kAppVersion',
            style: AppText.desc12,
          ),
        ],
      ),
    );
  }

  Widget _errorCard() {
    final msg = switch (_error) {
      'parse' => AppStrings.t('store.parseFail'),
      'catalog' => AppStrings.t('store.loadFail'),
      _ => AppStrings.t('store.loadFail'),
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 36, color: AppColors.textInactive),
            const SizedBox(height: 12),
            Text(msg, style: AppText.body13, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              AppStrings.t('store.mirrorHint'),
              style: AppText.desc12,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => _load(refresh: true),
              child: Text(AppStrings.t('store.retry')),
            ),
          ],
        ),
      ),
    );
  }
}

class _StoreCard extends StatelessWidget {
  const _StoreCard({
    required this.module,
    required this.installed,
    required this.busy,
    required this.busyLabel,
    required this.enabled,
    required this.onTap,
  });

  final StoreModule module;
  final bool installed;
  final bool busy;
  final String busyLabel;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final actionText = busy
        ? busyLabel
        : (installed
            ? AppStrings.t('store.reinstall')
            : AppStrings.t('store.install'));

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ModuleIconView(
                    moduleId: module.id,
                    iconKey: module.icon,
                    hasIcon: false,
                    fallbackIcon: Icons.extension_rounded,
                    color: AppColors.accent,
                    size: 38,
                    glyphSize: 20,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          module.name,
                          style: AppText.rowLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${module.version} · ${module.author} · ${module.sizeLabel}',
                          style: AppText.desc12,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: !enabled
                          ? AppColors.bg
                          : (installed ? AppColors.bg : AppColors.accentDim),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      actionText,
                      style: AppText.desc12.copyWith(
                        color: !enabled
                            ? AppColors.textInactive
                            : (installed
                                ? AppColors.textSecondary
                                : AppColors.accent),
                      ),
                    ),
                  ),
                ],
              ),
              if (module.description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  module.description,
                  style: AppText.desc12,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
