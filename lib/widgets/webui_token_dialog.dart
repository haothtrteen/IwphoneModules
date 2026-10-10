import 'package:flutter/material.dart';

import '../services/webui_token.dart';
import '../theme/app_theme.dart';

/// 设置 / 修改 WebUI 访问密钥的对话框。
///
/// APatch 式的做法：密钥由**用户自己想**，而不是随机生成 ——
/// 好处是用户能拿它直接在浏览器里打开 WebUI，也省掉了「App 经 adb 取随机 token」
/// 那条链路。代价是密钥强度取决于用户，所以这里强制至少 8 位。
///
/// 返回 true 表示设置成功。
Future<bool> showWebuiTokenDialog(
  BuildContext context, {
  String? current,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => _TokenDialog(current: current),
  );
  return ok == true;
}

class _TokenDialog extends StatefulWidget {
  const _TokenDialog({this.current});

  /// 已有密钥（修改时预填）。为 null / 空表示首次设置。
  final String? current;

  @override
  State<_TokenDialog> createState() => _TokenDialogState();
}

class _TokenDialogState extends State<_TokenDialog> {
  late final TextEditingController _ctrl;
  String? _error;
  bool _obscure = true;
  bool _busy = false;

  bool get _isFirstTime =>
      widget.current == null || widget.current!.isEmpty;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.current ?? '');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final err = WebuiTokenManager.validate(_ctrl.text);
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await WebuiTokenManager.instance.set(_ctrl.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _error = r.msg);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(_isFirstTime ? '设置访问密钥' : '修改访问密钥',
          style: AppText.cardTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '框架的 WebUI 上挂着 shell 权限接口，而它监听在本机回环口 —— '
              '同设备上任何应用都能访问，所以必须用一把密钥挡住它们。\n\n'
              '密钥由你自己想（至少 8 位）。设好之后：\n'
              '· App 会自动带着它访问框架\n'
              '· 想在浏览器里看 WebUI，用它拼地址即可\n\n'
              '密钥只存在你自己的手机里（框架侧文件权限 600）。',
              style: AppText.desc12,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _ctrl,
              obscureText: _obscure,
              enabled: !_busy,
              autofocus: _isFirstTime,
              style: AppText.value14,
              decoration: InputDecoration(
                labelText: '访问密钥',
                labelStyle: AppText.desc12,
                errorText: _error,
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure ? Icons.visibility_off : Icons.visibility,
                    size: 18,
                    color: AppColors.textSecondary,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text('取消',
              style: AppText.rowLabel
                  .copyWith(color: AppColors.textSecondary)),
        ),
        TextButton(
          onPressed: _busy ? null : _submit,
          child: Text(
            _busy ? '设置中…' : '确定',
            style: AppText.rowLabel.copyWith(
              color: _busy ? AppColors.textInactive : AppColors.accent,
            ),
          ),
        ),
      ],
    );
  }
}
