import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/max_channel_catalog_entry.dart';
import '../models/mother_group_channel.dart';
import 'node_runtime.dart';

typedef MotherProgressCallback = void Function(String message);

/// Only one mother CLI process at a time — parallel node sessions kick each other off MAX.
final _motherCliLock = _AsyncLock();

class _AsyncLock {
  Future<void>? _chain = Future.value();

  Future<T> run<T>(Future<T> Function() action) {
    final next = _chain!.then((_) => action());
    _chain = next.then((_) {}, onError: (_) {});
    return next;
  }
}

class MotherGroupsResult {
  MotherGroupsResult({
    required this.ok,
    required this.message,
    this.groups = const [],
  });

  final bool ok;
  final String message;
  final List<MotherGroupChannel> groups;

  factory MotherGroupsResult.fromJson(Map<String, dynamic> json) {
    final raw = json['groups'] as List<dynamic>? ?? const [];
    return MotherGroupsResult(
      ok: json['ok'] == true,
      message: json['error']?.toString() ?? 'Готово',
      groups: raw
          .whereType<Map<String, dynamic>>()
          .map(_groupFromCli)
          .where((g) => g.chatId.isNotEmpty)
          .toList(),
    );
  }
}

MotherGroupChannel _groupFromCli(Map<String, dynamic> json) {
  final rawHash = json['hash']?.toString() ?? json['inviteHash']?.toString();
  final hash = MotherGroupChannel.isValidInviteHash(rawHash) ? rawHash!.trim() : null;
  return MotherGroupChannel(
    chatId: json['chatId']?.toString() ?? '',
    title: json['title']?.toString() ?? 'Без названия',
    type: json['type']?.toString(),
    inviteHash: hash,
    updatedAt: DateTime.now(),
  );
}

class ChannelDiscoverResult {
  ChannelDiscoverResult({
    required this.ok,
    required this.message,
    this.channels = const [],
    this.added = 0,
    this.requested = 0,
  });

  final bool ok;
  final String message;
  final List<MaxChannelCatalogEntry> channels;
  final int added;
  final int requested;

  factory ChannelDiscoverResult.fromJson(Map<String, dynamic> json) {
    final raw = json['channels'] as List<dynamic>? ?? json['groups'] as List<dynamic>? ?? const [];
    final channels = raw
        .whereType<Map<String, dynamic>>()
        .map(MaxChannelCatalogEntry.fromCli)
        .where((c) => c.chatId.isNotEmpty && c.hasInviteLink)
        .toList();
    return ChannelDiscoverResult(
      ok: json['ok'] == true,
      message: json['error']?.toString() ?? 'Готово',
      channels: channels,
      added: json['added'] as int? ?? channels.length,
      requested: json['requested'] as int? ?? channels.length,
    );
  }
}

class MotherJoinResult {
  MotherJoinResult({
    required this.ok,
    required this.message,
    this.joined = 0,
    this.invited = 0,
    this.forwarded = 0,
    this.failed = 0,
    this.total = 0,
    this.results = const [],
    this.groups = const [],
  });

  final bool ok;
  final String message;
  final int joined;
  final int invited;
  final int forwarded;
  final int failed;
  final int total;
  final List<Map<String, dynamic>> results;
  final List<MotherGroupChannel> groups;

  factory MotherJoinResult.fromJson(Map<String, dynamic> json) {
    final results = (json['results'] as List<dynamic>?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        const [];
    final rawGroups = json['groups'] as List<dynamic>? ?? const [];
    final groups = rawGroups
        .whereType<Map<String, dynamic>>()
        .map(_groupFromCli)
        .where((g) => g.chatId.isNotEmpty)
        .toList();
    final joined = json['joined'] as int? ?? results.where((r) => r['phase'] == 'join' && r['ok'] == true).length;
    final invited = json['invited'] as int? ?? results.where((r) => r['phase'] == 'invite' && r['ok'] == true).length;
    final forwarded = json['forwarded'] as int? ?? results.where((r) => r['phase'] == 'forward' && r['ok'] == true).length;
    final failed = results.where((r) => r['ok'] != true).length;
    final total = json['total'] as int? ??
        [
          results.length,
          joined + invited + forwarded + failed,
        ].reduce((a, b) => a > b ? a : b);

    return MotherJoinResult(
      ok: json['ok'] == true,
      message: json['error']?.toString() ?? 'Готово',
      joined: joined,
      invited: invited,
      forwarded: forwarded,
      failed: failed,
      total: total,
      results: results,
      groups: groups,
    );
  }
}

class MaxMotherService {
  static Future<bool> isAvailable() => NodeRuntime.isAvailable();

