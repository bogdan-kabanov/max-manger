import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class AppUpdateInfo {
  AppUpdateInfo({
    required this.version,
    required this.build,
    required this.url,
    this.notes,
    this.mandatory = false,
  });

  final String version;
  final int build;
  final String url;
  final String? notes;
  final bool mandatory;

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    return AppUpdateInfo(
      version: json['version']?.toString() ?? '0.0.0',
      build: int.tryParse('${json['build'] ?? 0}') ?? 0,
      url: json['url']?.toString() ?? '',
      notes: json['notes']?.toString(),
      mandatory: json['mandatory'] == true,
    );
  }
}

class AppUpdateService {
  /// Public update feed on the VPS.
  static const feedUrl = 'http://145.63.130.142:8080/latest.json';

  static Future<({String version, int build})> currentVersion() async {
    final info = await PackageInfo.fromPlatform();
    return (
      version: info.version,
      build: int.tryParse(info.buildNumber) ?? 0,
    );
  }

  static Future<AppUpdateInfo?> checkForUpdate() async {
    if (!Platform.isWindows) return null;

    final response = await http
        .get(Uri.parse(feedUrl))
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw StateError('Сервер обновлений: HTTP ${response.statusCode}');
    }

    var body = response.body;
    if (body.isNotEmpty && body.codeUnitAt(0) == 0xFEFF) {
      body = body.substring(1);
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) return null;
    final json = Map<String, dynamic>.from(decoded);
    final remote = AppUpdateInfo.fromJson(json);
    if (remote.url.trim().isEmpty || remote.version == '0.0.0') return null;

    final current = await currentVersion();
    if (!_isNewer(remote.version, remote.build, current.version, current.build)) {
      return null;
    }
    return remote;
  }

  static bool _isNewer(String remoteV, int remoteBuild, String localV, int localBuild) {
    final r = _parseVersion(remoteV);
    final l = _parseVersion(localV);
    for (var i = 0; i < 3; i++) {
      if (r[i] != l[i]) return r[i] > l[i];
    }
    return remoteBuild > localBuild;
  }

  static List<int> _parseVersion(String raw) {
    final parts = raw.split(RegExp(r'[^0-9]+')).where((p) => p.isNotEmpty).toList();
    return [
      for (var i = 0; i < 3; i++) i < parts.length ? int.tryParse(parts[i]) ?? 0 : 0,
    ];
  }

  /// Downloads the installer and launches it silently, then exits the app.
  static Future<void> downloadAndInstall(
    AppUpdateInfo update, {
    void Function(double progress)? onProgress,
  }) async {
    final uri = Uri.parse(update.url);
    final client = http.Client();
    try {
      final request = http.Request('GET', uri);
      final streamed = await client.send(request).timeout(const Duration(minutes: 5));
      if (streamed.statusCode != 200) {
        throw StateError('Не удалось скачать обновление: HTTP ${streamed.statusCode}');
      }

      final total = streamed.contentLength ?? 0;
      var received = 0;
      final tempDir = await getTemporaryDirectory();
      final file = File(
        '${tempDir.path}${Platform.pathSeparator}MAX-Desktop-Setup-${update.version}.exe',
      );
      final sink = file.openWrite();
      await for (final chunk in streamed.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.flush();
      await sink.close();

      // Inno Setup silent install; closes running app and replaces files.
      await Process.start(
        file.path,
        const ['/VERYSILENT', '/NORESTART', '/CLOSEAPPLICATIONS', '/FORCECLOSEAPPLICATIONS'],
        mode: ProcessStartMode.detached,
      );
      await Future<void>.delayed(const Duration(milliseconds: 800));
      exit(0);
    } finally {
      client.close();
    }
  }
}
