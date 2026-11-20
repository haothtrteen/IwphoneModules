import 'dart:async';

import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
import '../services/iwphone_service.dart';
import '../theme/app_theme.dart';
import '../widgets/back_icon_button.dart';
import '../widgets/screen_app_bar.dart';

/// 单条终端记录。
///
/// 为什么要自己维护一个 StringBuffer 而不是等命令跑完拿一个字符串：
/// 流式命令（`getevent -lt` / `logcat`）不会结束，必须边收边显示。
/// [rendered] 是给 Widget 用的快照 —— 每 120ms 才同步一次，
/// 否则高频输出时每来一个 chunk 就 setState + 重建 SelectableText，会卡成幻灯片。
class _TermEntry {
  _TermEntry({required this.cmd});

  final String cmd;

  final StringBuffer buf = StringBuffer();
  String rendered = '';
  bool dirty = false;

  bool running = true;
  int? exitCode;
  String reason = '';
  String error = '';

  ShellStream? stream;
}

/// 内置终端 —— 直接在设备上执行 shell 命令。
///
/// 这是框架「无 App 场景」能力的图形化入口，可覆盖：
/// · `uid2pkg.sh <文件>` —— 反查文件属于哪个应用
/// · 投递 readbsh 脚本（写 adbsh/main.sh 后触发命令文件）
/// · 查看目录、读日志、手动调试
///
/// 执行走 `/api/shell/stream`（流式），所以 `getevent -lt`、`logcat`、
/// `tail -f` 这些**不会自己结束**的命令也能用：输出边产生边显示，
/// 由「空闲超时」判断什么时候算收工（而不是一刀切的总超时）。
///
/// 安全由框架侧把关：命令会经过 env.sh 的 COMMAND_BLACKLIST 过滤，
/// 流式通道另有并发上限与进程组回收；WebUI 仅绑定 127.0.0.1。
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

  /// 当前正在跑的那一条（同一时刻只跑一条，避免多条输出在单栏里交错）。
  _TermEntry? _active;

  /// 重绘节流：每 120ms 把脏条目刷进 Widget 层。
  Timer? _ticker;

  /// 空闲超时（秒）。0 = 不限 —— 给 `tail -f` 这种可能长时间安静的命令用。
  int _idleSec = 120;
  static const List<int> _idleOptions = [30, 120, 600, 0];

  /// 单条命令最长运行时间（秒），框架侧兜底，防忘记关闭的流一直占着进程。
  static const int _maxSec = 1800;

  /// 单条记录最多保留的字符数。超出后只留尾部一半，避免 getevent 跑久了 OOM。
  static const int _maxChars = 120000;

  /// 框架路径前缀，用于快捷命令。
  /// 与 AdbBootstrap.FRAME_DIR 保持一致：代码和运行时状态同处这一个目录。
  static const _frame = '/data/local/tmp/iwphone';

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(milliseconds: 120), (_) => _flush());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    // 离开页面要把还在跑的流掐掉，否则框架侧会一直跑到空闲超时
    for (final e in _entries) {
      if (e.running) e.stream?.cancel();
    }
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 把脏条目的缓冲区同步成可渲染字符串。
  void _flush() {
    var changed = false;
    for (final e in _entries) {
      if (!e.dirty) continue;
      e.rendered = e.buf.toString();
      e.dirty = false;
      changed = true;
    }
    if (!changed || !mounted) return;
    setState(() {});
    if (_nearBottom) _scrollToEnd();
  }

  bool get _nearBottom {
    if (!_scroll.hasClients) return true;
    final p = _scroll.position;
    return p.pixels >= p.maxScrollExtent - 60;
  }

  Future<void> _run(String cmd) async {
    final c = cmd.trim();
    if (c.isEmpty || _active != null) return;

    final entry = _TermEntry(cmd: c);
    setState(() {
      _active = entry;
      _entries.add(entry);
      _history.remove(c);
      _history.insert(0, c);
      if (_history.length > 20) _history.removeLast();
    });
    _ctrl.clear();
    _scrollToEnd();

    final s = await IwphoneService.instance.streamShell(
      c,
      idleSec: _idleSec,
      maxSec: _maxSec,
    );

    if (s == null) {
      entry
        ..error = AppStrings.t('iwphone.shellUnavailable')
        ..running = false
        ..dirty = true;
      if (mounted) {
        setState(() => _active = null);
        _flush();
      }
      return;
    }

    entry.stream = s;
    try {
      await for (final ev in s.events) {
        if (ev.isOutput) {
          _append(entry, ev.data);
        } else if (ev.isExit) {
          entry.exitCode = ev.exitCode;
          entry.reason = ev.reason;
          entry.running = false;
        } else if (ev.type == 'error') {
          entry.error = ev.message;
          entry.running = false;
        }
      }
    } catch (err) {
      entry.error = '$err';
    } finally {
      entry.running = false;
      entry.dirty = true;
      if (mounted) {
        setState(() => _active = null);
        _flush();
        _scrollToEnd();
      }
    }
  }

  void _append(_TermEntry e, String s) {
    e.buf.write(s);
    if (e.buf.length > _maxChars) {
      final all = e.buf.toString();
      final keep = all.substring(all.length - _maxChars ~/ 2);
      e.buf
        ..clear()
        ..write(AppStrings.t('terminal.trimmed'))
        ..write('\n')
        ..write(keep);
      // 丢掉前部后不再单独标记：缓冲区首行已经带说明
    }
    e.dirty = true;
  }

  Future<void> _stop() async {
    final e = _active;
    if (e == null) return;
    e.reason = 'cancel';
    e.running = false;
    await e.stream?.cancel();
    if (mounted) {
      setState(() => _active = null);
      _flush();
    }
  }

  void _cycleIdle() {
    final i = _idleOptions.indexOf(_idleSec);
    setState(() => _idleSec = _idleOptions[(i + 1) % _idleOptions.length]);
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
        title: Text(AppStrings.t('terminal.ownerDialogTitle'),
            style: AppText.cardTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(AppStrings.t('terminal.ownerDialogDesc'),
                style: AppText.desc12),
            const SizedBox(height: 14),
            TextField(
              controller: ctrl,
              autofocus: true,
              style: AppText.rowLabel,
              decoration: InputDecoration(
                hintText: '/sdcard/Android/data/…',
                hintStyle: AppText.desc12,
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: AppColors.divider),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: AppColors.accent),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(AppStrings.t('common.cancel'),
                style: AppText.rowLabel
                    .copyWith(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: Text(AppStrings.t('terminal.ownerDialogQuery'),
                style: AppText.rowLabel.copyWith(color: AppColors.accent)),
          ),
        ],
      ),
    );
    // 注意：不要在 showDialog 返回后立刻 dispose 这个 controller ——
    // 关闭动画还在跑的时候 TextField 仍会读它，会报 "used after being disposed"。
    if (path == null || path.isEmpty) return;
    await _run('sh $_frame/uid2pkg.sh "$path"');
  }

  @override
  Widget build(BuildContext context) {
    final busy = _active != null;
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
                      title: AppStrings.t('terminal.title'),
                      actions: [
                        AppBarActionIcon(
                          icon: Icons.delete_outline,
                          onTap: _entries.isEmpty
                              ? null
                              : () => setState(() {
                                    _entries.clear();
                                    _active = null;
                                  }),
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
                    Icon(Icons.warning_amber_rounded,
                        size: 16, color: AppColors.iconOrange),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        AppStrings.t('terminal.warning'),
                        style: AppText.desc12,
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 空闲超时切换：流式命令靠它判断"什么时候算跑完"，
                    // 不同的命令合适的值不一样（getevent 10s 就够，
                    // tail -f 可能几分钟没输出），所以交给用户。
                    GestureDetector(
                      onTap: _cycleIdle,
                      child: Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.bg,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _idleSec == 0
                              ? AppStrings.t('terminal.idleForever')
                              : 'idle ${_idleSec}s',
                          style: AppText.desc12
                              .copyWith(color: AppColors.accent),
                        ),
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
                  _Chip(
                      label: AppStrings.t('terminal.chipFileOwner'),
                      onTap: _askPath),
                  _Chip(
                    label: AppStrings.t('terminal.chipGetevent'),
                    onTap: () => _run('getevent -lt'),
                  ),
                  _Chip(
                    label: AppStrings.t('terminal.chipListModules'),
                    onTap: () => _run('ls -la /data/local/tmp/iwphone/work'),
                  ),
                  _Chip(
                    label: AppStrings.t('terminal.chipLogTail'),
                    onTap: () => _run(
                        'tail -n 40 \$(ls -t /sdcard/iwphone/logs/modrunner_*.log 2>/dev/null | head -1)'),
                  ),
                  _Chip(
                    label: AppStrings.t('terminal.chipDeliverScript'),
                    onTap: () => _run(
                        'mkdir -p /sdcard/iwphone/adbsh && echo "#!/system/bin/sh\\necho hello from adbsh" > /sdcard/iwphone/adbsh/main.sh && touch /sdcard/iwphone/readbsh && echo 已投递，等待守护消费'),
                  ),
                  _Chip(
                    label: AppStrings.t('terminal.chipFrameworkConfig'),
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
                          AppStrings.t('terminal.emptyHint'),
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
                        hintText: AppStrings.t('terminal.inputHint'),
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
                      onPressed: busy ? _stop : () => _run(_ctrl.text),
                      style: TextButton.styleFrom(
                        backgroundColor:
                            busy ? AppColors.iconRed : AppColors.accent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: busy
                          ? const Icon(Icons.stop_rounded,
                              color: Colors.white, size: 22)
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

  /// 结束原因 → 用户能看懂的说明。
  String get _reasonText {
    switch (entry.reason) {
      case 'idle':
        return AppStrings.t('terminal.stoppedByIdle');
      case 'max':
        return AppStrings.t('terminal.stoppedByMax');
      case 'cancel':
        return AppStrings.t('terminal.stoppedByUser');
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final out = entry.rendered.trimRight();
    final failed = entry.exitCode != null && entry.exitCode != 0;
    final reason = _reasonText;

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
          if (entry.error.isNotEmpty)
            SelectableText(
              entry.error,
              style: AppText.monoValue14
                  .copyWith(color: AppColors.iconRed, height: 1.45),
            )
          else ...[
            if (out.isNotEmpty)
              SelectableText(
                out,
                style: AppText.monoValue14.copyWith(
                  color: failed ? AppColors.iconOrange : AppColors.textPrimary,
                  height: 1.45,
                ),
              )
            else if (!entry.running)
              Text(AppStrings.t('terminal.noOutput'), style: AppText.desc12),
            if (entry.running)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.5, color: AppColors.accent),
                    ),
                    const SizedBox(width: 6),
                    Text(AppStrings.t('terminal.streaming'),
                        style: AppText.desc12),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  [
                    'exit ${entry.exitCode ?? 0}',
                    if (reason.isNotEmpty) reason,
                  ].join(' · '),
                  style: AppText.desc12,
                ),
              ),
          ],
          const SizedBox(height: 6),
          Container(height: 1, color: AppColors.divider),
        ],
      ),
    );
  }
}
