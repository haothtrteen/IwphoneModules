import 'package:flutter/material.dart';

import '../models/iwphone_module.dart';
import '../services/iwphone_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_switch.dart';
import '../widgets/back_icon_button.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/screen_app_bar.dart';

/// 模块通用配置页 —— 独立页面（自带 Scaffold）。
///
/// ## 为什么是「通用」的
///
/// 模块作者在目录里放一份 `config.prop` 声明选项（键|类型|标签|默认值|可选值|说明），
/// 本页就按声明自动渲染控件 —— 不需要为每个模块单独写界面。
/// 值由后端写进 `config.sh`（shell 赋值），模块 `main.sh` 直接 source 读取。
///
/// 没有声明 config.prop 的模块不该进这个页面（入口会隐藏）。
class ModuleConfigScreen extends StatefulWidget {
  const ModuleConfigScreen({
    super.key,
    required this.moduleName,
    required this.service,
  });

  final String moduleName;
  final IwphoneService service;

  @override
  State<ModuleConfigScreen> createState() => _ModuleConfigScreenState();
}

class _ModuleConfigScreenState extends State<ModuleConfigScreen> {
  ModuleConfig? _config;

  /// 编辑中的值；保存前不会写回设备。
  final Map<String, String> _draft = {};

  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() { _loading = true; _error = null; });
    final cfg = await widget.service.moduleConfig(widget.moduleName);
    if (!mounted) return;
    setState(() {
      _config = cfg;
      _draft
        ..clear()
        ..addAll(cfg?.values ?? const {});
      _loading = false;
      _error = cfg == null ? '读取配置失败：WebUI 不可达' : null;
    });
  }

  bool get _dirty {
    final cfg = _config;
    if (cfg == null) return false;
    for (final s in cfg.specs) {
      if ((_draft[s.key] ?? s.defaultValue) != cfg.values[s.key]) return true;
    }
    return false;
  }

  Future<void> _save() async {
    final cfg = _config;
    if (cfg == null || _saving) return;

    // 只提交声明过的键，避免把界面上的临时状态也带过去
    final payload = <String, String>{};
    for (final s in cfg.specs) {
      payload[s.key] = _draft[s.key] ?? s.defaultValue;
    }

    setState(() => _saving = true);
    final res = await widget.service.setModuleConfig(widget.moduleName, payload);
    if (!mounted) return;
    setState(() => _saving = false);

    if (res.ok) {
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('配置已保存')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('保存失败：${res.msg}'),
          backgroundColor: AppColors.iconRed,
        ),
      );
    }
  }

  Future<void> _resetDefaults() async {
    final cfg = _config;
    if (cfg == null) return;
    final ok = await showConfirmDialog(
      context,
      title: '恢复默认值',
      message: '把本模块的所有配置项还原为模块声明的默认值。\n\n'
          '这只是改回界面上的取值，需要点「保存」才会真正写入。',
      danger: true,
    );
    if (ok != true || !mounted) return;
    setState(() {
      for (final s in cfg.specs) {
        _draft[s.key] = s.defaultValue;
      }
    });
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
                    child: ScreenAppBar(title: widget.moduleName),
                  ),
                  IconButton(
                    onPressed: _loading || _saving ? null : _resetDefaults,
                    icon: Icon(
                      Icons.restart_alt_rounded,
                      size: 20,
                      color: AppColors.textSecondary,
                    ),
                    tooltip: '恢复默认值',
                  ),
                ],
              ),
            ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, style: AppText.body13, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              _TextButton(label: '重试', onTap: _load),
            ],
          ),
        ),
      );
    }

    final cfg = _config!;
    if (cfg.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '这个模块没有可配置的选项。\n'
            '（模块需要提供 config.prop 才会出现配置项）',
            style: AppText.body13,
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        for (final s in cfg.specs) ...[
          _ConfigField(
            spec: s,
            value: _draft[s.key] ?? s.defaultValue,
            enabled: !_saving,
            onChanged: (v) => setState(() => _draft[s.key] = v),
          ),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 6),
        _SaveButton(
          enabled: !_saving && _dirty,
          saving: _saving,
          onTap: _save,
        ),
        const SizedBox(height: 12),
        Text(
          _dirty ? '有改动尚未保存' : '已是最新',
          style: AppText.desc12,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

/// 单个配置项，按类型渲染对应控件。
class _ConfigField extends StatelessWidget {
  const _ConfigField({
    required this.spec,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final ModuleConfigSpec spec;
  final String value;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  spec.label,
                  style: AppText.rowLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 12),
              _buildControl(),
            ],
          ),
          if (spec.desc.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(spec.desc, style: AppText.desc12),
          ],
        ],
      ),
    );
  }

  Widget _buildControl() {
    switch (spec.type) {
      case ModuleConfigType.toggle:
        return AppSwitch(
          value: value == '1' || value == 'true' || value == 'yes',
          onChanged: enabled ? (v) => onChanged(v ? '1' : '0') : null,
        );

      case ModuleConfigType.select:
        final items = spec.values.isEmpty ? [value] : spec.values;
        // 值不在候选里时（例如模块更新后改了可选值），补进去避免 DropdownButton 报错
        final safeValue = items.contains(value) ? value : items.first;
        return _Select(
          value: safeValue,
          items: items,
          enabled: enabled,
          onChanged: onChanged,
        );

      case ModuleConfigType.number:
      case ModuleConfigType.text:
      case ModuleConfigType.unknown:
        return SizedBox(
          width: 132,
          child: _InlineInput(
            value: value,
            numeric: spec.type == ModuleConfigType.number,
            enabled: enabled,
            onChanged: onChanged,
          ),
        );
    }
  }
}

