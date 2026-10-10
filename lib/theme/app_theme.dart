import 'package:flutter/material.dart';

/// 一套主题所需的全部颜色。
///
/// 之所以引入这层：原先 [AppColors] 是一堆 `static const`，只能表达一种主题。
/// 要支持「浅色 / 深色 / 跟随系统」，颜色必须在运行时可变。
/// 现在的结构是「调色板 + getter」—— 调用方仍然照旧写 `AppColors.bg`，
/// 但取到的是**当前主题**的值，因此 300+ 处引用一处都不用改。
@immutable
class AppPalette {
  const AppPalette({
    required this.bg,
    required this.surface,
    required this.navBar,
    required this.accent,
    required this.accentDim,
    required this.textPrimary,
    required this.textSecondary,
    required this.textInactive,
    required this.textFaint,
    required this.divider,
    required this.switchTrackOff,
    required this.switchKnobOff,
    required this.iconPurple,
    required this.iconGreen,
    required this.iconOrange,
    required this.iconRed,
    required this.iconBlue,
    required this.iconDeepOrange,
  });

  final Color bg;
  final Color surface;
  final Color navBar;
  final Color accent;
  final Color accentDim;
  final Color textPrimary;
  final Color textSecondary;
  final Color textInactive;
  final Color textFaint;
  final Color divider;
  final Color switchTrackOff;
  final Color switchKnobOff;
  final Color iconPurple;
  final Color iconGreen;
  final Color iconOrange;
  final Color iconRed;
  final Color iconBlue;
  final Color iconDeepOrange;
}

/// 设计令牌 —— 深色取值严格对应 .ardot 设计稿，浅色为等比适配
///
/// - 深色 背景 #0D0D0F / 卡片 #1A1A1E / 底栏 #16161A / 强调绿 #00C853
/// - 浅色 背景 #F4F4F6 / 卡片 #FFFFFF / 强调绿加深到 #00A344（保证白底对比度）
abstract final class AppColors {
  AppColors._();

  /// 深色（设计稿原值）
  static const AppPalette dark = AppPalette(
    bg: Color(0xFF0D0D0F),
    surface: Color(0xFF1A1A1E),
    navBar: Color(0xFF16161A),
    accent: Color(0xFF00C853),
    accentDim: Color(0x2600C853),
    textPrimary: Color(0xFFFFFFFF),
    textSecondary: Color(0xFFA0A0A8),
    textInactive: Color(0xFF606068),
    textFaint: Color(0xFF45454A),
    divider: Color(0xFF2A2A2E),
    switchTrackOff: Color(0xFF3A3A3E),
    switchKnobOff: Color(0xFF808088),
    iconPurple: Color(0xFF7C4DFF),
    iconGreen: Color(0xFF00C853),
    iconOrange: Color(0xFFFFB300),
    iconRed: Color(0xFFFF5252),
    iconBlue: Color(0xFF2196F3),
    iconDeepOrange: Color(0xFFFF9800),
  );

  /// 浅色
  ///
  /// 不是把深色反过来：底栏与卡片同为白，靠 [divider] 与页面灰底拉开层次；
  /// 强调色整体压深一档，避免亮色背景上「糊掉」。
  static const AppPalette light = AppPalette(
    bg: Color(0xFFF4F4F6),
    surface: Color(0xFFFFFFFF),
    navBar: Color(0xFFFFFFFF),
    accent: Color(0xFF00A344),
    accentDim: Color(0x1F00A344),
    textPrimary: Color(0xFF1A1A1E),
    textSecondary: Color(0xFF5C5C66),
    textInactive: Color(0xFF8A8A93),
    textFaint: Color(0xFFB4B4BC),
    divider: Color(0xFFE4E4EA),
    switchTrackOff: Color(0xFFD6D6DC),
    switchKnobOff: Color(0xFFFFFFFF),
    iconPurple: Color(0xFF6A3FE0),
    iconGreen: Color(0xFF00A344),
    iconOrange: Color(0xFFD98A00),
    iconRed: Color(0xFFE03B3B),
    iconBlue: Color(0xFF1B7FE0),
    iconDeepOrange: Color(0xFFE07A00),
  );

  static AppPalette _palette = dark;

  /// 当前生效的调色板。
  static AppPalette get palette => _palette;

  /// 由根组件在主题变化时调用（见 `ShellManagerApp`）。
  static void applyBrightness(Brightness brightness) {
    _palette = brightness == Brightness.dark ? dark : light;
  }

  static Color get bg => _palette.bg;
  static Color get surface => _palette.surface;
  static Color get navBar => _palette.navBar;
  static Color get accent => _palette.accent;
  static Color get accentDim => _palette.accentDim;
  static Color get textPrimary => _palette.textPrimary;
  static Color get textSecondary => _palette.textSecondary;
  static Color get textInactive => _palette.textInactive;
  static Color get textFaint => _palette.textFaint;
  static Color get divider => _palette.divider;
  static Color get switchTrackOff => _palette.switchTrackOff;
  static Color get switchKnobOff => _palette.switchKnobOff;
  static Color get iconPurple => _palette.iconPurple;
  static Color get iconGreen => _palette.iconGreen;
  static Color get iconOrange => _palette.iconOrange;
  static Color get iconRed => _palette.iconRed;
  static Color get iconBlue => _palette.iconBlue;
  static Color get iconDeepOrange => _palette.iconDeepOrange;
}

