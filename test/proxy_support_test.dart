import 'package:flutter_test/flutter_test.dart';
import 'package:max_desktop/services/proxy_support.dart';

void main() {
  group('ParsedProxy.tryParse', () {
    test('parses host:port:user:pass', () {
      final p = ParsedProxy.tryParse(
        '45.82.64.195:443:j0s8qktucw-corp.mobile.user:zYlC7kt9coykH7GI',
      );
      expect(p, isNotNull);
      expect(p!.host, '45.82.64.195');
      expect(p.port, 443);
      expect(p.username, 'j0s8qktucw-corp.mobile.user');
      expect(p.password, 'zYlC7kt9coykH7GI');
      expect(p.chromiumProxyServer, 'http://45.82.64.195:443');
      expect(p.chromiumAuthArguments, hasLength(2));
    });

    test('strips trailing country label from socks URL', () {
      final p = ParsedProxy.tryParse(
        'socks5://user:pass@45.82.64.195:443:Uzbekistan',
      );
      expect(p, isNotNull);
      expect(p!.host, '45.82.64.195');
      expect(p.port, 443);
      expect(p.username, 'user');
      expect(p.password, 'pass');
      // SOCKS+auth → http for Chromium (Edge has no SOCKS auth).
      expect(p.chromiumProxyServer, 'http://45.82.64.195:443');
    });

    test('socks without auth stays socks5 for Chromium', () {
      final p = ParsedProxy.tryParse('socks5://45.82.64.195:1080');
      expect(p!.chromiumProxyServer, 'socks5://45.82.64.195:1080');
      expect(p.chromiumAuthArguments, isEmpty);
    });

    test('http user:pass@host never puts creds in chromiumProxyServer', () {
      final p = ParsedProxy.tryParse(
        'http://user:secret@1.2.3.4:8080',
      );
      expect(p!.chromiumProxyServer, 'http://1.2.3.4:8080');
      expect(
        p.chromiumAuthArguments.any((a) => a.contains('user')),
        isTrue,
      );
    });
  });
}
