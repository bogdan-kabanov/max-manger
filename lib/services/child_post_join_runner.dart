import '../models/active_action.dart';
import '../models/join_message_template.dart';
import '../models/map_workflow.dart';
import '../models/max_account.dart';
import '../models/rate_settings.dart';
import 'max_ws_service.dart';

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
  static Future<int> runFromJoinResults({
    required List<MaxAccount> tokenChildren,
    required List<Map<String, dynamic>> joinResults,
    List<BroadcastMessageStep> messages = const [],
    JoinMessageTemplate? Function(MaxAccount child)? templateFor,
    String? Function(MaxAccount child)? channelLinkFor,
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
      if (phase != null && phase != 'child_join') continue;
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
    final sharedSteps = messages.where((m) => m.text.trim().isNotEmpty).toList();
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
        steps = t.messages.where((m) => m.text.trim().isNotEmpty).toList();
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
      final ws = MaxWsService();
      ws.onLog = (msg, {String level = 'info'}) {
        if (level == 'error' || level == 'warn') onLog(msg, level: level);
      };

      try {
        await ws.connect(
          token: child.apiToken!,
          deviceId: child.webDeviceId,
          viewerId: child.viewerId,
          targetChats: const [],
          proxyUrl: child.isolation.proxyServer,
        );
        await delayUnlessCancelled(const Duration(milliseconds: 900), token: cancel);
        if (cancel?.isCancelled == true) {
          onLog('[Письмо] остановлено', level: 'warn');
          return sent;
        }

        final chatGapMs = 600;

        for (var c = 0; c < chatIds.length; c++) {
          if (cancel?.isCancelled == true) break;
          final chatId = chatIds[c];
          final label = entry.value
                  .where((e) => e.chatId == chatId)
                  .map((e) => e.title)
                  .firstWhere((t) => t != null && t.trim().isNotEmpty, orElse: () => null) ??
              chatId;
          for (var i = 0; i < steps.length; i++) {
            if (cancel?.isCancelled == true) break;
            final text = resolveMessageText(
              steps[i].text,
              child: child,
              channelLink: channelLink,
            );
            if (text.isEmpty) continue;
            try {
              await ws.sendMessage(chatId, text);
              sent += 1;
              onLog('[Письмо] ✓ «${child.label}» → $label · сообщ. ${i + 1}/${steps.length}');
            } catch (e) {
              onLog('[Письмо] ✗ «${child.label}» → $label: $e', level: 'error');
            }
            if (i < steps.length - 1) {
              final delay = steps[i].delayAfterMs;
              if (delay > 0) {
                await delayUnlessCancelled(Duration(milliseconds: delay), token: cancel);
              }
            }
          }
          if (c < chatIds.length - 1 && chatGapMs > 0) {
            await delayUnlessCancelled(Duration(milliseconds: chatGapMs), token: cancel);
          }
        }
      } catch (e) {
        onLog('[Письмо] «${child.label}» WS: $e', level: 'error');
      } finally {
        await ws.disconnect();
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
      onLog: onLog,
      delayAfterJoinMs: delayBeforeMs,
      rateSettings: rateSettings,
      cancel: cancel,
      onProgress: onProgress,
    );
  }
}
