import '../models/active_action.dart';
import '../models/join_message_template.dart';
import '../models/map_workflow.dart';
import '../models/max_account.dart';
import '../models/rate_settings.dart';
import 'max_mother_service.dart';

typedef ChildPostLog = void Function(String message, {String level});

/// After children join chats, send configured messages via MAX API (WS),
/// without the fragile web autoclicker.
///
/// Callers must pass only non-mother accounts in [tokenChildren] /
/// [children] — mothers must never write to chats.
class ChildPostJoinRunner {
  /// Substitutes join-template placeholders (channel invite from funnel, etc.).
  static String resolveMessageText(
    String raw, {
    required MaxAccount child,
    String? channelLink,
  }) {
    final link = (channelLink ?? '').trim();
    return raw
        .replaceAll('{account}', child.profileDisplayName)
        .replaceAll('{channel_link}', link)
        .replaceAll('{funnel_link}', link)
        .replaceAll('{invite}', link)
        .trim();
  }

  /// [tokenChildren] must be in the same order as CLI `childTokens`
  /// (so `childIndex` from join results maps correctly).
  ///
  /// When [templateFor] is set, each child uses its own template
  /// (messages + delay). Otherwise [messages] / [delayAfterJoinMs] apply to all.
  ///
  /// [channelLinkFor] returns invite URL of the child's funnel channel
  /// (`AccountChannelPolicy.lastCreatedInviteUrl`) for `{channel_link}`.
  ///
  /// [onChatsSent] is called once per child with chatIds that got ≥1 successful send.
  static Future<int> runFromJoinResults({
    required List<MaxAccount> tokenChildren,
    required List<Map<String, dynamic>> joinResults,
    List<BroadcastMessageStep> messages = const [],
    JoinMessageTemplate? Function(MaxAccount child)? templateFor,
    String? Function(MaxAccount child)? channelLinkFor,
    Future<void> Function(
      MaxAccount child,
      List<String> chatIds, {
      Map<String, List<String>> messageIdsByChatId,
      Map<String, String> titleByChatId,
    })? onChatsSent,
    required ChildPostLog onLog,
    int delayAfterJoinMs = 5000,
    RateSettings rateSettings = RateSettings.defaults,
    ActionCancelToken? cancel,
    void Function(String message, {int? done, int? total})? onProgress,
  }) async {
    if (tokenChildren.isEmpty) return 0;

    final jobs = <({MaxAccount child, String chatId, String? title})>[];
    for (final row in joinResults) {
      if (row['ok'] != true) continue;
      final phase = row['phase']?.toString();
      if (phase != null && phase != 'child_join' && phase != 'join') continue;
      final chatId = row['chatId']?.toString().trim() ?? '';
      if (chatId.isEmpty) continue;

      MaxAccount? child;
      final idx = (row['childIndex'] as num?)?.toInt();
      if (idx != null && idx >= 0 && idx < tokenChildren.length) {
        child = tokenChildren[idx];
      } else {
        final userId = row['childUserId'];
        if (userId != null) {
          for (final a in tokenChildren) {
            if (a.viewerId != null && a.viewerId.toString() == userId.toString()) {
              child = a;
              break;
            }
          }
        }
      }
      // Solo mother join: phase=join without childUserId → единственный аккаунт в списке.
      if (child == null && phase == 'join' && tokenChildren.length == 1) {
        child = tokenChildren.first;
      }
      if (child == null) continue;

      jobs.add((
        child: child,
        chatId: chatId,
        title: row['title']?.toString(),
      ));
    }

    if (jobs.isEmpty) {
      onLog('[Письмо] нет успешных вступлений с chatId — писать некуда', level: 'warn');
      return 0;
    }

    final byChild = <String, List<({String chatId, String? title})>>{};
    for (final job in jobs) {
      byChild.putIfAbsent(job.child.id, () => []).add((chatId: job.chatId, title: job.title));
    }

    // Resolve shared fallback or per-child templates.
    final sharedSteps = messages.where((m) => m.hasContent).toList();
    var anyActive = sharedSteps.isNotEmpty;
    if (templateFor != null) {
      for (final childId in byChild.keys) {
        final child = tokenChildren.firstWhere((a) => a.id == childId);
        final t = templateFor(child);
        if (t != null && t.isActive) {
          anyActive = true;
          break;
        }
      }
    }
    if (!anyActive) {
      onLog('[Письмо] нет активных шаблонов/сообщений — пропуск', level: 'warn');
      return 0;
    }

    onLog('[Письмо] дочерние напишут в ${jobs.length} чат(ов)');
    onProgress?.call('Старт…', done: 0, total: byChild.length);

    // Global pause: max of shared delay and per-child template delays.
    var pauseMs = sharedSteps.isNotEmpty ? delayAfterJoinMs : 0;
    if (templateFor != null) {
      for (final childId in byChild.keys) {
        final child = tokenChildren.firstWhere((a) => a.id == childId);
        final t = templateFor(child);
        if (t != null && t.isActive && t.delayMs > pauseMs) {
          pauseMs = t.delayMs;
        }
      }
    }
    if (pauseMs > 0) {
      onLog('[Письмо] пауза после вступления ${pauseMs}мс…');
      await delayUnlessCancelled(Duration(milliseconds: pauseMs), token: cancel);
    }

    if (cancel?.isCancelled == true) {
      onLog('[Письмо] остановлено', level: 'warn');
      return 0;
    }

    var sent = 0;
    var childDone = 0;

    for (final entry in byChild.entries) {
      if (cancel?.isCancelled == true) {
        onLog('[Письмо] остановлено', level: 'warn');
        onProgress?.call('Остановлено', done: childDone, total: byChild.length);
        return sent;
      }

      final child = tokenChildren.firstWhere((a) => a.id == entry.key);
      if (!child.hasApiSession) {
        onLog('[Письмо] «${child.label}» без токена — пропуск', level: 'warn');
        childDone += 1;
        continue;
      }

      List<BroadcastMessageStep> steps;
      if (templateFor != null) {
        final t = templateFor(child);
        if (t == null || !t.isActive) {
          onLog('[Письмо] «${child.label}» без шаблона — пропуск');
          childDone += 1;
          continue;
        }
        steps = t.messages.where((m) => m.hasContent).toList();
      } else {
        steps = sharedSteps;
      }
      if (steps.isEmpty) {
        childDone += 1;
        continue;
      }

      final channelLink = channelLinkFor?.call(child)?.trim() ?? '';
      final needsAnyLink = steps.any(
        (s) =>
            s.text.contains('{channel_link}') ||
            s.text.contains('{funnel_link}') ||
            s.text.contains('{invite}'),
      );
      if (needsAnyLink && channelLink.isEmpty) {
        onLog(
          '[Письмо] «${child.label}» — нет ссылки канала воронки '
          '({channel_link}). Сначала запустите воронку для этого аккаунта — '
          'без ссылки рассылка не стартует.',
          level: 'error',
        );
        childDone += 1;
        continue;
      }

      final chatIds = entry.value.map((e) => e.chatId).toSet().toList();
      final batch = <Map<String, dynamic>>[];
      final chatGapMs = (() {
        if (templateFor != null) {
          final t = templateFor(child);
          if (t != null && t.chatGapMs > 0) return t.chatGapMs;
        }
        return 600;
      })();

      for (var ci = 0; ci < chatIds.length; ci++) {
        final chatId = chatIds[ci];
        final label = entry.value
                .where((e) => e.chatId == chatId)
                .map((e) => e.title)
                .firstWhere((t) => t != null && t.trim().isNotEmpty, orElse: () => null) ??
            chatId;
        for (var i = 0; i < steps.length; i++) {
          final text = resolveMessageText(
            steps[i].text,
            child: child,
            channelLink: channelLink,
          );
          final media = steps[i].mediaPath?.trim();
          if (text.isEmpty && (media == null || media.isEmpty)) continue;
          final isLastOfChat = i == steps.length - 1 ||
              steps.skip(i + 1).every((s) => !s.hasContent);
          final delayAfter = !isLastOfChat
              ? (steps[i].delayAfterMs > 0 ? steps[i].delayAfterMs : 600)
              : (ci < chatIds.length - 1 ? chatGapMs : 600);
          batch.add({
            'chatId': chatId,
            'title': label,
            'text': text,
            if (media != null && media.isNotEmpty) 'mediaPath': media,
            'delayMs': delayAfter > 0 ? delayAfter : 600,
          });
        }
      }
      if (batch.isEmpty) {
        childDone += 1;
        continue;
      }

      onLog('[Письмо] «${child.label}» → ${chatIds.length} чат(ов), сообщ. ${batch.length}');
      try {
        final result = await MaxMotherService.sendChatMessages(
          token: child.apiToken!,
          messages: batch,
          proxy: child.isolation.proxyServer,
          cancel: cancel,
          onProgress: (msg) {
            if (msg.contains('✓') || msg.contains('✗') || msg.startsWith('⚠')) {
              onLog(msg, level: msg.contains('✗') || msg.startsWith('⚠') ? 'warn' : 'info');
            }
          },
        );
        if (cancel?.isCancelled == true) {
          onLog('[Письмо] остановлено', level: 'warn');
          return sent;
        }
        sent += result.sent;
        if (!result.ok && result.sent == 0) {
          onLog(
            '[Письмо] «${child.label}»: ${result.message}',
            level: 'error',
          );
        } else {
          onLog('[Письмо] «${child.label}»: отправлено ${result.sent}/${batch.length}');
        }
        if (onChatsSent != null && result.results.isNotEmpty) {
          final okChats = <String>{};
          final messageIdsByChatId = <String, List<String>>{};
          final titleByChatId = <String, String>{};
          for (final row in result.results) {
            if (row['ok'] != true) continue;
            final id = row['chatId']?.toString().trim() ?? '';
            if (id.isEmpty) continue;
            okChats.add(id);
            final mid = row['messageId']?.toString().trim() ?? '';
            if (mid.isNotEmpty) {
              messageIdsByChatId.putIfAbsent(id, () => []).add(mid);
            }
            final title = row['title']?.toString().trim() ?? '';
            if (title.isNotEmpty) titleByChatId[id] = title;
          }
          if (okChats.isNotEmpty) {
            await onChatsSent(
              child,
              okChats.toList(),
              messageIdsByChatId: messageIdsByChatId,
              titleByChatId: titleByChatId,
            );
          }
        }
      } catch (e) {
        onLog('[Письмо] «${child.label}»: $e', level: 'error');
      }

      childDone += 1;
      onProgress?.call('«${child.label}»', done: childDone, total: byChild.length);
    }

    if (cancel?.isCancelled == true) {
      onLog('[Письмо] остановлено (отправлено $sent)', level: 'warn');
    } else if (sent == 0) {
      onLog('[Письмо] ничего не отправлено — проверьте токены, каналы и {channel_link}', level: 'error');
    } else {
      onLog('[Письмо] готово: отправлено $sent');
    }
    return sent;
  }

