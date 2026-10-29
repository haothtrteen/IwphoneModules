import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
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
      title: Text(
          _isFirstTime
              ? AppStrings.t('webuiToken.titleSet')
              : AppStrings.t('webuiToken.titleChange'),
          style: AppText.cardTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppStrings.t('webuiToken.desc'),
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
                labelText: AppStrings.t('webuiToken.label'),
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
          child: Text(AppStrings.t('common.cancel'),
              style: AppText.rowLabel
                  .copyWith(color: AppColors.textSecondary)),
        ),
        TextButton(
          onPressed: _busy ? null : _submit,
          child: Text(
            _busy
                ? AppStrings.t('webuiToken.setting')
                : AppStrings.t('common.confirm'),
            style: AppText.rowLabel.copyWith(
              color: _busy ? AppColors.textInactive : AppColors.accent,
            ),
          ),
        ),
      ],
    );
  }
}
