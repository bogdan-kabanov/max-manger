import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:path_provider/path_provider.dart';

class MaxApkDownloadResult {
  MaxApkDownloadResult({
    required this.ok,
    required this.message,
    this.path,
    this.version,
    this.sizeBytes,
  });

  final bool ok;
  final String message;
  final String? path;
  final String? version;
  final int? sizeBytes;
}

/// Downloads MAX (ru.oneme.app) APK from RuStore public API.
class MaxApkDownloadService {
  static const packageName = 'ru.oneme.app';
  static const _infoUrl = 'https://backapi.rustore.ru/applicationData/overallInfo/$packageName';
  static const _linkUrl = 'https://backapi.rustore.ru/applicationData/v2/download-link';

  Future<String> defaultApkPath() async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}${Platform.pathSeparator}max.apk';
  }

  Future<bool> hasCachedApk() async {
    final file = File(await defaultApkPath());
    return file.existsSync() && file.lengthSync() > 10 * 1024 * 1024;
  }

  Future<MaxApkDownloadResult> download({
    void Function(String message)? onProgress,
  }) async {
    try {
      return await _downloadImpl(onProgress: onProgress).timeout(
        const Duration(minutes: 25),
        onTimeout: () => MaxApkDownloadResult(
          ok: false,
          message: 'Скачивание MAX заняло слишком долго. Проверьте интернет и повторите.',
        ),
      );
    } on SocketException catch (e) {
      return MaxApkDownloadResult(ok: false, message: 'Нет сети: $e');
    } catch (e) {
      return MaxApkDownloadResult(ok: false, message: 'Ошибка загрузки: $e');
    }
  }

  Future<MaxApkDownloadResult> _downloadImpl({
    void Function(String message)? onProgress,
  }) async {
    void progress(String msg) => onProgress?.call(msg);

    progress('Запрос RuStore…');
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 30);

    try {
      final info = await _getJson(client, Uri.parse(_infoUrl));
      final body = info['body'];
      if (body is! Map) {
        return MaxApkDownloadResult(ok: false, message: 'RuStore: нет данных о приложении');
      }

      final appId = body['appId'];
      final version = body['versionName']?.toString() ?? '?';
      if (appId == null) {
        return MaxApkDownloadResult(ok: false, message: 'RuStore: appId не найден');
      }

      progress('Получение ссылки на APK v$version…');
      final link = await _postJson(
        client,
        Uri.parse(_linkUrl),
        {'appId': appId, 'firstInstall': true},
      );

      final linkBody = link['body'];
      if (linkBody is! Map) {
        return MaxApkDownloadResult(ok: false, message: 'RuStore: ссылка на APK недоступна');
      }

      final urls = linkBody['downloadUrls'] as List<dynamic>?;
      final apkUrl = urls?.isNotEmpty == true
          ? (urls!.first as Map)['url']?.toString()
          : linkBody['apkUrl']?.toString();

      if (apkUrl == null || apkUrl.isEmpty) {
        return MaxApkDownloadResult(ok: false, message: 'RuStore: пустой URL APK');
      }

      final destPath = await defaultApkPath();
      final dest = File(destPath);
      await dest.parent.create(recursive: true);

      final sizeBytes = (urls?.first as Map?)?['size'] as num? ?? 130000000;
      final sizeMb = (sizeBytes / (1024 * 1024)).toStringAsFixed(0);
      progress('Скачивание MAX… (~$sizeMb МБ)');
      await _downloadFile(client, Uri.parse(apkUrl), dest, onProgress: progress);

      final size = await dest.length();

      return MaxApkDownloadResult(
        ok: true,
        message: 'MAX v$version скачан (${(size / (1024 * 1024)).toStringAsFixed(1)} МБ)',
        path: destPath,
        version: version,
        sizeBytes: size,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _getJson(HttpClient client, Uri uri) async {
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode}: $text', uri: uri);
    }
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _postJson(
    HttpClient client,
    Uri uri,
    Map<String, dynamic> payload,
  ) async {
    final request = await client.postUrl(uri);
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    request.add(utf8.encode(jsonEncode(payload)));
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode}: $text', uri: uri);
    }
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<void> _downloadFile(
    HttpClient client,
    Uri uri,
    File dest, {
    void Function(String message)? onProgress,
  }) async {
    final request = await client.getUrl(uri);
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }

    final total = response.contentLength;
    final sink = dest.openWrite();
    var received = 0;

    await for (final chunk in response) {
      received += chunk.length;
      sink.add(chunk);
      if (total > 0 && received % (5 * 1024 * 1024) < chunk.length) {
        final pct = (received * 100 / total).toStringAsFixed(0);
        onProgress?.call('Скачивание… $pct% (${(received / (1024 * 1024)).toStringAsFixed(0)} МБ)');
      }
    }

    await sink.close();
  }
}
