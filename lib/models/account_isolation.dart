import 'dart:math';

import 'package:uuid/uuid.dart';

import '../services/proxy_support.dart';

class AccountIsolation {
  AccountIsolation({
    required this.userAgent,
    required this.screenWidth,
    required this.screenHeight,
    required this.hardwareConcurrency,
    required this.deviceMemory,
    this.deviceId,
    this.proxyServer,
    this.locale = 'ru-RU',
  });

  final String userAgent;
  final int screenWidth;
  final int screenHeight;
  final int hardwareConcurrency;
  final int deviceMemory;
  final String? deviceId;
  final String? proxyServer;
  final String locale;

  AccountIsolation copyWith({
    String? userAgent,
    int? screenWidth,
    int? screenHeight,
    int? hardwareConcurrency,
    int? deviceMemory,
    String? deviceId,
    String? proxyServer,
    bool clearProxy = false,
    String? locale,
  }) {
    return AccountIsolation(
      userAgent: userAgent ?? this.userAgent,
      screenWidth: screenWidth ?? this.screenWidth,
      screenHeight: screenHeight ?? this.screenHeight,
      hardwareConcurrency: hardwareConcurrency ?? this.hardwareConcurrency,
      deviceMemory: deviceMemory ?? this.deviceMemory,
      deviceId: deviceId ?? this.deviceId,
      proxyServer: clearProxy ? null : (proxyServer ?? this.proxyServer),
      locale: locale ?? this.locale,
    );
  }

  Map<String, dynamic> toJson() => {
        'userAgent': userAgent,
        'screenWidth': screenWidth,
        'screenHeight': screenHeight,
        'hardwareConcurrency': hardwareConcurrency,
        'deviceMemory': deviceMemory,
        if (deviceId != null) 'deviceId': deviceId,
        'proxyServer': proxyServer,
        'locale': locale,
      };

  factory AccountIsolation.fromJson(Map<String, dynamic> json) {
    return AccountIsolation(
      userAgent: json['userAgent'] as String,
      screenWidth: json['screenWidth'] as int,
      screenHeight: json['screenHeight'] as int,
      hardwareConcurrency: json['hardwareConcurrency'] as int,
      deviceMemory: json['deviceMemory'] as int,
      deviceId: json['deviceId'] as String?,
      proxyServer: json['proxyServer'] as String?,
      locale: json['locale'] as String? ?? 'ru-RU',
    );
  }

  /// Unique Chromium flags for this profile — applied when the account browser starts.
  String chromiumArguments() {
    final parts = <String>[
      '--lang=$locale',
      '--user-agent=${_escape(userAgent)}',
      '--disable-sync',
      '--disable-background-networking',
      '--disable-features=Translate,OptimizationHints',
    ];
    final proxy = proxyServer?.trim();
    if (proxy != null && proxy.isNotEmpty) {
      final parsed = ParsedProxy.tryParse(proxy);
      parts.add('--proxy-server=${_escape(parsed?.chromiumProxyServer ?? proxy)}');
    }
    return parts.join(' ');
  }

  static String _escape(String value) {
    if (!value.contains(' ') && !value.contains('"')) return value;
    return '"${value.replaceAll('"', '\\"')}"';
  }
}

class ProfileFingerprint {
  static AccountIsolation generate(String seed) {
    final random = Random(_seedToInt(seed));

    final chromeVersions = [131, 132, 133, 134, 135, 136];
    final chrome = chromeVersions[random.nextInt(chromeVersions.length)];
    final build = 6000 + random.nextInt(800);
    final patch = random.nextInt(200);

    final widths = [1366, 1440, 1536, 1600, 1920];
    final heights = [768, 900, 864, 900, 1080];
    final idx = random.nextInt(widths.length);

    final osVariants = [
      'Windows NT 10.0; Win64; x64',
      'Windows NT 10.0; WOW64',
    ];
    final os = osVariants[random.nextInt(osVariants.length)];

    final userAgent =
        'Mozilla/5.0 ($os) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$chrome.0.$build.$patch Safari/537.36 Edg/$chrome.0.$build.$patch';

    final coresOptions = [4, 6, 8, 12, 16];
    final memoryOptions = [4, 8, 16];

    return AccountIsolation(
      userAgent: userAgent,
      screenWidth: widths[idx],
      screenHeight: heights[idx],
      hardwareConcurrency: coresOptions[random.nextInt(coresOptions.length)],
      deviceMemory: memoryOptions[random.nextInt(memoryOptions.length)],
      deviceId: const Uuid().v5(Uuid.NAMESPACE_URL, 'max-desktop-device:$seed'),
      locale: random.nextBool() ? 'ru-RU' : 'ru',
    );
  }

  static int _seedToInt(String seed) {
    return seed.codeUnits.fold(0, (a, b) => (a * 31 + b) & 0x7fffffff);
  }
}