  static Future<MotherJoinResult> motherDeploy({
    required String motherToken,
    required List<String> links,
    List<Map<String, dynamic>> groups = const [],
    List<String> chatIds = const [],
    List<int> inviteUserIds = const [],
    List<int> forwardUserIds = const [],
    List<String> childTokens = const [],
    List<Map<String, dynamic>> childTargets = const [],
    int delayMs = 2500,
    bool inviteChildren = false,
    bool forwardChildren = true,
    bool childrenJoin = true,
    String? proxy,
    MotherProgressCallback? onProgress,
  }) async {
    return _run(
      'mother-deploy',
      {
        'token': motherToken,
        'links': links,
        if (groups.isNotEmpty) 'groups': groups,
        if (chatIds.isNotEmpty) 'chatIds': chatIds,
        'inviteUserIds': inviteUserIds,
        'forwardUserIds': forwardUserIds,
        'childTokens': childTokens,
        if (childTargets.isNotEmpty) 'childTargets': childTargets,
        'delayMs': delayMs,
        'inviteChildren': inviteChildren,
        'forwardChildren': forwardChildren,
        'childrenJoin': childrenJoin,
      },
      onProgress: onProgress,
      proxy: proxy,
    );
  }

  static Future<MotherGroupsResult> listMotherGroups({
    required String token,
    bool scanMessages = true,
    String? proxy,
    MotherProgressCallback? onProgress,
  }) async {
    final json = await _runRaw(
      'list-groups',
      {
        'token': token,
        'scanMessages': scanMessages,
      },
      onProgress: onProgress,
      proxy: proxy,
    );
    if (json == null) {
      return MotherGroupsResult(ok: false, message: 'Пустой ответ CLI');
    }
    return MotherGroupsResult.fromJson(json);
  }

  static Future<ChannelDiscoverResult> discoverChannels({
    required String token,
    required int count,
    List<String> topics = const [],
    List<String> excludeHashes = const [],
    List<String> excludeChatIds = const [],
    String? proxy,
    MotherProgressCallback? onProgress,
  }) async {
    final json = await _runRaw(
      'discover-channels',
      {
        'token': token,
        'count': count,
        if (topics.isNotEmpty) 'topics': topics,
        if (excludeHashes.isNotEmpty) 'excludeHashes': excludeHashes,
        if (excludeChatIds.isNotEmpty) 'excludeChatIds': excludeChatIds,
      },
      onProgress: onProgress,
      proxy: proxy,
    );
    if (json == null) {
      return ChannelDiscoverResult(ok: false, message: 'Пустой ответ CLI');
    }
    final result = ChannelDiscoverResult.fromJson(json);
    if (json['error'] != null) {
      return ChannelDiscoverResult(
        ok: false,
        message: json['error'].toString(),
        channels: result.channels,
        added: result.added,
        requested: count,
      );
    }
    return result;
  }

  static Future<MotherGroupsResult> scanChatInvites({
    required String token,
    required List<String> chatIds,
    String? proxy,
    MotherProgressCallback? onProgress,
  }) {
    return fetchProfileInviteLinks(
      token: token,
      chatIds: chatIds,
      proxy: proxy,
      onProgress: onProgress,
    );
  }

  static Future<MotherGroupsResult> fetchProfileInviteLinks({
    required String token,
    required List<String> chatIds,
    List<Map<String, dynamic>> groups = const [],
    String? proxy,
    MotherProgressCallback? onProgress,
  }) async {
    final json = await _runRaw(
      'fetch-profile-invite-links',
      {
        'token': token,
        'chatIds': chatIds,
        if (groups.isNotEmpty) 'groups': groups,
      },
      onProgress: onProgress,
      proxy: proxy,
    );
    if (json == null) {
      return MotherGroupsResult(ok: false, message: 'Пустой ответ CLI');
    }
    return MotherGroupsResult.fromJson(json);
  }

