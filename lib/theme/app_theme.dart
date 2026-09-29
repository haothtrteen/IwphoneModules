import 'package:flutter/material.dart';

/// 设计令牌 —— 严格对应 .ardot 设计稿取值
///
/// 颜色均为设计稿中拾取的精确值：
/// - 背景        #0D0D0F
/// - 卡片表面    #1A1A1E
/// - 底部导航    #16161A
/// - 强调绿      #00C853
/// - 分隔线      #2A2A2E
abstract final class AppColors {
  AppColors._();

  /// 页面背景（rgb 0.051, 0.051, 0.059）
  static const Color bg = Color(0xFF0D0D0F);

  /// 卡片表面（rgb 0.102, 0.102, 0.118）
  static const Color surface = Color(0xFF1A1A1E);

  /// 底部导航栏背景（rgb 0.086, 0.086, 0.102）
  static const Color navBar = Color(0xFF16161A);

  /// 强调绿（rgb 0, 0.784, 0.325）
  static const Color accent = Color(0xFF00C853);

  /// 强调绿 15% 透明度（徽章 / 筛选选中态底色）
  static const Color accentDim = Color(0x2600C853);

  static const Color textPrimary = Color(0xFFFFFFFF);

  /// 次级文字（rgb 0.627, 0.627, 0.659）
  static const Color textSecondary = Color(0xFFA0A0A8);

  /// 未激活文字 / 导航未选中（rgb 0.376, 0.376, 0.408）
  static const Color textInactive = Color(0xFF606068);

  /// 页脚副标题（rgb 0.271, 0.271, 0.290）
  static const Color textFaint = Color(0xFF45454A);

  /// 卡片内分隔线（rgb 0.165, 0.165, 0.180）
  static const Color divider = Color(0xFF2A2A2E);

  /// 开关关闭态轨道（rgb 0.227, 0.227, 0.243）
  static const Color switchTrackOff = Color(0xFF3A3A3E);

  /// 开关关闭态滑块（rgb 0.502, 0.502, 0.533）
  static const Color switchKnobOff = Color(0xFF808088);

  // ---- 模块 / 应用图标色（取自设计稿） ----
  static const Color iconPurple = Color(0xFF7C4DFF); // Adreno GPU 驱动
  static const Color iconGreen = Color(0xFF00C853); // 音频增强 / 终端模拟器
  static const Color iconOrange = Color(0xFFFFB300); // 字体管理器 / 系统调优
  static const Color iconRed = Color(0xFFFF5252); // YouTube ReVanced
  static const Color iconBlue = Color(0xFF2196F3); // 系统调优图标 / Titanium
  static const Color iconDeepOrange = Color(0xFFFF9800); // Tasker
}

/// 文字样式 —— 字号 / 字重严格对应设计稿
abstract final class AppText {
  AppText._();

  static const String inter = 'Inter';
  static const String mono = 'JetBrains Mono';

  /// 页面大标题：22 / Bold / 白
  static const TextStyle appTitle = TextStyle(
    fontFamily: inter,
    fontSize: 22,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
    height: 1.0,
  );

  /// 卡片标题（Shell 状态）：16 / SemiBold / 白
  static const TextStyle cardTitle = TextStyle(
    fontFamily: inter,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
    height: 1.0,
  );

  /// 模块名 / 应用名：15 / Medium / 白
  static const TextStyle itemName = TextStyle(
    fontFamily: inter,
    fontSize: 15,
    fontWeight: FontWeight.w500,
    color: AppColors.textPrimary,
    height: 1.0,
  );

  /// 设置行标签：15 / Regular / 白
  static const TextStyle rowLabel = TextStyle(
    fontFamily: inter,
    fontSize: 15,
    fontWeight: FontWeight.w400,
    color: AppColors.textPrimary,
    height: 1.0,
  );

  /// 常规说明文字：13 / Regular / 次级灰
  static const TextStyle body13 = TextStyle(
    fontFamily: inter,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
    height: 1.0,
  );

  /// 等宽数值（信息行右侧值）：13 / Medium / JetBrains Mono / 白
  static const TextStyle mono13 = TextStyle(
    fontFamily: mono,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    color: AppColors.textPrimary,
    height: 1.0,
  );

  /// 统计卡片标签：12 / Regular / 次级灰
  static const TextStyle statLabel = TextStyle(
    fontFamily: inter,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
    height: 1.0,
  );

  /// 统计卡片数值：28 / Bold
  static const TextStyle statValue = TextStyle(
    fontFamily: inter,
    fontSize: 28,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
    height: 1.0,
  );

  /// 徽章 / 筛选选中：12-13 / Medium / 强调绿
  static const TextStyle badge = TextStyle(
    fontFamily: inter,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: AppColors.accent,
    height: 1.0,
  );

  static const TextStyle filterActive = TextStyle(
    fontFamily: inter,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    color: AppColors.accent,
    height: 1.0,
  );

  static const TextStyle filterInactive = TextStyle(
    fontFamily: inter,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    color: AppColors.textInactive,
    height: 1.0,
  );

  /// 分组标题（设置）：13 / Medium / 次级灰
  static const TextStyle sectionTitle = TextStyle(
    fontFamily: inter,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    color: AppColors.textSecondary,
    height: 1.0,
  );

  /// 分组标题（系统信息）：14 / Medium / 次级灰
  static const TextStyle infoTitle = TextStyle(
    fontFamily: inter,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    color: AppColors.textSecondary,
    height: 1.0,
  );

  /// 描述文字：12 / Regular / 次级灰
  static const TextStyle desc12 = TextStyle(
    fontFamily: inter,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
    height: 1.0,
  );

  /// 模块版本号：11 / Medium / JetBrains Mono（颜色随模块变化）
  static const TextStyle monoVersion11 = TextStyle(
    fontFamily: mono,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    color: AppColors.accent,
    height: 1.0,
  );

  /// 设置行右侧值：14 / Regular / 次级灰
  static const TextStyle value14 = TextStyle(
    fontFamily: inter,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: AppColors.textSecondary,
    height: 1.0,
  );

  /// 设置行右侧等宽值（版本号 / 源代码）：14 / Medium / 次级灰
  static const TextStyle monoValue14 = TextStyle(
    fontFamily: mono,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    color: AppColors.textSecondary,
    height: 1.0,
  );

  /// 底部导航标签：10 / Medium
  static const TextStyle navLabel = TextStyle(
    fontFamily: inter,
    fontSize: 10,
    fontWeight: FontWeight.w500,
    color: AppColors.textInactive,
    height: 1.0,
  );

  /// 状态栏时间：14 / Medium / 白
  static const TextStyle statusTime = TextStyle(
    fontFamily: inter,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    color: AppColors.textPrimary,
    height: 1.0,
  );

  /// 页脚：12 / Regular / 未激活灰
  static const TextStyle footer = TextStyle(
    fontFamily: inter,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: AppColors.textInactive,
    height: 1.0,
  );

  /// 页脚副标题：11 / Regular / 深灰
  static const TextStyle footerSub = TextStyle(
    fontFamily: inter,
    fontSize: 11,
    fontWeight: FontWeight.w400,
    color: AppColors.textFaint,
    height: 1.0,
  );
}
