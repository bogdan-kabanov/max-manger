import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../services/max_auth_service.dart';

enum _SmsStep { phone, code, twoFa, done }

class SmsAccountDialog extends StatefulWidget {
  const SmsAccountDialog({super.key});

  static Future<bool?> show(BuildContext context) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const SmsAccountDialog(),
    );
  }

  @override
  State<SmsAccountDialog> createState() => _SmsAccountDialogState();
}

class _SmsAccountDialogState extends State<SmsAccountDialog> {
  final _phoneController = TextEditingController();
  final _labelController = TextEditingController();
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();

  _SmsStep _step = _SmsStep.phone;
  bool _loading = false;
  String? _error;
  String? _phone;
  String? _hint;
  bool? _authAvailable;

  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    final available = await MaxAuthService.isAvailable();
    if (!mounted) return;
    setState(() => _authAvailable = available);
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _labelController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String _normalizePhone(String raw) {
    var phone = raw.trim().replaceAll(RegExp(r'[\s\-()]'), '');
    if (!phone.startsWith('+')) {
      if (phone.startsWith('8') && phone.length == 11) {
        phone = '+7${phone.substring(1)}';
      } else if (phone.startsWith('7') && phone.length == 11) {
        phone = '+$phone';
      } else if (RegExp(r'^\d{10,15}$').hasMatch(phone)) {
        phone = '+$phone';
      }
    }
    return phone;
  }

  bool _isValidPhone(String phone) {
    return RegExp(r'^\+\d{10,15}$').hasMatch(phone);
  }

  Future<void> _sendCode() async {
    final phone = _normalizePhone(_phoneController.text);
    if (!_isValidPhone(phone)) {
      setState(() => _error = 'Введите номер с кодом страны, например +998779522047 или +79991234567');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    final result = await MaxAuthService.sendCode(phone);
    if (!mounted) return;

    if (!result.ok) {
      setState(() {
        _loading = false;
        _error = result.error ?? 'Не удалось отправить код';
      });
      return;
    }

    setState(() {
      _loading = false;
      _phone = phone;
      _step = _SmsStep.code;
    });
  }

  Future<void> _verifyCode() async {
    final phone = _phone;
    if (phone == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    final result = await MaxAuthService.verifyCode(phone, _codeController.text.trim());
    if (!mounted) return;

    if (!result.ok) {
      setState(() {
        _loading = false;
        _error = result.error ?? 'Неверный код';
      });
      return;
    }

    if (result.requires2FA == true) {
      setState(() {
        _loading = false;
        _hint = result.hint;
        _step = _SmsStep.twoFa;
      });
      return;
    }

    await _finishLogin(result);
  }

  Future<void> _verify2FA() async {
    final phone = _phone;
    if (phone == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    final result = await MaxAuthService.verify2FA(phone, _passwordController.text);
    if (!mounted) return;

    if (!result.ok) {
      setState(() {
        _loading = false;
        _error = result.error ?? 'Неверный пароль 2FA';
      });
      return;
    }

    await _finishLogin(result);
  }

  Future<void> _finishLogin(MaxAuthResult result) async {
    final token = result.token;
    final phone = _phone ?? result.phone;
    if (token == null || phone == null) {
      setState(() {
        _loading = false;
        _error = 'Токен не получен';
      });
      return;
    }

    final label = _labelController.text.trim().isEmpty
        ? (result.profileName ?? phone)
        : _labelController.text.trim();

    await context.read<AppState>().addAccountFromSms(
          phone: phone,
          apiToken: token,
          label: label,
        );

    if (!mounted) return;
    setState(() {
      _loading = false;
      _step = _SmsStep.done;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('SMS через API (экспериментально)'),
      content: SizedBox(
        width: 420,
        child: _authAvailable == null
            ? const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
            : _authAvailable == false
                ? _buildSetupHelp()
                : _buildStepContent(),
      ),
      actions: _buildActions(),
    );
  }

  Widget _buildSetupHelp() {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Для SMS-входа нужен Node.js и зависимости auth-модуля.',
          style: TextStyle(fontSize: 13),
        ),
        SizedBox(height: 12),
        SelectableText(
          '1. Установите Node.js: https://nodejs.org\n'
          '2. В терминале:\n'
          '   cd tools/max_auth\n'
          '   npm install\n'
          '3. Перезапустите MAX Desktop',
          style: TextStyle(fontSize: 12, fontFamily: 'monospace'),
        ),
      ],
    );
  }

  Widget _buildStepContent() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_step == _SmsStep.phone) ...[
            const Text(
              'MAX часто блокирует SMS через неофициальный API (ошибка captcha) — '
              'даже из РФ. Для узбекского (+998) и других номеров надёжнее: '
              'зарегистрируйте номер в приложении MAX на телефоне → «Профиль + QR» здесь.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phoneController,
              decoration: const InputDecoration(
                labelText: 'Телефон',
                hintText: '+998779522047 или +79991234567',
              ),
              keyboardType: TextInputType.phone,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+\-\s()]'))],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _labelController,
              decoration: const InputDecoration(
                labelText: 'Название профиля (необязательно)',
                hintText: 'Рабочий, личный...',
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Captcha — защита MAX от ботов, не VPN. Если SMS не проходит, '
                'используйте «Профиль + QR» (официальный вход) или «Вход по токену».',
                style: TextStyle(fontSize: 11),
              ),
            ),
          ],
          if (_step == _SmsStep.code) ...[
            Text('Код отправлен на $_phone', style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            TextField(
              controller: _codeController,
              decoration: const InputDecoration(labelText: 'Код из SMS'),
              keyboardType: TextInputType.number,
              autofocus: true,
              maxLength: 6,
            ),
          ],
          if (_step == _SmsStep.twoFa) ...[
            const Text('На аккаунте включена двухфакторная защита', style: TextStyle(fontSize: 13)),
            if (_hint != null) ...[
              const SizedBox(height: 8),
              Text('Подсказка: $_hint', style: const TextStyle(fontSize: 12, color: Colors.white70)),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              decoration: const InputDecoration(labelText: 'Пароль 2FA'),
              obscureText: true,
              autofocus: true,
            ),
          ],
          if (_step == _SmsStep.done) ...[
            const Icon(Icons.check_circle_outline, color: Colors.green, size: 48),
            const SizedBox(height: 12),
            const Text(
              'Аккаунт добавлен. API-сессия сохранена.\n\n'
              'Откройте web.max.ru в центральной панели и отсканируйте QR с телефона, '
              'если сайт не войдёт автоматически.',
              style: TextStyle(fontSize: 13),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
          ],
          if (_loading) ...[
            const SizedBox(height: 16),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildActions() {
    if (_authAvailable != true) {
      return [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть')),
      ];
    }

    if (_step == _SmsStep.done) {
      return [
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Готово'),
        ),
      ];
    }

    return [
      TextButton(
        onPressed: _loading ? null : () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      if (_step == _SmsStep.phone)
        FilledButton(
          onPressed: _loading ? null : _sendCode,
          child: const Text('Отправить код'),
        ),
      if (_step == _SmsStep.code)
        FilledButton(
          onPressed: _loading ? null : _verifyCode,
          child: const Text('Подтвердить'),
        ),
      if (_step == _SmsStep.twoFa)
        FilledButton(
          onPressed: _loading ? null : _verify2FA,
          child: const Text('Войти'),
        ),
    ];
  }
}