/// 文字样式 —— 字号 / 字重严格对应设计稿
///
/// 与 [AppColors] 同理：这些样式引用主题色，因此必须是 getter 而非 const
/// （const 会把深色值烘进编译期，切主题时文字颜色不会跟着变）。
abstract final class AppText {
  AppText._();

  static const String inter = 'Inter';
  static const String mono = 'JetBrains Mono';

  /// 页面大标题：22 / Bold
  static TextStyle get appTitle => TextStyle(
        fontFamily: inter,
        fontSize: 22,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
        height: 1.0,
      );

  /// 卡片标题（Shell 状态）：16 / SemiBold
  static TextStyle get cardTitle => TextStyle(
        fontFamily: inter,
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
        height: 1.0,
      );

  /// 模块名 / 应用名：15 / Medium
  static TextStyle get itemName => TextStyle(
        fontFamily: inter,
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: AppColors.textPrimary,
        height: 1.0,
      );

  /// 设置行标签：15 / Regular
  static TextStyle get rowLabel => TextStyle(
        fontFamily: inter,
        fontSize: 15,
        fontWeight: FontWeight.w400,
        color: AppColors.textPrimary,
        height: 1.0,
      );

  /// 常规说明文字：13 / Regular / 次级
  static TextStyle get body13 => TextStyle(
        fontFamily: inter,
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: AppColors.textSecondary,
        height: 1.0,
      );

  /// 等宽数值（信息行右侧值）：13 / Medium / JetBrains Mono
  static TextStyle get mono13 => TextStyle(
        fontFamily: mono,
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: AppColors.textPrimary,
        height: 1.0,
      );

  /// 统计卡片标签：12 / Regular / 次级
  static TextStyle get statLabel => TextStyle(
        fontFamily: inter,
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: AppColors.textSecondary,
        height: 1.0,
      );

  /// 统计卡片数值：28 / Bold
  static TextStyle get statValue => TextStyle(
        fontFamily: inter,
        fontSize: 28,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
        height: 1.0,
      );

  /// 徽章 / 筛选选中：12 / Medium / 强调色
  static TextStyle get badge => TextStyle(
        fontFamily: inter,
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: AppColors.accent,
        height: 1.0,
      );

  static TextStyle get filterActive => TextStyle(
        fontFamily: inter,
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: AppColors.accent,
        height: 1.0,
      );

  static TextStyle get filterInactive => TextStyle(
        fontFamily: inter,
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: AppColors.textInactive,
        height: 1.0,
      );

  /// 分组标题（设置）：13 / Medium / 次级
  static TextStyle get sectionTitle => TextStyle(
        fontFamily: inter,
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: AppColors.textSecondary,
        height: 1.0,
      );

  /// 分组标题（系统信息）：14 / Medium / 次级
  static TextStyle get infoTitle => TextStyle(
        fontFamily: inter,
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: AppColors.textSecondary,
        height: 1.0,
      );

  /// 描述文字：12 / Regular / 次级
  static TextStyle get desc12 => TextStyle(
        fontFamily: inter,
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: AppColors.textSecondary,
        height: 1.0,
      );

  /// 模块版本号：11 / Medium / JetBrains Mono（颜色随模块变化）
  static TextStyle get monoVersion11 => TextStyle(
        fontFamily: mono,
        fontSize: 11,
        fontWeight: FontWeight.w500,
        color: AppColors.accent,
        height: 1.0,
      );

  /// 设置行右侧值：14 / Regular / 次级
  static TextStyle get value14 => TextStyle(
        fontFamily: inter,
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: AppColors.textSecondary,
        height: 1.0,
      );

  /// 设置行右侧等宽值（版本号 / 源代码）：14 / Medium / 次级
  static TextStyle get monoValue14 => TextStyle(
        fontFamily: mono,
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: AppColors.textSecondary,
        height: 1.0,
      );

  /// 底部导航标签：10 / Medium
  static TextStyle get navLabel => TextStyle(
        fontFamily: inter,
        fontSize: 10,
        fontWeight: FontWeight.w500,
        color: AppColors.textInactive,
        height: 1.0,
      );

  /// 状态栏时间：14 / Medium
  static TextStyle get statusTime => TextStyle(
        fontFamily: inter,
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: AppColors.textPrimary,
        height: 1.0,
      );

  /// 页脚：12 / Regular / 未激活
  static TextStyle get footer => TextStyle(
        fontFamily: inter,
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: AppColors.textInactive,
        height: 1.0,
      );

  /// 页脚副标题：11 / Regular / 深灰
  static TextStyle get footerSub => TextStyle(
        fontFamily: inter,
        fontSize: 11,
        fontWeight: FontWeight.w400,
        color: AppColors.textFaint,
        height: 1.0,
      );
}
