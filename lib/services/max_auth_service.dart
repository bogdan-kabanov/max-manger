import 'dart:convert';
import 'dart:io';

import 'node_runtime.dart';

class MaxAuthResult {
  MaxAuthResult({
    required this.ok,
    this.error,
    this.smsSent,
    this.requires2FA,
    this.hint,
    this.token,
    this.phone,
    this.profileName,
    this.profilePhone,
    this.profileId,
  });

  final bool ok;
  final String? error;
  final bool? smsSent;
  final bool? requires2FA;
  final String? hint;
  final String? token;
  final String? phone;
  final String? profileName;
  final String? profilePhone;
  final int? profileId;

  factory MaxAuthResult.fromJson(Map<String, dynamic> json) {
    final profile = json['profile'] as Map<String, dynamic>?;
    return MaxAuthResult(
      ok: json['ok'] == true,
      error: _asString(json['error']),
      smsSent: json['smsSent'] as bool?,
      requires2FA: json['requires2FA'] as bool?,
      hint: _asString(json['hint']),
      token: _asString(json['token']),
      phone: _asString(json['phone']),
      profileName: _asString(profile?['name']),
      profilePhone: _asString(profile?['phone']),
      profileId: _asInt(profile?['id']),
    );
  }
}

int? _asInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString());
}

String? _asString(dynamic value) {
  if (value == null) return null;
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  return value.toString();
}

class MaxAuthService {
  static Future<bool> isAvailable() => NodeRuntime.isAvailable();