class _Select extends StatelessWidget {
  const _Select({
    required this.value,
    required this.items,
    required this.enabled,
    required this.onChanged,
  });

  final String value;
  final List<String> items;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.divider),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isDense: true,
          dropdownColor: AppColors.surface,
          style: AppText.monoValue14,
          items: [
            for (final v in items)
              DropdownMenuItem<String>(value: v, child: Text(v)),
          ],
          onChanged: enabled ? (v) { if (v != null) onChanged(v); } : null,
        ),
      ),
    );
  }
}

class _InlineInput extends StatefulWidget {
  const _InlineInput({
    required this.value,
    required this.numeric,
    required this.enabled,
    required this.onChanged,
  });

  final String value;
  final bool numeric;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  State<_InlineInput> createState() => _InlineInputState();
}

class _InlineInputState extends State<_InlineInput> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(covariant _InlineInput old) {
    super.didUpdateWidget(old);
    // 外部值变了（如恢复默认、重新加载）才覆盖用户输入，避免打字时光标乱跳
    if (old.value != widget.value && widget.value != _ctrl.text) {
      _ctrl.text = widget.value;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      enabled: widget.enabled,
      keyboardType: widget.numeric ? TextInputType.number : TextInputType.text,
      textAlign: TextAlign.right,
      style: AppText.monoValue14,
      onChanged: widget.onChanged,
      decoration: InputDecoration(
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 8,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: AppColors.accent),
        ),
      ),
    );
  }
}

class _SaveButton extends StatelessWidget {
  const _SaveButton({
    required this.enabled,
    required this.saving,
    required this.onTap,
  });

  final bool enabled;
  final bool saving;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? AppColors.accent : AppColors.textInactive;
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              saving ? Icons.hourglass_empty : Icons.save_outlined,
              size: 18,
              color: color,
            ),
            const SizedBox(width: 6),
            Text(
              saving ? '保存中…' : '保存配置',
              style: AppText.rowLabel.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _TextButton extends StatelessWidget {
  const _TextButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.divider),
        ),
        child: Text(label, style: AppText.rowLabel),
      ),
    );
  }
}
