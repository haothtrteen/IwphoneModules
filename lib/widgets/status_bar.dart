import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 状态栏 —— 1:1 还原设计稿自绘状态栏
///
/// 高度 62，背景 #0D0D0F，左侧时间（左内边距 24），
/// 右侧信号 / WiFi / 电池图标组（右内边距 20，图标间距 6）。
class StatusBar extends StatefulWidget {
  const StatusBar({super.key});

  @override
  State<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<StatusBar> {
  Timer? _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _timeText {
    final h = _now.hour.toString().padLeft(2, '0');
    final m = _now.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 62,
      color: AppColors.bg,
      padding: const EdgeInsets.only(left: 24, right: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(_timeText, style: AppText.statusTime),
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SignalIcon(),
              SizedBox(width: 6),
              _WifiIcon(),
              SizedBox(width: 6),
              _BatteryIcon(),
            ],
          ),
        ],
      ),
    );
  }
}

/// 信号图标：4 根递增竖条（宽 2.25，高 4.5 / 7.5 / 10.5 / 12.75）
class _SignalIcon extends StatelessWidget {
  const _SignalIcon();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 18,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          _Bar(4.5),
          SizedBox(width: 1.5),
          _Bar(7.5),
          SizedBox(width: 1.5),
          _Bar(10.5),
          SizedBox(width: 1.5),
          _Bar(12.75),
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar(this.height);

  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(width: 2.25, height: height, color: Colors.white);
  }
}

/// WiFi 图标
class _WifiIcon extends StatelessWidget {
  const _WifiIcon();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 18,
      height: 18,
      child: Center(
        child: Icon(Icons.wifi, size: 15, color: Colors.white),
      ),
    );
  }
}

/// 电池图标：描边外壳 16.5×6 + 电量填充 11×3 + 正极凸点
class _BatteryIcon extends StatelessWidget {
  const _BatteryIcon();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 22,
      height: 18,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 16.5,
              height: 6,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 1),
                borderRadius: BorderRadius.circular(1.5),
              ),
              child: const Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(width: 9, height: 2.5, child: ColoredBox(color: Colors.white)),
              ),
            ),
            Container(
              width: 1.8,
              height: 3,
              margin: const EdgeInsets.only(left: 1),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