  /// Write into known chatIds (already joined) without a join step.
  /// Same [chatIds] for every account in [children].
  static Future<int> runToChatIds({
    required List<MaxAccount> children,
    required List<String> chatIds,
    List<BroadcastMessageStep> messages = const [],
    JoinMessageTemplate? Function(MaxAccount child)? templateFor,
    String? Function(MaxAccount child)? channelLinkFor,
    Future<void> Function(
      MaxAccount child,
      List<String> chatIds, {
      Map<String, List<String>> messageIdsByChatId,
      Map<String, String> titleByChatId,
    })? onChatsSent,
    required ChildPostLog onLog,
    int delayBeforeMs = 0,
    RateSettings rateSettings = RateSettings.defaults,
    ActionCancelToken? cancel,
    void Function(String message, {int? done, int? total})? onProgress,
  }) async {
    final byAccount = <String, List<String>>{
      for (final child in children.where((a) => a.hasApiSession))
        child.id: chatIds.where((id) => id.trim().isNotEmpty).toList(),
    };
    return runPerAccountChats(
      children: children,
      chatIdsByAccountId: byAccount,
      messages: messages,
      templateFor: templateFor,
      channelLinkFor: channelLinkFor,
      onChatsSent: onChatsSent,
      onLog: onLog,
      delayBeforeMs: delayBeforeMs,
      rateSettings: rateSettings,
      cancel: cancel,
      onProgress: onProgress,
    );
  }

