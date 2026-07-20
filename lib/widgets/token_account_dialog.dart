import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../services/max_auth_service.dart';
import '../services/token_file_parser.dart';

class TokenAccountDialog extends StatefulWidget {
  const TokenAccountDialog({super.key});

  static Future<bool?> show(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (context) => const TokenAccountDialog(),
    );
  }

  @override
  State<TokenAccountDialog> createState() => _TokenAccountDialogState();
}

class _TokenAccountDialogState extends State<TokenAccountDialog> {
  final _phoneController = TextEditingController();
  final _labelController = TextEditingController();
  final _tokenController = TextEditingController();
  final _proxyController = TextEditingController();

  bool _loading = false;
  String? _error;
  bool _canAddWithoutVerify = false;
  int? _parsedViewerId;
  String? _parsedDeviceId;

  @override
  void dispose() {
    _phoneController.dispose();
    _labelController.dispose();
    _tokenController.dispose();
    _proxyController.dispose();
    super.dispose();
  }

  String? get _proxy {
    final value = _proxyController.text.trim();
    return value.isEmpty ? null : value;
  }

  void _reparseTokenField() {
    final parsed = TokenFileParser.parse(_tokenController.text);
    _parsedViewerId = parsed.viewerId;
    _parsedDeviceId = parsed.deviceId;
  }

  Future<void> _addAccount({
    required String token,
    String? phone,
    String? label,
    int? viewerId,
  }) async {
    await context.read<AppState>().addAccountFromToken(
          apiToken: token,
          phone: phone,
          label: label,
          viewerId: viewerId ?? _parsedViewerId,
          proxyServer: _proxy,
          deviceId: _parsedDeviceId,
        );
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  Future<void> _submit({bool skipVerify = false}) async {
    final parsed = TokenFileParser.parse(_tokenController.text);
    _parsedViewerId = parsed.viewerId;
    _parsedDeviceId = parsed.deviceId;

    final token = parsed.token ?? MaxAuthService.normalizeTokenInput(_tokenController.text);
    final formatError = parsed.error ?? MaxAuthService.validateTokenFormat(token);
    if (formatError != null || token.isEmpty) {
      setState(() {
        _error = formatError ?? 'Не удалось распознать токен';
        _canAddWithoutVerify = false;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _canAddWithoutVerify = false;
    });

    if (!skipVerify) {
      final result = await MaxAuthService.verifyToken(token, proxy: _proxy);
      if (!mounted) return;

      if (result.ok) {
        final phone = _phoneController.text.trim().isNotEmpty
            ? _phoneController.text.trim()
            : result.profilePhone ?? result.phone;
        final label = _labelController.text.trim().isNotEmpty
            ? _labelController.text.trim()
            : result.profileName ?? phone ?? 'Аккаунт';

        setState(() => _loading = false);
        await _addAccount(
          token: token,
          phone: phone,
          label: label,
          viewerId: result.profileId ?? _parsedViewerId,
        );
        return;
      }

      if (MaxAuthService.isNetworkError(result.error)) {
        setState(() {
          _loading = false;
          _error = result.error;
          _canAddWithoutVerify = true;
        });
        return;
      }

      setState(() {
        _loading = false;
        _error = result.error ??
            'MAX не принял токен. Нужен свежий токен An_… из web.max.ru';
      });
      return;
    }

    final phone = _phoneController.text.trim().isNotEmpty ? _phoneController.text.trim() : null;
    final label = _labelController.text.trim().isNotEmpty
        ? _labelController.text.trim()
        : phone ?? 'Аккаунт';

    setState(() => _loading = false);
    await _addAccount(token: token, phone: phone, label: label, viewerId: _parsedViewerId);
  }

  @override
  Widget build(BuildContext context) {
    final previewParsed = TokenFileParser.parse(_tokenController.text);
    final previewToken = previewParsed.token ?? '';

    return AlertDialog(
      title: const Text('Вход по токену'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Вставьте токен An_… или весь скрипт с localStorage.setItem(\'__oneme_auth\', …).',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              const Text(
                '1. Откройте web.max.ru → войдите по QR\n'
                '2. F12 → Console\n'
                '3. Скопируйте токен или весь sessionStorage/localStorage скрипт\n'
                '4. Вставьте сюда. Токен длинный и начинается с An_.',
                style: TextStyle(fontSize: 12, height: 1.45),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _tokenController,
                decoration: const InputDecoration(
                  labelText: 'Токен / скрипт сессии',
                  hintText: 'An_Sx6HQ9HDi… или localStorage.setItem…',
                ),
                maxLines: 6,
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 11),
                onChanged: (_) {
                  _reparseTokenField();
                  setState(() => _error = null);
                },
              ),
              const SizedBox(height: 4),
              Text(
                'Распознано: ${MaxAuthService.tokenPreview(previewToken)}'
                '${previewParsed.viewerId != null ? ' · viewerId ${previewParsed.viewerId}' : ''}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11),
              ),
              const SizedBox(height: 4),
              Text(
                'В поле длинный токен может выглядеть «обрезанным» (виден кусок …LLM86… посередине) — это нормально, если сверху «Распознано» начинается с An_ и длина ~700.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _proxyController,
                decoration: const InputDecoration(
                  labelText: 'Прокси SOCKS5 / HTTP (обязательно, если не хотите светить IP)',
                  hintText: 'socks5://user:pass@host:port',
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Трафик проверки токена, API (матка/дочерние) и браузера пойдёт через этот прокси.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _phoneController,
                decoration: const InputDecoration(
                  labelText: 'Телефон (необязательно)',
                  hintText: '+998779522047',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _labelController,
                decoration: const InputDecoration(
                  labelText: 'Название профиля (необязательно)',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
                ),
              ],
              if (_loading) ...[
                const SizedBox(height: 16),
                const Center(child: CircularProgressIndicator()),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        if (_canAddWithoutVerify)
          FilledButton(
            onPressed: _loading ? null : () => _submit(skipVerify: true),
            child: const Text('Добавить без проверки'),
          ),
        FilledButton(
          onPressed: _loading ? null : () => _submit(),
          child: Text(_canAddWithoutVerify ? 'Повторить' : 'Добавить'),
        ),
      ],
    );
  }
}
