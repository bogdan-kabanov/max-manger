import 'dart:io';

import 'package:socks5_proxy/socks_client.dart';

class ParsedProxy {
  ParsedProxy({
    required this.raw,
    required this.scheme,
    required this.host,
    required this.port,
    this.username,
    this.password,
  });

  final String raw;
  final String scheme;
  final String host;
  final int port;
  final String? username;
  final String? password;

  bool get isSocks => scheme.startsWith('socks');
  bool get hasAuth =>
      (username != null && username!.isNotEmpty) ||
      (password != null && password!.isNotEmpty);

  String get masked {
    if (!hasAuth) return raw;
    try {
      final u = Uri.parse(raw.contains('://') ? raw : 'http://$raw');
      return u.replace(userInfo: '${u.userInfo.split(':').first}:***').toString();
    } catch (_) {
      return raw.replaceAll(RegExp(r':[^:@/]+@'), ':***@');
    }
  }

  /// Value for Chromium `--proxy-server`.
  ///
  /// Must NOT include credentials — that causes `ERR_NO_SUPPORTED_PROXIES`.
  /// Edge/WebView2 also has no SOCKS5 auth; authenticated SOCKS is remapped
  /// to HTTP CONNECT (`http://host:port`) and credentials go through
  /// [BasicAuthenticationRequested] via `--max-desktop-proxy-*` flags.
  String get chromiumProxyServer {
    if (isSocks && !hasAuth) {
      return 'socks5://$host:$port';
    }
    // HTTP(S) proxy, or SOCKS+auth (unsupported in Edge) → HTTP CONNECT.
    return 'http://$host:$port';
  }

  /// Extra Chromium args that the WebView2 plugin strips and uses for 407 auth.
  List<String> get chromiumAuthArguments {
    if (!hasAuth) return const [];
    return [
      '--max-desktop-proxy-user=${Uri.encodeComponent(username ?? '')}',
      '--max-desktop-proxy-pass=${Uri.encodeComponent(password ?? '')}',
    ];
  }

  /// Canonical URL for API / Node (`user:pass@host` form).
  String get normalizedUrl {
    final auth = hasAuth
        ? '${Uri.encodeComponent(username ?? '')}:${Uri.encodeComponent(password ?? '')}@'
        : '';
    if (isSocks) {
      final sch = scheme.startsWith('socks5') ? 'socks5' : scheme;
      return '$sch://$auth$host:$port';
    }
    final sch = scheme == 'https' ? 'https' : 'http';
    return '$sch://$auth$host:$port';
  }

  static ParsedProxy? tryParse(String? raw) {
    final value = _preprocess(raw);
    if (value == null) return null;

    final withScheme = value.contains('://') ? value : 'http://$value';
    final uri = Uri.tryParse(withScheme);
    if (uri == null || uri.host.isEmpty) {
      throw FormatException('Некорректный прокси: $raw');
    }

    final scheme = uri.scheme.toLowerCase();
    final port = uri.hasPort
        ? uri.port
        : (scheme.startsWith('socks')
            ? 1080
            : (scheme == 'https' ? 443 : 80));

    String? user;
    String? pass;
    if (uri.userInfo.isNotEmpty) {
      final parts = uri.userInfo.split(':');
      user = Uri.decodeComponent(parts.first);
      pass = parts.length > 1 ? Uri.decodeComponent(parts.sublist(1).join(':')) : '';
    }

    return ParsedProxy(
      raw: raw!.trim(),
      scheme: scheme,
      host: uri.host,
      port: port,
      username: user,
      password: pass,
    );
  }

  /// Accepts common provider paste formats and strips UI country labels.
  static String? _preprocess(String? raw) {
    var value = raw?.trim();
    if (value == null || value.isEmpty) return null;

    // socks5://user:pass@host:443:Uzbekistan → drop trailing :Label
    final trailingLabel = RegExp(r'^(.*?://.+?:\d+):([A-Za-z][\w\- ]*)$');
    final labelMatch = trailingLabel.firstMatch(value);
    if (labelMatch != null) {
      value = labelMatch.group(1)!;
    }

    // host:port:user:pass[:Country]
    if (!value.contains('://') && !value.contains('@')) {
      final parts = value.split(':');
      if (parts.length >= 4 && int.tryParse(parts[1]) != null) {
        final host = parts[0];
        final port = parts[1];
        final user = parts[2];
        // Last segment is a country label if non-numeric-looking letters-only
        // and we have 5+ parts; otherwise password is everything after user.
        String pass;
        if (parts.length >= 5 && RegExp(r'^[A-Za-z][\w\- ]*$').hasMatch(parts.last)) {
          pass = parts.sublist(3, parts.length - 1).join(':');
        } else {
          pass = parts.sublist(3).join(':');
        }
        return 'http://$user:$pass@$host:$port';
      }
    }

    // user:pass@host:port
    if (!value.contains('://') && value.contains('@')) {
      return 'http://$value';
    }

    return value;
  }
}

/// Opens WSS through HTTP(S) or SOCKS5 proxy (with login/password).
Future<WebSocket> openProxiedWebSocket(
  String wsUrl, {
  required Map<String, dynamic> headers,
  String? proxyUrl,
}) async {
  final parsed = ParsedProxy.tryParse(proxyUrl);
  if (parsed == null) {
    return WebSocket.connect(wsUrl, headers: headers);
  }

  final client = HttpClient();
  if (parsed.isSocks) {
    final addresses = await InternetAddress.lookup(parsed.host);
    if (addresses.isEmpty) {
      throw SocketException('Не удалось резолвить прокси ${parsed.host}');
    }
    SocksTCPClient.assignToHttpClient(client, [
      ProxySettings(
        addresses.first,
        parsed.port,
        username: parsed.username,
        password: parsed.password,
      ),
    ]);
  } else {
    client.findProxy = (_) => 'PROXY ${parsed.host}:${parsed.port}';
    if (parsed.hasAuth) {
      client.addProxyCredentials(
        parsed.host,
        parsed.port,
        'MAX Desktop',
        HttpClientBasicCredentials(parsed.username ?? '', parsed.password ?? ''),
      );
    }
  }

  return WebSocket.connect(wsUrl, headers: headers, customClient: client);
}