  /// Each account writes into its own list of chatIds.
  static Future<int> runPerAccountChats({
    required List<MaxAccount> children,
    required Map<String, List<String>> chatIdsByAccountId,
    List<BroadcastMessageStep> messages = const [],
    JoinMessageTemplate? Function(MaxAccount child)? templateFor,
    String? Function(MaxAccount child)? channelLinkFor,
    Future<void> Function(
      MaxAccount child,
      List<String> chatIds, {
      Map<String, List<String>> messageIdsByChatId,
      Map<String, String> titleByChatId,
    })? onChatsSent,
    required ChildPostLog onLog,
    int delayBeforeMs = 0,
    RateSettings rateSettings = RateSettings.defaults,
    ActionCancelToken? cancel,
    void Function(String message, {int? done, int? total})? onProgress,
  }) async {
    final fakeResults = <Map<String, dynamic>>[];
    final tokenChildren = children.where((a) => a.hasApiSession).toList();
    for (var i = 0; i < tokenChildren.length; i++) {
      final chats = chatIdsByAccountId[tokenChildren[i].id] ?? const <String>[];
      for (final chatId in chats) {
        if (chatId.trim().isEmpty) continue;
        fakeResults.add({
          'ok': true,
          'phase': 'child_join',
          'childIndex': i,
          'chatId': chatId.trim(),
        });
      }
    }
    if (fakeResults.isEmpty) {
      onLog('[Письмо] нет чатов для отправки', level: 'warn');
      return 0;
    }
    return runFromJoinResults(
      tokenChildren: tokenChildren,
      joinResults: fakeResults,
      messages: messages,
      templateFor: templateFor,
      channelLinkFor: channelLinkFor,
      onChatsSent: onChatsSent,
      onLog: onLog,
      delayAfterJoinMs: delayBeforeMs,
      rateSettings: rateSettings,
      cancel: cancel,
      onProgress: onProgress,
    );
  }
}