  static Future<MaxAuthResult> _run(String command, Map<String, dynamic> args) async {
    final node = await NodeRuntime.findNodeExecutable();
    if (node == null) {
      return MaxAuthResult(
        ok: false,
        error: 'Node.js не найден. Переустановите приложение или поставьте Node с https://nodejs.org',
      );
    }

    final cli = await NodeRuntime.findCliPath();
    if (cli == null) {
      return MaxAuthResult(
        ok: false,
        error: 'Не найден tools/max_auth/cli.mjs. Переустановите приложение.',
      );
    }

    final authDir = File(cli).parent.path;
    final nodeModules = Directory('$authDir${Platform.pathSeparator}node_modules');
    if (!nodeModules.existsSync()) {
      return MaxAuthResult(
        ok: false,
        error: 'Не найдены зависимости CLI. Переустановите приложение.',
      );
    }

    final result = await Process.run(
      node,
      [cli, command, jsonEncode(args)],
      workingDirectory: authDir,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
      environment: {
        ...Platform.environment,
        'NODE_NO_WARNINGS': '1',
        'PYTHONIOENCODING': 'utf-8',
      },
    );

    final stdout = _decodeProcessOutput(result.stdout).trim();
    final stderr = _decodeProcessOutput(result.stderr).trim();

    Map<String, dynamic>? json;
    // Prefer a real command result ({ok: ...}) over progress/debug JSON lines.
    final lines = [...stdout.split('\n'), ...stderr.split('\n')];
    for (final line in lines.reversed) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('{')) continue;
      try {
        final parsed = jsonDecode(trimmed);
        if (parsed is! Map) continue;
        final map = Map<String, dynamic>.from(parsed);
        if (map['type'] == 'progress') continue;
        if (!map.containsKey('ok')) continue;
        json = map;
        break;
      } catch (_) {}
    }

    if (json != null) {
      final parsed = MaxAuthResult.fromJson(json);
      return MaxAuthResult(
        ok: parsed.ok,
        error: parsed.error != null
            ? mapError(_fixMojibake(parsed.error!))
            : (parsed.ok ? null : mapError(null)),
        smsSent: parsed.smsSent,
        requires2FA: parsed.requires2FA,
        hint: parsed.hint != null ? _fixMojibake(parsed.hint!) : null,
        token: parsed.token,
        phone: parsed.phone,
        profileName: parsed.profileName,
        profilePhone: parsed.profilePhone,
        profileId: parsed.profileId,
      );
    }

    final fallback = stderr.isNotEmpty ? stderr : stdout;
    return MaxAuthResult(
      ok: false,
      error: mapError(fallback.isNotEmpty ? _fixMojibake(fallback) : null),
    );
  }

  static String _decodeProcessOutput(Object? output) {
    if (output == null) return '';
    if (output is String) return output;
    if (output is List<int>) return utf8.decode(output, allowMalformed: true);
    return output.toString();
  }

  /// UTF-8 bytes were misread as Latin-1 on Windows.
  static String _fixMojibake(String text) {
    if (!text.contains('Ð') && !text.contains('Ñ') && !text.contains('Ã')) {
      return text;
    }
    try {
      return utf8.decode(latin1.encode(text));
    } catch (_) {
      return text;
    }
  }

  static Future<MaxAuthResult> sendCode(String phone) => _run('send-code', {'phone': phone});

  static Future<MaxAuthResult> verifyCode(String phone, String code) =>
      _run('verify-code', {'phone': phone, 'code': code});

  static Future<MaxAuthResult> verify2FA(String phone, String password) =>
      _run('verify-2fa', {'phone': phone, 'password': password});

  static Future<MaxAuthResult> verifyToken(String token, {String? proxy}) =>
      _run('login-token', {
        'token': token,
        if (proxy != null && proxy.trim().isNotEmpty) 'proxy': proxy.trim(),
      });

  static bool isNetworkError(String? error) {
    if (error == null) return false;
    final lower = error.toLowerCase();
    return lower.contains('enotfound') ||
        lower.contains('etimedout') ||
        lower.contains('econnrefused') ||
        lower.contains('getaddrinfo') ||
        lower.contains('network') ||
        lower.contains('dns') ||
        lower.contains('proxy') ||
        lower.contains('socket hang up');
  }

  /// Pulls a session token out of raw paste (plain token, quoted, or whole __oneme_auth JSON).
  static String normalizeTokenInput(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return text;

    // Whole JSON object from localStorage / console.log
    if (text.startsWith('{')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) {
          final map = Map<String, dynamic>.from(decoded);
          final attrs = map['tokenAttrs'];
          final fromAttrs = attrs is Map ? attrs['token']?.toString() : null;
          final candidate = (fromAttrs != null && fromAttrs.isNotEmpty)
              ? fromAttrs
              : map['token']?.toString();
          if (candidate != null && candidate.trim().isNotEmpty) {
            text = candidate.trim();
          }
        }
      } catch (_) {
        // fall through — maybe not JSON
      }
    }

    // Quoted string
    if ((text.startsWith('"') && text.endsWith('"')) ||
        (text.startsWith("'") && text.endsWith("'"))) {
      text = text.substring(1, text.length - 1).trim();
    }

    // Remove accidental whitespace/newlines from paste
    text = text.replaceAll(RegExp(r'\s+'), '');

    // Already a normal session token — keep as-is (do not regex-cut).
    if (text.startsWith('An_') || text.startsWith('AN_')) {
      return text;
    }

    // If pasted blob contains An_… somewhere, take it
    final match = RegExp(r'An_[A-Za-z0-9_-]+', caseSensitive: false).firstMatch(text);
    if (match != null) {
      return match.group(0)!;
    }

    return text;
  }

  static String tokenPreview(String token) {
    final t = normalizeTokenInput(token);
    if (t.isEmpty) return 'пусто';
    if (t.length <= 24) return '$t (${t.length} симв.)';
    return '${t.substring(0, 14)}…${t.substring(t.length - 10)} (${t.length} симв.)';
  }

  static String? validateTokenFormat(String token) {
    final t = normalizeTokenInput(token);
    if (t.isEmpty) {
      return 'Вставьте токен сессии';
    }
    if (t.length < 200) {
      return 'Токен слишком короткий (${t.length} символов) — скопируйте целиком.\n'
          'Нужен токен вида An_… (обычно 400+ символов).';
    }
    if (!t.startsWith('An_') && !t.startsWith('AN_')) {
      final prefix = t.length > 12 ? '${t.substring(0, 12)}…' : t;
      return 'Неверный токен (начинается с «$prefix»).\n'
          'Нужен токен сессии, который начинается с An_.\n\n'
          'В консоли web.max.ru выполните:\n'
          'copy((()=>{const a=JSON.parse(localStorage.getItem("__oneme_auth")||"{}");'
          'return a.tokenAttrs?.token||a.token||"";})())';
    }
    return null;
  }

  static String mapError(String? error) {
    if (error == null || error.trim().isEmpty) {
      return 'MAX не принял токен (пустой ответ). Попробуйте ещё раз или смените прокси.';
    }
    if (isNetworkError(error)) {
      return 'Нет доступа к ws-api.oneme.ru (DNS/сеть/прокси). '
          'Аккаунт можно добавить без проверки — вход через web.max.ru в приложении.';
    }
    final lower = error.toLowerCase();
    if (lower.contains('login') ||
        lower.contains('auth') ||
        lower.contains('token') ||
        lower.contains('unauthorized') ||
        lower.contains('forbidden') ||
        lower.contains('error.login') ||
        lower.contains('session')) {
      return 'MAX не принял токен: $error\n'
          'Скопируйте свежий An_… из web.max.ru и проверьте прокси.';
    }
    return error;
  }
}
