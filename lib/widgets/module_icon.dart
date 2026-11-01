import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/iwphone_service.dart';
import '../theme/app_theme.dart';

/// 模块图标语义表。
///
/// 模块在 `iwphone.prop` 里写 `icon="battery"` 这样的**语义名**，客户端在这里
/// 查表换成具体图标。用 IconData 而不是图片的好处：
///   - 跟随浅色/深色主题取色，不用为两套主题各出一张图；
///   - 不增加模块包体积，老模块也不用重新打包；
///   - 任意尺寸都清晰，不需要 @2x/@3x。
///
/// ⚠️ 键名一旦发布就**不要再改**，改名等于让已发布的模块失去图标。
/// 新增键是安全的。
abstract final class ModuleIcons {
  ModuleIcons._();

  /// 语义名 → 图标（全部按字母序排列，便于查找）。
  static const Map<String, IconData> table = {
    'app': Icons.apps_rounded,
    'battery': Icons.battery_saver_rounded,
    'cloud': Icons.cloud_rounded,
    'debug': Icons.bug_report_rounded,
    'display': Icons.brightness_6_rounded,
    'dns': Icons.dns_rounded,
    'input': Icons.keyboard_rounded,
    'language': Icons.language_rounded,
    'memory': Icons.memory_rounded,
    'module': Icons.extension_rounded,
    'motion': Icons.animation_rounded,
    'network': Icons.wifi_rounded,
    'performance': Icons.speed_rounded,
    'power': Icons.power_settings_new_rounded,
    'privacy': Icons.lock_rounded,
    'security': Icons.shield_rounded,
    'sound': Icons.volume_up_rounded,
    'storage': Icons.folder_rounded,
    'system': Icons.settings_rounded,
    'time': Icons.schedule_rounded,
    'visual': Icons.blur_on_rounded,
  };

  /// 查表。未知 / 空值返回 null，由调用方回退。
  static IconData? resolve(String key) {
    final k = key.trim().toLowerCase();
    if (k.isEmpty) return null;
    return table[k];
  }

  /// 全部可用语义名（写文档、做提示时用）。
  static List<String> get keys => table.keys.toList(growable: false);
}

/// 模块图标。
///
/// 取图优先级：
///   1. 模块自带的 `icon.png`（体积上限 256 KB，由框架 `/api/module/<名>/icon` 提供）
///   2. `iwphone.prop` 里的 `icon="语义名"`
///   3. 调用方传进来的兜底图标（按模块名哈希来的那个，保证老模块行为不变）
///
/// `icon.png` 只在这个模块第一次出现在屏幕上时拉一次，成功后缓存在内存里；
/// 失败不缓存，下次列表重建会重试。
class ModuleIconView extends StatefulWidget {
  const ModuleIconView({
    super.key,
    required this.moduleId,
    required this.iconKey,
    required this.hasIcon,
    required this.fallbackIcon,
    required this.color,
    this.size = 40,
    this.glyphSize = 22,
  });

  /// 模块目录名，同时作为自定义图标的缓存键。
  final String moduleId;

  /// `iwphone.prop` 的 `icon=`（语义名）。
  final String iconKey;

  /// 模块是否有 `icon.png`。
  final bool hasIcon;

  /// 既没自定义图、语义名也查不到时用。
  final IconData fallbackIcon;

  /// 没有自定义图时的底色（当前是按模块名哈希出来的色）。
  final Color color;

  final double size;
  final double glyphSize;

  @override
  State<ModuleIconView> createState() => _ModuleIconViewState();
}

class _ModuleIconViewState extends State<ModuleIconView> {
  /// 模块 id → PNG 字节。只存成功结果。
  static final Map<String, Uint8List> _cache = {};

  Uint8List? _bytes;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(ModuleIconView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.moduleId != widget.moduleId ||
        oldWidget.hasIcon != widget.hasIcon) {
      _sync();
    }
  }

  void _sync() {
    _bytes = _cache[widget.moduleId];
    if (widget.hasIcon && _bytes == null) {
      _load();
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    final bytes = await IwphoneService.instance.moduleIconBytes(widget.moduleId);
    _loading = false;
    if (!mounted) return;
    if (bytes == null) return; // 不缓存失败，下次重建再试
    _cache[widget.moduleId] = bytes;
    setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null) {
      return Container(
        width: widget.size,
        height: widget.size,
        color: AppColors.divider,
        padding: EdgeInsets.all(widget.size * 0.1),
        child: Image.memory(
          bytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
          // 图标文件损坏 / 不是合法 PNG 时不能红屏，退回语义图标
          errorBuilder: (_, __, ___) => _glyph(color: widget.color),
        ),
      );
    }
    return Container(
      width: widget.size,
      height: widget.size,
      color: widget.color,
      child: _glyph(),
    );
  }

  Widget _glyph({Color? color}) {
    final icon = ModuleIcons.resolve(widget.iconKey) ?? widget.fallbackIcon;
    return Icon(icon, size: widget.glyphSize, color: color ?? Colors.white);
  }
}