  static Future<MotherJoinResult> joinGroups({
    required String token,
    required List<String> links,
    int delayMs = 2500,
    String? proxy,
    MotherProgressCallback? onProgress,
  }) async {
    return _run(
      'join-groups',
      {
        'token': token,
        'links': links,
        'delayMs': delayMs,
      },
      onProgress: onProgress,
      proxy: proxy,
    );
  }

  /// Mother invites child accounts to groups (matka already joined).
  static Future<MotherJoinResult> inviteChildren({
    required String motherToken,
    required List<String> links,
    List<Map<String, dynamic>> groups = const [],
    List<String> chatIds = const [],
    required List<int> inviteUserIds,
    int delayMs = 2500,
    String? proxy,
    MotherProgressCallback? onProgress,
  }) async {
    return _run(
      'invite-children',
      {
        'token': motherToken,
        'links': links,
        if (groups.isNotEmpty) 'groups': groups,
        if (chatIds.isNotEmpty) 'chatIds': chatIds,
        'inviteUserIds': inviteUserIds,
        'delayMs': delayMs,
      },
      onProgress: onProgress,
      proxy: proxy,
    );
  }

  /// Mother forwards invite links to child accounts in private chat.
  static Future<MotherJoinResult> forwardLinks({
    required String motherToken,
    required List<String> links,
    List<Map<String, dynamic>> groups = const [],
    List<String> chatIds = const [],
    required List<int> forwardUserIds,
    int delayMs = 2500,
    String? proxy,
    MotherProgressCallback? onProgress,
  }) async {
    return _run(
      'forward-links',
      {
        'token': motherToken,
        'links': links,
        if (groups.isNotEmpty) 'groups': groups,
        if (chatIds.isNotEmpty) 'chatIds': chatIds,
        'forwardUserIds': forwardUserIds,
        'delayMs': delayMs,
      },
      onProgress: onProgress,
      proxy: proxy,
    );
  }

  /// Mother forwards links to children, then each child joins via invite link.
  static Future<MotherJoinResult> forwardAndJoin({
    required String motherToken,
    required List<String> links,
    List<Map<String, dynamic>> groups = const [],
    List<String> chatIds = const [],
    required List<Map<String, dynamic>> childTargets,
    int delayMs = 2500,
    String? proxy,
    MotherProgressCallback? onProgress,
  }) async {
    return _run(
      'forward-and-join',
      {
        'token': motherToken,
        'links': links,
        if (groups.isNotEmpty) 'groups': groups,
        if (chatIds.isNotEmpty) 'chatIds': chatIds,
        'childTargets': childTargets,
        'delayMs': delayMs,
      },
      onProgress: onProgress,
      proxy: proxy,
    );
  }

  /// Child accounts join all groups by invite links themselves.
  static Future<MotherJoinResult> childrenJoin({
    required List<String> childTokens,
    required List<String> links,
    List<Map<String, dynamic>> groups = const [],
    List<String> chatIds = const [],
    String? motherToken,
    int delayMs = 2500,
    String? proxy,
    List<String?> childProxies = const [],
    MotherProgressCallback? onProgress,
  }) async {
    return _run(
      'children-join',
      {
        'childTokens': childTokens,
        'links': links,
        if (groups.isNotEmpty) 'groups': groups,
        if (chatIds.isNotEmpty) 'chatIds': chatIds,
        if (motherToken != null && motherToken.isNotEmpty) 'motherToken': motherToken,
        'delayMs': delayMs,
        if (childProxies.isNotEmpty) 'childProxies': childProxies,
      },
      onProgress: onProgress,
      proxy: proxy,
    );
  }

