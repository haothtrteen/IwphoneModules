import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
import '../services/app_prefs.dart';
import '../theme/app_theme.dart';

/// 首次启动引导。
///
/// 三页：这是什么 → 怎么开始 → 风险告知。
/// 讲完风险再让用户进主界面 —— 这个项目要拿 ADB 权限做系统级操作，
/// 一上来就进主界面、事后在设置里藏一段免责声明，是不负责任的。
///
/// 只展示一次，完成状态存在原生 SharedPreferences（`AppPrefs.onboardingDone`）。
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  static const _pageCount = 3;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_page >= _pageCount - 1) {
      _finish();
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _finish() => AppPrefs.instance.setOnboardingDone();

  @override
  Widget build(BuildContext context) {
    final last = _page == _pageCount - 1;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            // 顶部：跳过（最后一页不显示）
            SizedBox(
              height: 44,
              child: last
                  ? null
                  : Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _finish,
                        child: Text(
                          AppStrings.t('common.skip'),
                          style: AppText.desc12
                              .copyWith(color: AppColors.textSecondary),
                        ),
                      ),
                    ),
            ),
            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (i) => setState(() => _page = i),
                children: const [
                  _WelcomePage(),
                  _StepsPage(),
                  _RiskPage(),
                ],
              ),
            ),
            // 指示点
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _pageCount; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _page ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _page ? AppColors.accent : AppColors.divider,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: TextButton(
                  onPressed: _next,
                  style: TextButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    last ? AppStrings.t('onboarding.agree') : AppStrings.t('common.next'),
                    style: AppText.rowLabel.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 通用页骨架：图标 + 标题 + 内容。
class _PageShell extends StatelessWidget {
  const _PageShell({
    required this.icon,
    required this.title,
    required this.children,
  });

  final IconData icon;
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Container(
            width: 56,
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.accentDim,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, size: 28, color: AppColors.accent),
          ),
          const SizedBox(height: 20),
          Text(title, style: AppText.appTitle),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }
}

/// 一行：勾号 + 文案。
class _Bullet extends StatelessWidget {
  const _Bullet({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(Icons.check_circle, size: 15, color: AppColors.accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: AppText.body13.copyWith(height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一页：步骤条目（编号 + 标题 + 说明）。
class _Step extends StatelessWidget {
  const _Step({
    required this.index,
    required this.title,
    required this.desc,
  });

  final int index;
  final String title;
  final String desc;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: AppColors.divider),
            ),
            child: Text('$index',
                style: AppText.desc12.copyWith(color: AppColors.accent)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppText.rowLabel),
                const SizedBox(height: 4),
                Text(desc, style: AppText.desc12.copyWith(height: 1.45)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WelcomePage extends StatelessWidget {
  const _WelcomePage();

  @override
  Widget build(BuildContext context) {
    return _PageShell(
      icon: Icons.shield_moon_outlined,
      title: AppStrings.t('onboarding.welcomeTitle'),
      children: [
        Text(
          AppStrings.t('onboarding.welcomeDesc'),
          style: AppText.body13.copyWith(height: 1.5),
        ),
        const SizedBox(height: 20),
        _Bullet(text: AppStrings.t('onboarding.welcomePoint1')),
        _Bullet(text: AppStrings.t('onboarding.welcomePoint2')),
        _Bullet(text: AppStrings.t('onboarding.welcomePoint3')),
      ],
    );
  }
}

class _StepsPage extends StatelessWidget {
  const _StepsPage();

  @override
  Widget build(BuildContext context) {
    return _PageShell(
      icon: Icons.rocket_launch_outlined,
      title: AppStrings.t('onboarding.step2Title'),
      children: [
        Text(
          AppStrings.t('onboarding.step2Desc'),
          style: AppText.body13.copyWith(height: 1.5),
        ),
        const SizedBox(height: 18),
        _Step(
          index: 1,
          title: AppStrings.t('onboarding.stepPair'),
          desc: AppStrings.t('onboarding.stepPairDesc'),
        ),
        _Step(
          index: 2,
          title: AppStrings.t('onboarding.stepDeploy'),
          desc: AppStrings.t('onboarding.stepDeployDesc'),
        ),
        _Step(
          index: 3,
          title: AppStrings.t('onboarding.stepToken'),
          desc: AppStrings.t('onboarding.stepTokenDesc'),
        ),
      ],
    );
  }
}

class _RiskPage extends StatelessWidget {
  const _RiskPage();

  @override
  Widget build(BuildContext context) {
    return _PageShell(
      icon: Icons.warning_amber_rounded,
      title: AppStrings.t('onboarding.step3Title'),
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: AppColors.iconOrange.withValues(alpha: 0.45),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 16, color: AppColors.iconOrange),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  AppStrings.t('onboarding.step3Desc'),
                  style: AppText.body13.copyWith(height: 1.5),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
