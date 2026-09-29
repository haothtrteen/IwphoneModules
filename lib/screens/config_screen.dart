import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/iwphone_module.dart';
import '../services/iwphone_service.dart';
import '../theme/app_theme.dart';
import '../widgets/back_icon_button.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/screen_app_bar.dart';

/// 框架配置页 —— 读写 env.sh 中的可配置项。
///
/// 后端只暴露一份白名单（运行行为 / 安全 / WebUI 三组），
/// 路径类与端口类不在此列（改错会让框架找不到目录或 App 直接失联）。
///
/// 注意：多数配置项由守护进程在**启动时**读取，改完需重启框架才生效，
/// 因此页尾提供「重启框架」入口。
class ConfigScreen extends StatefulWidget {
  const ConfigScreen({super.key, required this.reloadToken});

  final int reloadToken;

  @override
  State<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends State<ConfigScreen> {
  bool _loading = true;
  bool _available = false;
  List<IwphoneConfigItem> _items = const [];

  /// 本次会话内改动过的项，用于提示「需重启生效」。
  final Set<String> _dirty = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ConfigScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadToken != widget.reloadToken) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
    });
    final avail = await IwphoneService.instance.checkAvailable();
    final list = await IwphoneService.instance.getConfig();
    if (!mounted) return;
    setState(() {
      _available = avail;
      _items = list;
      _loading = false;
    });
  }

  /// 按 group 归组，保持后端返回顺序。
  Map<String, List<IwphoneConfigItem>> get _grouped {
    final m = <String, List<IwphoneConfigItem>>{};
    for (final it in _items) {
      m.putIfAbsent(it.group, () => []).add(it);
    }
    return m;
  }

  Future<void> _edit(IwphoneConfigItem item) async {
    String draft = item.value;
    if (item.isBool) {
      draft = item.boolValue ? '0' : '1';
    } else {
      final input = await _askValue(item);
      if (input == null) return;
      draft = input;
    }

    final res = await IwphoneService.instance.setConfig(item.key, draft);
    if (!mounted) return;

    if (res.ok) {
      setState(() => _dirty.add(item.key));
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(res.ok ? res.msg : '修改失败：${res.msg}')),
    );
    if (res.ok) await _load();
  }

  Future<String?> _askValue(IwphoneConfigItem item) async {
    final ctrl = TextEditingController(text: item.value);
    final isNum = item.isInt;

    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(item.label, style: AppText.cardTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(item.desc, style: AppText.desc12),
            const SizedBox(height: 14),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType:
                  isNum ? TextInputType.number : TextInputType.text,
              inputFormatters: isNum
                  ? [FilteringTextInputFormatter.allow(RegExp(r'-?\d'))]
                  : null,
              style: AppText.rowLabel,
              decoration: InputDecoration(
                hintText: isNum ? '${item.min} ~ ${item.max}' : '输入新值',
                hintStyle: AppText.desc12,
                helperText: isNum ? '取值范围 ${item.min} ~ ${item.max}' : null,
                helperStyle: AppText.desc12,
                enabledBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: AppColors.divider),
                ),
                focusedBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: AppColors.accent),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消',
                style: AppText.rowLabel
                    .copyWith(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: Text('保存',
                style: AppText.rowLabel.copyWith(color: AppColors.accent)),
          ),
        ],
      ),
    );
  }

  Future<void> _restartFramework() async {
    final ok = await showConfirmDialog(
      context,
      title: '重启框架',
      message: '配置改动需要重启守护进程才会生效。\n\n'
          '重启会打断当前轮询周期，已在运行的模块不受影响。\n\n确定要重启吗？',
      confirmText: '重启',
    );
    if (!ok || !mounted) return;

    final done = await IwphoneService.instance.runnerRestart();
    if (!mounted) return;
    if (done) setState(() => _dirty.clear());
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(done ? '框架已重启，配置已生效' : '重启失败：WebUI 不可达')),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _grouped;

    // 本页是 Navigator.push 打开的独立页面，不像主页面那样有外层 Scaffold，
    // 必须自带 Scaffold —— 否则 InkWell / TextButton 找不到 Material 祖先会直接抛错。
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: RefreshIndicator(
          color: AppColors.accent,
          backgroundColor: AppColors.surface,
          onRefresh: _load,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const BackIconButton(),
                    Expanded(
                      child: ScreenAppBar(
                        title: '框架配置',
                        actions: [
                          AppBarActionIcon(icon: Icons.refresh, onTap: _load),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_loading)
                  const _Hint('正在读取框架配置…')
                else if (!_available)
                  const _Hint('未连接到 iwphone WebUI（127.0.0.1:8537）。\n'
                      '请先确认框架与 WebUI 正在运行。')
                else if (_items.isEmpty)
                  const _Hint('框架未返回任何可配置项')
                else ...[
                  for (final entry in grouped.entries) ...[
                    _GroupCard(
                      title: entry.key,
                      items: entry.value,
                      dirtyKeys: _dirty,
                      onEdit: _edit,
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (_dirty.isNotEmpty)
                    _RestartHint(
                      count: _dirty.length,
                      onRestart: _restartFramework,
                    ),
                ],
                const SizedBox(height: 16),
                const Text('配置写入框架的 env.sh（修改前会自动备份）',
                    style: AppText.footer, textAlign: TextAlign.center),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text, style: AppText.body13, textAlign: TextAlign.center),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({
    required this.title,
    required this.items,
    required this.dirtyKeys,
    required this.onEdit,
  });

  final String title;
  final List<IwphoneConfigItem> items;
  final Set<String> dirtyKeys;
  final void Function(IwphoneConfigItem) onEdit;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppText.sectionTitle),
          const SizedBox(height: 12),
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(height: 14),
            _ConfigRow(
              item: items[i],
              dirty: dirtyKeys.contains(items[i].key),
              onEdit: () => onEdit(items[i]),
            ),
          ],
        ],
      ),
    );
  }
}

class _ConfigRow extends StatelessWidget {
  const _ConfigRow({
    required this.item,
    required this.dirty,
    required this.onEdit,
  });

  final IwphoneConfigItem item;
  final bool dirty;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onEdit,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          item.label,
                          style: AppText.rowLabel,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (dirty) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.accentDim,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text('待生效',
                              style: AppText.badge
                                  .copyWith(color: AppColors.accent)),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  item.displayValue,
                  style: AppText.monoValue14.copyWith(
                    color: item.isBool
                        ? (item.boolValue
                            ? AppColors.accent
                            : AppColors.textInactive)
                        : AppColors.textSecondary,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right,
                    size: 18, color: AppColors.textSecondary),
              ],
            ),
            const SizedBox(height: 3),
            Text(item.desc, style: AppText.desc12),
          ],
        ),
      ),
    );
  }
}

class _RestartHint extends StatelessWidget {
  const _RestartHint({required this.count, required this.onRestart});

  final int count;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.accentDim,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text('有 $count 项改动需要重启框架才会生效',
                style: AppText.body13.copyWith(color: AppColors.accent)),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onRestart,
            child: Text('重启框架',
                style: AppText.rowLabel.copyWith(color: AppColors.accent)),
          ),
        ],
      ),
    );
  }
}
