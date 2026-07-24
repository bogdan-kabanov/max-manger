import 'dart:convert';
import 'dart:io';

import '../models/max_account.dart';
import 'node_runtime.dart';

class MaxAuthResult {
  MaxAuthResult({
    required this.ok,
    this.error,
    this.code,
    this.smsSent,
    this.requires2FA,
    this.hint,
    this.token,
    this.phone,
    this.profileName,
    this.profileFirstName,
    this.profileLastName,
    this.profileDescription,
    this.profilePhone,
    this.profileId,
  });

  final bool ok;
  final String? error;
  /// Raw MAX / CLI error code when present (e.g. `login.token`, `user.blocked`).
  final String? code;
  final bool? smsSent;
  final bool? requires2FA;
  final String? hint;
  final String? token;
  final String? phone;
  final String? profileName;
  final String? profileFirstName;
  final String? profileLastName;
  final String? profileDescription;
  final String? profilePhone;
  final int? profileId;

  AccountHealthStatus get healthStatus => MaxAuthService.classifyHealth(
        ok: ok,
        code: code,
        error: error,
      );

  factory MaxAuthResult.fromJson(Map<String, dynamic> json) {
    final profile = json['profile'] as Map<String, dynamic>?;
    return MaxAuthResult(
      ok: json['ok'] == true,
      error: _asString(json['error']),
      code: _asString(json['code']),
      smsSent: json['smsSent'] as bool?,
      requires2FA: json['requires2FA'] as bool?,
      hint: _asString(json['hint']),
      token: _asString(json['token']),
      phone: _asString(json['phone']),
      profileName: _asString(profile?['name']),
      profileFirstName: _asString(profile?['firstName']),
      profileLastName: _asString(profile?['lastName']),
      profileDescription: _asString(profile?['description']),
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
        code: parsed.code,
        smsSent: parsed.smsSent,
        requires2FA: parsed.requires2FA,
        hint: parsed.hint != null ? _fixMojibake(parsed.hint!) : null,
        token: parsed.token,
        phone: parsed.phone,
        profileName: parsed.profileName,
        profileFirstName: parsed.profileFirstName,
        profileLastName: parsed.profileLastName,
        profileDescription: parsed.profileDescription,
        profilePhone: parsed.profilePhone,
        profileId: parsed.profileId,
      );
    }

