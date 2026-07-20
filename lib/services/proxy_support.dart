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

  /// Chromium `--proxy-server` value. Auth in SOCKS URL is unreliable in WebView2;
  /// we still pass the full URL — API/CLI use proper SOCKS auth separately.
  String get chromiumProxyServer {
    if (isSocks) {
      // Prefer socks5://host:port; credentials via user:pass@ when present.
      final auth = hasAuth
          ? '${Uri.encodeComponent(username ?? '')}:${Uri.encodeComponent(password ?? '')}@'
          : '';
      return 'socks5://$auth$host:$port';
    }
    final auth = hasAuth
        ? '${Uri.encodeComponent(username ?? '')}:${Uri.encodeComponent(password ?? '')}@'
        : '';
    final sch = scheme == 'https' ? 'https' : 'http';
    return '$sch://$auth$host:$port';
  }

  static ParsedProxy? tryParse(String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return null;

    final withScheme = value.contains('://') ? value : 'http://$value';
    final uri = Uri.tryParse(withScheme);
    if (uri == null || uri.host.isEmpty) {
      throw FormatException('Некорректный прокси: $value');
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
      raw: value,
      scheme: scheme,
      host: uri.host,
      port: port,
      username: user,
      password: pass,
    );
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
