import 'package:flutter_test/flutter_test.dart';
import 'package:max_desktop/services/max_auth_service.dart';

void main() {
  group('MaxAuthService.mapError', () {
    test('socks auth failed is about proxy, not token', () {
      final msg = MaxAuthService.mapError('Socks5 Authentication failed');
      expect(msg, contains('Прокси отклонил логин/пароль'));
      expect(msg, contains('SOCKS5'));
      expect(msg, contains('Токен MAX тут ни при чём'));
      expect(msg, isNot(contains('свежий An_')));
      expect(MaxAuthService.isNetworkError(msg), isTrue);
      expect(MaxAuthService.isProxyError(msg), isTrue);
    });

    test('http 407 is about proxy credentials', () {
      final msg = MaxAuthService.mapError('Proxy Authentication Required (407)');
      expect(msg, contains('HTTP'));
      expect(msg, contains('логин/пароль'));
    });

    test('real token reject is about token', () {
      final msg = MaxAuthService.mapError('login.token');
      expect(msg, contains('Токен MAX отклонён'));
      expect(msg, contains('свежий An_'));
    });

    test('dns failure is network', () {
      final msg = MaxAuthService.mapError('getaddrinfo ENOTFOUND ws-api.oneme.ru');
      expect(msg, contains('DNS'));
      expect(MaxAuthService.isNetworkError(msg), isTrue);
    });
  });
}
