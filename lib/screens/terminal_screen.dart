import 'package:flutter/material.dart';

import '../models/iwphone_module.dart';
import '../services/iwphone_service.dart';
import '../theme/app_theme.dart';
import '../widgets/back_icon_button.dart';
import '../widgets/screen_app_bar.dart';

/// 单条终端记录。
class _TermEntry {
  _TermEntry({required this.cmd});

  final String cmd;

  /// null 表示仍在执行中。
  ShellResult? result;
}

/// 内置终端 —— 直接在设备上执行 shell 命令。
///
/// 这是框架「无 App 场景」能力的图形化入口，可覆盖：
/// · `uid2pkg.sh <文件>` —— 反查文件属于哪个应用
/// · 投递 readbsh 脚本（写 adbsh/main.sh 后触发命令文件）
/// · 查看目录、读日志、手动调试
///
/// 安全由框架侧把关：命令会经过 env.sh 的 COMMAND_BLACKLIST 过滤，
/// 并有 1~60 秒超时；WebUI 仅绑定 127.0.0.1。
class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final List<_TermEntry> _entries = [];

  /// 命令历史（去重、最新在前，最多 20 条）。
  final List<String> _history = [];
  bool _busy = false;

  /// 框架路径前缀，用于快捷命令。
  static const _frame =
      '/data/local/tmp/iwphone_modrunner_v3_slim/iwphone_modrunner_v3';

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _run(String cmd) async {
    final c = cmd.trim();
    if (c.isEmpty || _busy) return;

    setState(() {
      _busy = true;
      _entries.add(_TermEntry(cmd: c));
      _history.remove(c);
      _history.insert(0, c);
      if (_history.length > 20) _history.removeLast();
    });
    _ctrl.clear();
    _scrollToEnd();

    final res = await IwphoneService.instance.runShell(c);
    if (!mounted) return;
    setState(() {
      _entries.last.result = res;
      _busy = false;
    });
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// uid2pkg 需要用户给一个文件路径，单独弹框收集。
  Future<void> _askPath() async {
    final ctrl = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('查询文件所属应用', style: AppText.cardTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('输入文件或目录路径，框架会反查它的所有者属于哪个应用。',
                style: AppText.desc12),
            const SizedBox(height: 14),
            TextField(
              controller: ctrl,
              autofocus: true,
              style: AppText.rowLabel,
              decoration: InputDecoration(
                hintText: '/sdcard/Android/data/…',
                hintStyle: AppText.desc12,
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
            child: Text('查询',
                style: AppText.rowLabel.copyWith(color: AppColors.accent)),
          ),
        ],
      ),
    );
    if (path == null || path.isEmpty) return;
    await _run('sh $_frame/uid2pkg.sh "$path"');
  }

  @override
  Widget build(BuildContext context) {
    // 本页由 Navigator.push 打开，不像主页面那样有外层 Scaffold，
    // 必须自带 —— TextButton / TextField / InkWell 都需要 Material 祖先。
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Row(
                children: [
                  const BackIconButton(),
                  Expanded(
                    child: ScreenAppBar(
                      title: '终端',
                      actions: [
                        AppBarActionIcon(
                          icon: Icons.delete_outline,
                          onTap: _entries.isEmpty
                              ? null
                              : () => setState(() => _entries.clear()),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning_amber_rounded,
                    size: 16, color: AppColors.iconOrange),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '命令直接在设备上执行（框架黑名单与超时保护）',
                    style: AppText.desc12,
                  ),
                ),
              ],
            ),
          ),
        ),
        // 快捷命令
        SizedBox(
          height: 34,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              _Chip(label: '查询文件归属', onTap: _askPath),
              _Chip(
                label: '列出模块',
                onTap: () => _run('ls -la /data/local/tmp/iwphone/work'),
              ),
              _Chip(
                label: '框架日志尾部',
                onTap: () => _run(
                    'tail -n 40 \$(ls -t /sdcard/iwphone/logs/modrunner_*.log 2>/dev/null | head -1)'),
              ),
              _Chip(
                label: '投递脚本',
                onTap: () => _run(
                    'mkdir -p /sdcard/iwphone/adbsh && echo "#!/system/bin/sh\\necho hello from adbsh" > /sdcard/iwphone/adbsh/main.sh && touch /sdcard/iwphone/readbsh && echo 已投递，等待守护消费'),
              ),
              _Chip(
                label: '查看框架配置',
                onTap: () => _run('cat $_frame/env.sh | grep -v "^#"'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: AppColors.bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.divider),
            ),
            child: _entries.isEmpty
                ? Center(
                    child: Text(
                      '输入命令开始，或点上方快捷按钮',
                      style: AppText.desc12,
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: _entries.length,
                    itemBuilder: (_, i) => _EntryView(entry: _entries[i]),
                  ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  style: AppText.monoValue14
                      .copyWith(color: AppColors.textPrimary),
                  onSubmitted: _run,
                  decoration: InputDecoration(
                    hintText: '输入命令…',
                    hintStyle: AppText.desc12,
                    prefixText: '\$ ',
                    prefixStyle: AppText.monoValue14
                        .copyWith(color: AppColors.accent),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                    filled: true,
                    fillColor: AppColors.surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 44,
                width: 56,
                child: TextButton(
                  onPressed: _busy ? null : () => _run(_ctrl.text),
                  style: TextButton.styleFrom(
                    backgroundColor:
                        _busy ? AppColors.switchTrackOff : AppColors.accent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.play_arrow_rounded,
                          color: Colors.white, size: 22),
                ),
              ),
            ],
          ),
        ),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(label, style: AppText.desc12),
        ),
      ),
    );
  }
}

class _EntryView extends StatelessWidget {
  const _EntryView({required this.entry});

  final _TermEntry entry;

  @override
  Widget build(BuildContext context) {
    final r = entry.result;
    final failed = r != null && (!r.ok || (r.exitCode ?? 0) != 0);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            '\$ ${entry.cmd}',
            style: AppText.monoValue14.copyWith(color: AppColors.accent),
          ),
          const SizedBox(height: 4),
          if (r == null)
            Text('执行中…', style: AppText.desc12)
          else if (!r.ok)
            SelectableText(
              r.message.isEmpty ? '执行失败' : r.message,
              style: AppText.monoValue14
                  .copyWith(color: AppColors.iconRed, height: 1.45),
            )
          else ...[
            if (r.combined.trim().isEmpty)
              Text('（无输出）', style: AppText.desc12)
            else
              SelectableText(
                r.combined.trimRight(),
                style: AppText.monoValue14.copyWith(
                  color: failed ? AppColors.iconOrange : AppColors.textPrimary,
                  height: 1.45,
                ),
              ),
            const SizedBox(height: 2),
            Text('exit ${r.exitCode ?? 0}', style: AppText.desc12),
          ],
          const SizedBox(height: 6),
          Container(height: 1, color: AppColors.divider),
        ],
      ),
    );
  }
}