  static Future<Map<String, dynamic>?> _runRaw(
    String command,
    Map<String, dynamic> args, {
    MotherProgressCallback? onProgress,
    String? proxy,
  }) async {
    final node = await NodeRuntime.findNodeExecutable();
    final cli = await NodeRuntime.findCliPath();
    if (node == null || cli == null) return null;

    final authDir = File(cli).parent.path;
    final nodeModules = Directory('$authDir${Platform.pathSeparator}node_modules');
    if (!nodeModules.existsSync()) return null;

    final payload = Map<String, dynamic>.from(args);
    final proxyTrimmed = proxy?.trim();
    if (proxyTrimmed != null && proxyTrimmed.isNotEmpty) {
      payload['proxy'] = proxyTrimmed;
    }

    try {
      return await _motherCliLock.run(() async {
      final process = await Process.start(
        node,
        [cli, command, jsonEncode(payload)],
        workingDirectory: authDir,
        environment: {
          ...Platform.environment,
          'NODE_NO_WARNINGS': '1',
        },
      );

      final stdoutBuffer = StringBuffer();
      final stderrSub = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('{')) return;
        try {
          final json = jsonDecode(trimmed) as Map<String, dynamic>;
          if (json['type'] == 'progress' && json['message'] is String) {
            final level = json['level'] as String? ?? 'info';
            final message = json['message'] as String;
            final data = json['data'];
            var out = message;
            if (level == 'debug') {
              out = '🔍 $message';
              if (data != null) out = '$out ${jsonEncode(data)}';
            } else if (level == 'warn') {
              out = '⚠ $message';
            }
            onProgress?.call(out);
          }
        } catch (_) {}
      });

      await for (final chunk in process.stdout.transform(utf8.decoder)) {
        stdoutBuffer.write(chunk);
      }

      await stderrSub.cancel();
      final exitCode = await process.exitCode;
      final stdout = stdoutBuffer.toString().trim();

      for (final line in stdout.split('\n').reversed) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('{')) continue;
        try {
          return jsonDecode(trimmed) as Map<String, dynamic>;
        } catch (_) {}
      }
      if (exitCode != 0) {
        onProgress?.call('⚠ CLI завершился с кодом $exitCode');
      } else {
        onProgress?.call('⚠ CLI завершился без JSON-ответа');
      }
      return null;
      });
    } catch (_) {}
    return null;
  }

  static Future<MotherJoinResult> _run(
    String command,
    Map<String, dynamic> args, {
    MotherProgressCallback? onProgress,
    String? proxy,
  }) async {
    final cli = await NodeRuntime.findCliPath();
    if (cli == null) {
      return MotherJoinResult(
        ok: false,
        message: 'Не найден tools/max_auth/cli.mjs',
      );
    }

    final authDir = File(cli).parent.path;
    final nodeModules = Directory('$authDir${Platform.pathSeparator}node_modules');
    if (!nodeModules.existsSync()) {
      return MotherJoinResult(
        ok: false,
        message: 'Не найдены зависимости CLI. Переустановите приложение.',
      );
    }

    if (await NodeRuntime.findNodeExecutable() == null) {
      return MotherJoinResult(
        ok: false,
        message: 'Node.js не найден. Переустановите приложение.',
      );
    }

    try {
      final json = await _runRaw(command, args, onProgress: onProgress, proxy: proxy);
      if (json != null) {
        final result = MotherJoinResult.fromJson(json);
        final invited = result.invited;
        final joined = result.joined;
        final forwarded = result.forwarded;
        String msg;
        if (forwarded > 0 && joined > 0) {
          msg = 'Переслано: $forwarded, вступило: $joined из ${result.total}';
        } else if (forwarded > 0) {
          msg = 'Переслано ссылок: $forwarded из ${result.total}';
        } else if (invited > 0 && joined > 0) {
          msg = 'Групп: $joined, приглашений: $invited из ${result.total}';
        } else if (invited > 0) {
          msg = 'Приглашений: $invited из ${result.total}';
        } else {
          msg = 'Вступило: $joined/${result.total}';
        }
        if (result.failed > 0) {
          msg = '$msg, ошибок: ${result.failed}';
        }
        if (json['error'] != null) {
          return MotherJoinResult(
            ok: false,
            message: json['error'].toString(),
            results: result.results,
            groups: result.groups,
          );
        }
        return MotherJoinResult(
          ok: result.failed == 0,
          message: msg,
          joined: joined,
          invited: invited,
          forwarded: forwarded,
          failed: result.failed,
          total: result.total,
          results: result.results,
          groups: result.groups,
        );
      }

      return MotherJoinResult(
        ok: false,
        message: 'Пустой ответ CLI',
      );
    } catch (e) {
      return MotherJoinResult(ok: false, message: e.toString());
    }
  }
}