    final fallback = stderr.isNotEmpty ? stderr : stdout;
    return MaxAuthResult(
      ok: false,
      error: mapError(fallback.isNotEmpty ? _fixMojibake(fallback) : null),
      code: 'cli.parse',
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

  /// Push name / about / avatar to MAX (opcode 16).
  static Future<MaxAuthResult> updateProfile({
    required String token,
    String? proxy,
    String? firstName,
    String? lastName,
    String? description,
    String? photoPath,
    bool includeFirstName = true,
    bool includeLastName = true,
    bool includeDescription = true,
  }) {
    final args = <String, dynamic>{
      'token': token,
      if (proxy != null && proxy.trim().isNotEmpty) 'proxy': proxy.trim(),
    };
    if (includeFirstName) args['firstName'] = firstName?.trim() ?? '';
    if (includeLastName) args['lastName'] = lastName?.trim() ?? '';
    if (includeDescription) args['description'] = description ?? '';
    final photo = photoPath?.trim();
    if (photo != null && photo.isNotEmpty) args['photoPath'] = photo;
    return _run('update-profile', args);
  }

  static bool isNetworkError(String? error) {
    if (error == null) return false;
    final lower = error.toLowerCase();
    return lower.contains('enotfound') ||
        lower.contains('etimedout') ||
        lower.contains('econnrefused') ||
        lower.contains('econnreset') ||
        lower.contains('getaddrinfo') ||
        lower.contains('network') ||
        lower.contains('dns') ||
        lower.contains('proxy') ||
        lower.contains('прокси') ||
        lower.contains('socks') ||
        lower.contains('сокс') ||
        lower.contains('socket hang up') ||
        lower.contains('network.error') ||
        lower.contains('407') ||
        lower.contains('err_no_supported_proxies') ||
        lower.contains('недоступен') ||
        lower.contains('таймаут');
  }

  /// Proxy login/host/port problems (not a bad MAX token).
  static bool isProxyError(String? error) {
    if (error == null) return false;
    final lower = error.toLowerCase();
    return lower.contains('socks') ||
        lower.contains('сокс') ||
        lower.contains('proxy authentication') ||
        lower.contains('прокси отклонил') ||
        lower.contains('прокси недоступен') ||
        lower.contains('логин/пароль прокси') ||
        lower.contains('формат прокси') ||
        lower.contains('err_no_supported_proxies') ||
        (lower.contains('407') && lower.contains('прокси'));
  }

  /// Map login-token result to a persisted account health status.
  static AccountHealthStatus classifyHealth({
    required bool ok,
    String? code,
    String? error,
  }) {
    if (ok) return AccountHealthStatus.ok;
    if (isProxyError(error) ||
        isProxyError(code) ||
        isNetworkError(error) ||
        isNetworkError(code)) {
      return AccountHealthStatus.networkError;
    }
    final hay = '${code ?? ''} ${error ?? ''}'.toLowerCase();
    if (_looksBanned(hay)) return AccountHealthStatus.banned;
    return AccountHealthStatus.authFailed;
  }

  static bool _looksBanned(String hay) {
    const markers = [
      'ban',
      'banned',
      'забан',
      'blocked',
      'заблок',
      'блокиров',
      'suspend',
      'suspended',
      'disabled',
      'deactivat',
      'user.blocked',
      'account.blocked',
      'login.blocked',
      'error.user.blocked',
      'error.account.blocked',
      'access.denied',
    ];
    for (final m in markers) {
      if (hay.contains(m)) return true;
    }
    return false;
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
      return 'MAX не ответил при проверке токена.\n'
          'Попробуйте ещё раз. Если снова пусто — смените прокси или сеть.';
    }

    final lower = error.toLowerCase();

    // Proxy errors MUST be checked before generic "auth" — e.g.
    // "Socks5 Authentication failed" contains "auth" but is NOT a bad token.
    final proxyMapped = _mapProxyError(lower, error);
    if (proxyMapped != null) return proxyMapped;

    if (lower.contains('enotfound') ||
        lower.contains('getaddrinfo') ||
        lower.contains('dns')) {
      return 'Нет DNS / хост не найден.\n'
          'Проверьте интернет. Если указан прокси — нет опечатки в адресе хоста.\n'
          'Аккаунт можно добавить без проверки.';
    }
    if (lower.contains('etimedout') ||
        lower.contains('timeout') ||
        lower.contains('timed out')) {
      return 'Таймаут соединения с MAX (сеть или прокси).\n'
          'Прокси может быть мёртвым или слишком медленным. Смените прокси и повторите.\n'
          'Аккаунт можно добавить без проверки.';
    }
    if (lower.contains('econnrefused') || lower.contains('econnreset')) {
      return 'Соединение сброшено / отказано.\n'
          'Частая причина — неверный порт прокси или прокси выключен.\n'
          'Аккаунт можно добавить без проверки.';
    }
    if (lower.contains('socket hang up') || lower.contains('network')) {
      return 'Сбой сети при обращении к ws-api.oneme.ru.\n'
          'Проверьте интернет и прокси. Аккаунт можно добавить без проверки.';
    }

    if (lower.contains('login.token') ||
        lower.contains('error.login') ||
        lower.contains('unauthorized') ||
        lower.contains('forbidden') ||
        lower.contains('invalid token') ||
        lower.contains('token expired') ||
        (lower.contains('session') && lower.contains('invalid')) ||
        (lower.contains('token') &&
            (lower.contains('invalid') ||
                lower.contains('expired') ||
                lower.contains('reject')))) {
      return 'Токен MAX отклонён (устарел или неверный).\n'
          'Скопируйте свежий An_… из web.max.ru (консоль → localStorage __oneme_auth).\n'
          'Прокси тут ни при чём — нужен новый токен.';
    }

    // Last resort: keep technical detail, but say what it likely is.
    if (lower.contains('login') || lower.contains('auth')) {
      return 'Ошибка входа MAX: $error\n'
          'Если в тексте про proxy/socks — чините прокси. '
          'Иначе скопируйте свежий токен An_… из web.max.ru.';
    }
    return error;
  }

  static String? _mapProxyError(String lower, String original) {
    if (lower.contains('socks') &&
        (lower.contains('authentication failed') ||
            lower.contains('auth failed') ||
            lower.contains('not authorized') ||
            lower.contains('unauthorized'))) {
      return 'Прокси отклонил логин/пароль (SOCKS5).\n'
          '• Логин и пароль должны быть целиком (часто обрезается начало логина).\n'
          '• Формат: socks5://логин:пароль@хост:порт\n'
          '• Порт должен быть именно SOCKS5 у провайдера (не HTTP).\n'
          'Токен MAX тут ни при чём.';
    }
    if (lower.contains('proxy authentication') ||
        lower.contains('authentication required') ||
        lower.contains('407')) {
      return 'Прокси отклонил логин/пароль (HTTP).\n'
          'Проверьте user:pass и что порт — HTTP-прокси. '
          'Формат: http://логин:пароль@хост:порт\n'
          'Токен MAX тут ни при чём.';
    }
    if (lower.contains('err_no_supported_proxies')) {
      return 'Неверный формат прокси для браузера.\n'
          'Не вставляйте логин:пароль внутрь --proxy-server. '
          'Используйте: socks5://user:pass@host:port или http://user:pass@host:port';
    }
    if ((lower.contains('socks') || lower.contains('proxy')) &&
        (lower.contains('econnrefused') ||
            lower.contains('enotfound') ||
            lower.contains('etimedout') ||
            lower.contains('could not connect') ||
            lower.contains('connect failed'))) {
      return 'Прокси недоступен (хост/порт).\n'
          'Проверьте адрес, порт и что прокси онлайн у провайдера.\n'
          'Токен MAX тут ни при чём.';
    }
    if (lower.contains('socks') && lower.contains('failed')) {
      return 'Ошибка SOCKS5-прокси: $original\n'
          'Проверьте строку socks5://логин:пароль@хост:порт. '
          'Токен MAX обычно ни при чём.';
    }
    return null;
  }
}
