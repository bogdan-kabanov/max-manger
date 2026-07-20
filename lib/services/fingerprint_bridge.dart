import '../models/account_isolation.dart';

class FingerprintBridge {
  static String documentScript(AccountIsolation isolation) {
    final ua = _jsString(isolation.userAgent);
    final locale = _jsString(isolation.locale);
    return '''
(function () {
  if (window.__maxFingerprint) return;
  window.__maxFingerprint = true;

  const profile = {
    userAgent: $ua,
    language: $locale,
    languages: [$locale, 'ru', 'en-US', 'en'],
    platform: 'Win32',
    hardwareConcurrency: ${isolation.hardwareConcurrency},
    deviceMemory: ${isolation.deviceMemory},
    screenWidth: ${isolation.screenWidth},
    screenHeight: ${isolation.screenHeight},
  };

  try {
    Object.defineProperty(navigator, 'userAgent', { get: () => profile.userAgent });
    Object.defineProperty(navigator, 'language', { get: () => profile.language });
    Object.defineProperty(navigator, 'languages', { get: () => profile.languages });
    Object.defineProperty(navigator, 'platform', { get: () => profile.platform });
    Object.defineProperty(navigator, 'hardwareConcurrency', { get: () => profile.hardwareConcurrency });
    Object.defineProperty(navigator, 'deviceMemory', { get: () => profile.deviceMemory });
    // Не подменяем window.innerWidth/innerHeight и screen — иначе web.max.ru
    // не видит реальный размер окна (сайдбар не тянется, вёрстка ломается).
  } catch (_) {}
})();
''';
  }

  static String _jsString(String value) {
    return "'${value.replaceAll('\\', '\\\\').replaceAll("'", "\\'")}'";
  }
}
