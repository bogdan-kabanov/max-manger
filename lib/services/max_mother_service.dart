import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/active_action.dart';
import '../models/chat_history_message.dart';
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
    ActionCancelToken? cancel,
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
      cancel: cancel,
    );
  }

  static Future<MotherGroupsResult> listMotherGroups({
    required String token,
    bool scanMessages = true,
    String? proxy,
    MotherProgressCallback? onProgress,
    ActionCancelToken? cancel,
  }) async {
    final json = await _runRaw(
      'list-groups',
      {
        'token': token,
        'scanMessages': scanMessages,
      },
      onProgress: onProgress,
      proxy: proxy,
      cancel: cancel,
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
    /// chats = можно писать, channels = лента, all = оба
    String kind = 'chats',
    String? proxy,
    MotherProgressCallback? onProgress,
    ActionCancelToken? cancel,
  }) async {
    final json = await _runRaw(
      'discover-channels',
      {
        'token': token,
        'count': count,
        'kind': kind,
        if (topics.isNotEmpty) 'topics': topics,
        if (excludeHashes.isNotEmpty) 'excludeHashes': excludeHashes,
        if (excludeChatIds.isNotEmpty) 'excludeChatIds': excludeChatIds,
      },
      onProgress: onProgress,
      proxy: proxy,
      cancel: cancel,
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
    ActionCancelToken? cancel,
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
      cancel: cancel,
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
    ActionCancelToken? cancel,
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
      cancel: cancel,
    );
  }

  static Future<MotherJoinResult> leaveGroups({
    required String token,
    required List<String> chatIds,
    int delayMs = 2500,
    String? proxy,
    MotherProgressCallback? onProgress,
    ActionCancelToken? cancel,
  }) async {
    final ids = [...{...chatIds.map((id) => id.trim()).where((id) => id.isNotEmpty)}];
    if (ids.isEmpty) {
      return MotherJoinResult(ok: false, message: 'Не выбраны каналы для выхода');
    }

    final json = await _runRaw(
      'leave-groups',
      {
        'token': token,
        'chatIds': ids,
        'delayMs': delayMs,
      },
      onProgress: onProgress,
      proxy: proxy,
      cancel: cancel,
    );
    if (json == null) {
      return MotherJoinResult(
        ok: false,
        message: cancel?.isCancelled == true ? 'Остановлено пользователем' : 'Пустой ответ CLI',
      );
    }
    if (json['cancelled'] == true || cancel?.isCancelled == true) {
      return MotherJoinResult(ok: false, message: 'Остановлено пользователем');
    }
    if (json['error'] != null) {
      return MotherJoinResult(ok: false, message: json['error'].toString());
    }

    final results = (json['results'] as List<dynamic>?)
            ?.whereType<Map<String, dynamic>>()
            .toList() ??
        const [];
    final left = json['left'] as int? ?? results.where((r) => r['ok'] == true).length;
    final failed = json['failed'] as int? ?? results.where((r) => r['ok'] != true).length;
    final total = json['total'] as int? ?? ids.length;
    var msg = 'Вышло: $left/$total';
    if (failed > 0) msg = '$msg, ошибок: $failed';

    return MotherJoinResult(
      ok: failed == 0,
      message: msg,
      joined: left,
      failed: failed,
      total: total,
      results: results,
    );
  }

  /// Mother invites children: inviteUsers → forward link → child join (cascade).
  static Future<MotherJoinResult> inviteChildren({
    required String motherToken,
    required List<String> links,
    List<Map<String, dynamic>> groups = const [],
    List<String> chatIds = const [],
    required List<int> inviteUserIds,
    List<Map<String, dynamic>> childTargets = const [],
    List<String> childTokens = const [],
    int delayMs = 2500,
    String? proxy,
    MotherProgressCallback? onProgress,
    ActionCancelToken? cancel,
  }) async {
    return _run(
      'invite-children',
      {
        'token': motherToken,
        'links': links,
        if (groups.isNotEmpty) 'groups': groups,
        if (chatIds.isNotEmpty) 'chatIds': chatIds,
        'inviteUserIds': inviteUserIds,
        if (childTargets.isNotEmpty) 'childTargets': childTargets,
        if (childTokens.isNotEmpty) 'childTokens': childTokens,
        'delayMs': delayMs,
      },
      onProgress: onProgress,
      proxy: proxy,
      cancel: cancel,
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
    ActionCancelToken? cancel,
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
      cancel: cancel,
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
    ActionCancelToken? cancel,
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
      cancel: cancel,
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
    ActionCancelToken? cancel,
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
      cancel: cancel,
    );
  }

  static Future<Map<String, dynamic>?> _runRaw(
    String command,
    Map<String, dynamic> args, {
    MotherProgressCallback? onProgress,
    String? proxy,
    ActionCancelToken? cancel,
  }) async {
    if (cancel?.isCancelled == true) {
      onProgress?.call('⏹ Остановлено');
      return {'ok': false, 'error': 'Остановлено пользователем', 'cancelled': true};
    }

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
      onProgress?.call('CLI: $command…');
      return await _motherCliLock.run(() async {
      if (cancel?.isCancelled == true) {
        onProgress?.call('⏹ Остановлено');
        return {'ok': false, 'error': 'Остановлено пользователем', 'cancelled': true};
      }

      final encoded = jsonEncode(payload);
      // Prefer args file: Windows CreateProcess ~32k; 100+ invite links overflow argv.
      final useArgsFile = true;

      File? argsFile;
      late final List<String> processArgs;
      if (useArgsFile) {
        argsFile = File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'max_cli_${command}_${DateTime.now().microsecondsSinceEpoch}.json',
        );
        await argsFile.writeAsString(encoded);
        processArgs = [cli, command, '@${argsFile.path}'];
        onProgress?.call('CLI: аргументы через файл (${encoded.length} байт)');
      } else {
        processArgs = [cli, command, encoded];
      }

      try {
        final process = await Process.start(
          node,
          processArgs,
          workingDirectory: authDir,
          environment: {
            ...Platform.environment,
            'NODE_NO_WARNINGS': '1',
          },
        );
        cancel?.attachProcess(process);

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

        if (cancel?.isCancelled == true) {
          onProgress?.call('⏹ Остановлено');
          return {'ok': false, 'error': 'Остановлено пользователем', 'cancelled': true};
        }

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
      } finally {
        if (argsFile != null) {
          try {
            await argsFile.delete();
          } catch (_) {}
        }
      }
      });
    } catch (e) {
      onProgress?.call('⚠ Не удалось запустить CLI: $e');
    }
    return null;
  }

  static Future<MotherJoinResult> _run(
    String command,
    Map<String, dynamic> args, {
    MotherProgressCallback? onProgress,
    String? proxy,
    ActionCancelToken? cancel,
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
      final json = await _runRaw(
        command,
        args,
        onProgress: onProgress,
        proxy: proxy,
        cancel: cancel,
      );
      if (json != null) {
        if (json['cancelled'] == true || cancel?.isCancelled == true) {
          return MotherJoinResult(
            ok: false,
            message: 'Остановлено пользователем',
            results: (json['results'] as List<dynamic>?)
                    ?.whereType<Map<String, dynamic>>()
                    .toList() ??
                const [],
          );
        }
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

      if (cancel?.isCancelled == true) {
        return MotherJoinResult(ok: false, message: 'Остановлено пользователем');
      }

      return MotherJoinResult(
        ok: false,
        message: 'Пустой ответ CLI',
      );
    } catch (e) {
      return MotherJoinResult(ok: false, message: e.toString());
    }
  }

  /// Create channel + optional description/posts for one account token.
  static Future<FunnelSetupResult> funnelSetup({
    required String token,
    required String title,
    String? description,
    String? photoPath,
    List<Map<String, dynamic>> posts = const [],
    bool publish = true,
    bool privateChannel = false,
    bool commentsEnabled = true,
    String? proxy,
    MotherProgressCallback? onProgress,
    ActionCancelToken? cancel,
  }) async {
    final json = await _runRaw(
      'funnel-setup',
      {
        'token': token,
        'title': title,
        if (description != null && description.trim().isNotEmpty)
          'description': description.trim(),
        if (photoPath != null && photoPath.trim().isNotEmpty) 'photoPath': photoPath.trim(),
        'posts': posts,
        'publish': publish,
        'privateChannel': privateChannel,
        'commentsEnabled': commentsEnabled,
      },
      onProgress: onProgress,
      proxy: proxy,
      cancel: cancel,
    );
    if (json == null) {
      return FunnelSetupResult(
        ok: false,
        message: cancel?.isCancelled == true ? 'Остановлено пользователем' : 'CLI не ответил',
      );
    }
    if (json['cancelled'] == true || cancel?.isCancelled == true) {
      return FunnelSetupResult(ok: false, message: 'Остановлено пользователем');
    }
    if (json['ok'] != true) {
      return FunnelSetupResult(
        ok: false,
        message: json['error']?.toString() ?? 'Не удалось создать канал',
      );
    }
    return FunnelSetupResult.fromJson(json);
  }

  /// Publish posts into an existing channel (no create).
  static Future<FunnelPublishResult> funnelPublish({
    required String token,
    required String chatId,
    List<Map<String, dynamic>> posts = const [],
    String? proxy,
    MotherProgressCallback? onProgress,
    ActionCancelToken? cancel,
  }) async {
    final json = await _runRaw(
      'funnel-publish',
      {
        'token': token,
        'chatId': chatId,
        'posts': posts,
      },
      onProgress: onProgress,
      proxy: proxy,
      cancel: cancel,
    );
    if (json == null) {
      return FunnelPublishResult(
        ok: false,
        message: cancel?.isCancelled == true ? 'Остановлено пользователем' : 'CLI не ответил',
      );
    }
    if (json['cancelled'] == true || cancel?.isCancelled == true) {
      return FunnelPublishResult(ok: false, message: 'Остановлено пользователем');
    }
    if (json['ok'] != true) {
      return FunnelPublishResult(
        ok: false,
        message: json['error']?.toString() ?? 'Не удалось опубликовать',
      );
    }
    return FunnelPublishResult.fromJson(json);
  }

  /// Invite URL for an existing funnel/owned channel (discovers CHANNEL if [chatId] null).
  static Future<ChannelInviteResolveResult> resolveChannelInvite({
    required String token,
    String? chatId,
    String? proxy,
    MotherProgressCallback? onProgress,
    ActionCancelToken? cancel,
  }) async {
    final json = await _runRaw(
      'resolve-channel-invite',
      {
        'token': token,
        if (chatId != null && chatId.trim().isNotEmpty) 'chatId': chatId.trim(),
      },
      onProgress: onProgress,
      proxy: proxy,
      cancel: cancel,
    );
    if (json == null) {
      return ChannelInviteResolveResult(
        ok: false,
        message: cancel?.isCancelled == true ? 'Остановлено пользователем' : 'CLI не ответил',
      );
    }
    if (json['cancelled'] == true || cancel?.isCancelled == true) {
      return ChannelInviteResolveResult(ok: false, message: 'Остановлено пользователем');
    }
    if (json['ok'] != true && json['error'] != null) {
      return ChannelInviteResolveResult(
        ok: false,
        message: json['error'].toString(),
      );
    }
    final inviteUrl = (json['inviteUrl'] as String?)?.trim();
    if (inviteUrl == null || inviteUrl.isEmpty) {
      return ChannelInviteResolveResult(
        ok: false,
        message: json['error']?.toString() ?? 'Нет invite-ссылки',
      );
    }
    return ChannelInviteResolveResult(
      ok: true,
      message: 'OK',
      chatId: json['chatId']?.toString(),
      title: json['title']?.toString(),
      inviteHash: json['inviteHash']?.toString(),
      inviteUrl: inviteUrl,
    );
  }

  /// Send texts into chats via Node CLI (same proxy path as list-groups).
  /// Prefer this over Dart [MaxWsService] when accounts use HTTP/SOCKS proxies.
  static Future<SendChatMessagesResult> sendChatMessages({
    required String token,
    required List<Map<String, dynamic>> messages,
    String? proxy,
    MotherProgressCallback? onProgress,
    ActionCancelToken? cancel,
  }) async {
    if (messages.isEmpty) {
      return SendChatMessagesResult(ok: true, sent: 0, message: 'Нет сообщений');
    }
    final json = await _runRaw(
      'send-chat-messages',
      {
        'token': token,
        'messages': messages,
      },
      onProgress: onProgress,
      proxy: proxy,
      cancel: cancel,
    );
    if (json == null) {
      return SendChatMessagesResult(
        ok: false,
        sent: 0,
        message: cancel?.isCancelled == true ? 'Остановлено пользователем' : 'CLI не ответил',
      );
    }
    if (json['cancelled'] == true || cancel?.isCancelled == true) {
      return SendChatMessagesResult(ok: false, sent: 0, message: 'Остановлено пользователем');
    }
    if (json['ok'] != true) {
      return SendChatMessagesResult(
        ok: false,
        sent: (json['sent'] as num?)?.toInt() ?? 0,
        message: json['error']?.toString() ?? 'Ошибка отправки',
      );
    }
    return SendChatMessagesResult(
      ok: true,
      sent: (json['sent'] as num?)?.toInt() ?? 0,
      message: 'OK',
      results: (json['results'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(),
    );
  }

  static Future<DeleteChatMessagesResult> deleteChatMessages({
    required String token,
    required List<Map<String, dynamic>> items,
    bool forMe = false,
    String? proxy,
    MotherProgressCallback? onProgress,
    ActionCancelToken? cancel,
  }) async {
    if (items.isEmpty) {
      return DeleteChatMessagesResult(ok: true, deleted: 0, message: 'Нет сообщений');
    }
    final json = await _runRaw(
      'delete-chat-messages',
      {
        'token': token,
        'items': items,
        'forMe': forMe,
      },
      onProgress: onProgress,
      proxy: proxy,
      cancel: cancel,
    );
    if (json == null) {
      return DeleteChatMessagesResult(
        ok: false,
        deleted: 0,
        message: cancel?.isCancelled == true ? 'Остановлено пользователем' : 'CLI не ответил',
      );
    }
    if (json['cancelled'] == true || cancel?.isCancelled == true) {
      return DeleteChatMessagesResult(ok: false, deleted: 0, message: 'Остановлено пользователем');
    }
    if (json['ok'] != true) {
      return DeleteChatMessagesResult(
        ok: false,
        deleted: (json['deleted'] as num?)?.toInt() ?? 0,
        message: json['error']?.toString() ?? 'Ошибка удаления',
      );
    }
    return DeleteChatMessagesResult(
      ok: true,
      deleted: (json['deleted'] as num?)?.toInt() ?? 0,
      message: 'OK',
      results: (json['results'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(),
    );
  }

  static Future<ListChatMessagesResult> listChatMessages({
    required String token,
    required String chatId,
    int limit = 50,
    int? from,
    String? proxy,
    MotherProgressCallback? onProgress,
    ActionCancelToken? cancel,
  }) async {
    final json = await _runRaw(
      'list-chat-messages',
      {
        'token': token,
        'chatId': chatId,
        'backward': limit,
        if (from != null) 'from': from,
      },
      onProgress: onProgress,
      proxy: proxy,
      cancel: cancel,
    );
    if (json == null) {
      return ListChatMessagesResult(
        ok: false,
        message: cancel?.isCancelled == true ? 'Остановлено' : 'CLI не ответил',
      );
    }
    if (json['ok'] != true) {
      return ListChatMessagesResult(
        ok: false,
        message: json['error']?.toString() ?? 'Ошибка загрузки',
      );
    }
    final rawList = (json['rawMessages'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final rawById = <String, Map<String, dynamic>>{
      for (final r in rawList)
        if ((r['id'] ?? r['messageId']) != null)
          (r['id'] ?? r['messageId']).toString(): r,
    };
    final messages = (json['messages'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((e) {
          final map = Map<String, dynamic>.from(e);
          final id = (map['id'] ?? '').toString();
          return ChatHistoryMessage.fromJson({
            ...map,
            'chatId': map['chatId'] ?? chatId,
            if (rawById[id] != null) 'raw': rawById[id],
          });
        })
        .where((m) => m.id.isNotEmpty)
        .toList();
    return ListChatMessagesResult(
      ok: true,
      message: 'OK',
      chatId: json['chatId']?.toString() ?? chatId,
      messages: messages,
    );
  }

  static Future<ForwardChatMessagesResult> forwardChatMessages({
    required String token,
    required String sourceChatId,
    required List<String> targetChatIds,
    required List<String> messageIds,
    List<Map<String, dynamic>> rawMessages = const [],
    String comment = '',
    int delayMs = 800,
    String? proxy,
    MotherProgressCallback? onProgress,
    ActionCancelToken? cancel,
  }) async {
    if (targetChatIds.isEmpty || (messageIds.isEmpty && rawMessages.isEmpty)) {
      return ForwardChatMessagesResult(
        ok: false,
        forwarded: 0,
        copied: 0,
        message: 'Нет целей или сообщений',
      );
    }
    final json = await _runRaw(
      'forward-chat-messages',
      {
        'token': token,
        'sourceChatId': sourceChatId,
        'targetChatIds': targetChatIds,
        'messageIds': messageIds,
        if (rawMessages.isNotEmpty) 'rawMessages': rawMessages,
        if (comment.trim().isNotEmpty) 'comment': comment.trim(),
        'delayMs': delayMs,
      },
      onProgress: onProgress,
      proxy: proxy,
      cancel: cancel,
    );
    if (json == null) {
      return ForwardChatMessagesResult(
        ok: false,
        forwarded: 0,
        copied: 0,
        message: cancel?.isCancelled == true ? 'Остановлено' : 'CLI не ответил',
      );
    }
    if (json['ok'] != true) {
      return ForwardChatMessagesResult(
        ok: false,
        forwarded: (json['forwarded'] as num?)?.toInt() ?? 0,
        copied: (json['copied'] as num?)?.toInt() ?? 0,
        message: json['error']?.toString() ?? 'Ошибка пересылки',
        results: (json['results'] as List<dynamic>? ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(),
      );
    }
    return ForwardChatMessagesResult(
      ok: true,
      forwarded: (json['forwarded'] as num?)?.toInt() ?? 0,
      copied: (json['copied'] as num?)?.toInt() ?? 0,
      message: 'OK',
      results: (json['results'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(),
    );
  }
}

class SendChatMessagesResult {
  SendChatMessagesResult({
    required this.ok,
    required this.sent,
    required this.message,
    this.results = const [],
  });

  final bool ok;
  final int sent;
  final String message;
  final List<Map<String, dynamic>> results;
}

class DeleteChatMessagesResult {
  DeleteChatMessagesResult({
    required this.ok,
    required this.deleted,
    required this.message,
    this.results = const [],
  });

  final bool ok;
  final int deleted;
  final String message;
  final List<Map<String, dynamic>> results;
}

class ListChatMessagesResult {
  ListChatMessagesResult({
    required this.ok,
    required this.message,
    this.chatId,
    this.messages = const [],
  });

  final bool ok;
  final String message;
  final String? chatId;
  final List<ChatHistoryMessage> messages;
}

class ForwardChatMessagesResult {
  ForwardChatMessagesResult({
    required this.ok,
    required this.forwarded,
    required this.copied,
    required this.message,
    this.results = const [],
  });

  final bool ok;
  final int forwarded;
  final int copied;
  final String message;
  final List<Map<String, dynamic>> results;

  int get failed => results.where((r) => r['ok'] != true).length;
}

class ChannelInviteResolveResult {
  ChannelInviteResolveResult({
    required this.ok,
    required this.message,
    this.chatId,
    this.title,
    this.inviteHash,
    this.inviteUrl,
  });

  final bool ok;
  final String message;
  final String? chatId;
  final String? title;
  final String? inviteHash;
  final String? inviteUrl;
}

class FunnelSetupResult {
  FunnelSetupResult({
    required this.ok,
    required this.message,
    this.chatId,
    this.title,
    this.postsSent = 0,
    this.inviteHash,
    this.inviteUrl,
    this.descriptionApplied = false,
    this.avatarApplied = false,
  });

  final bool ok;
  final String message;
  final String? chatId;
  final String? title;
  final int postsSent;
  final String? inviteHash;
  final String? inviteUrl;
  final bool descriptionApplied;
  final bool avatarApplied;

  factory FunnelSetupResult.fromJson(Map<String, dynamic> json) {
    return FunnelSetupResult(
      ok: json['ok'] == true,
      message: json['error']?.toString() ?? 'Готово',
      chatId: json['chatId']?.toString(),
      title: json['title']?.toString(),
      postsSent: json['postsSent'] as int? ?? 0,
      inviteHash: json['inviteHash']?.toString(),
      inviteUrl: json['inviteUrl']?.toString(),
      descriptionApplied: json['descriptionApplied'] == true,
      avatarApplied: json['avatarApplied'] == true,
    );
  }
}

class FunnelPublishResult {
  FunnelPublishResult({
    required this.ok,
    required this.message,
    this.chatId,
    this.postsSent = 0,
    this.photoFailures = 0,
    this.inviteUrl,
  });

  final bool ok;
  final String message;
  final String? chatId;
  final int postsSent;
  final int photoFailures;
  final String? inviteUrl;

  factory FunnelPublishResult.fromJson(Map<String, dynamic> json) {
    return FunnelPublishResult(
      ok: json['ok'] == true,
      message: json['error']?.toString() ?? 'Готово',
      chatId: json['chatId']?.toString(),
      postsSent: json['postsSent'] as int? ?? 0,
      photoFailures: json['photoFailures'] as int? ?? 0,
      inviteUrl: json['inviteUrl']?.toString(),
    );
  }
}
