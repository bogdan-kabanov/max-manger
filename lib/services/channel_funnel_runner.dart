import '../models/account_map_state.dart';
import '../models/active_action.dart';
import '../models/channel_funnel.dart';
import '../models/max_account.dart';
import 'max_mother_service.dart';

typedef FunnelLog = void Function(String message, {String level});

class FunnelRunSummary {
  FunnelRunSummary({
    required this.ok,
    required this.processed,
    required this.succeeded,
    required this.failed,
    this.message = '',
    this.cancelled = false,
  });

  final bool ok;
  final int processed;
  final int succeeded;
  final int failed;
  final String message;
  final bool cancelled;
}

/// Resolves templates and runs funnel-setup for assigned accounts.
class ChannelFunnelRunner {
  String resolveTemplate(
    String template, {
    required MaxAccount account,
    MotherCluster? cluster,
    required int index,
    String? channelLink,
  }) {
    final now = DateTime.now();
    final date =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final link = (channelLink ?? '').trim();
    return template
        .replaceAll('{account}', account.profileDisplayName)
        .replaceAll('{n}', '$index')
        .replaceAll('{cluster}', cluster?.name ?? '')
        .replaceAll('{date}', date)
        .replaceAll('{channel_link}', link)
        .replaceAll('{funnel_link}', link)
        .replaceAll('{invite}', link)
        .trim();
  }

  Future<FunnelRunSummary> run({
    required ChannelFunnel funnel,
    required List<MaxAccount> accounts,
    required List<MotherCluster> clusters,
    required AccountChannelPolicy Function(String accountId) policyFor,
    required Future<void> Function(AccountChannelPolicy policy) savePolicy,
    required FunnelLog onLog,
    ActionCancelToken? cancel,
    void Function(String message, {int? done, int? total})? onProgress,
  }) async {
    final targets = <MaxAccount>[];
    for (final account in accounts) {
      final policy = policyFor(account.id);
      if (!policy.canCreateChannels) continue;
      if (!policy.funnelIds.contains(funnel.id)) continue;
      if (!account.hasApiSession) {
        onLog(
          '[Воронка] «${account.profileDisplayName}» — нет токена, пропуск',
          level: 'warn',
        );
        continue;
      }
      targets.add(account);
    }

    if (targets.isEmpty) {
      onLog(
        '[Воронка] «${funnel.name}» — нет аккаунтов с правом создания и этой воронкой',
        level: 'warn',
      );
      return FunnelRunSummary(
        ok: false,
        processed: 0,
        succeeded: 0,
        failed: 0,
        message: 'Нет подходящих аккаунтов',
      );
    }

    onLog(
      '[Воронка] «${funnel.name}» — старт для ${targets.length} акк., '
      'постов: ${funnel.publicationCount}',
    );
    onProgress?.call('Старт…', done: 0, total: targets.length);

    var okCount = 0;
    var failCount = 0;
    var processed = 0;

    for (var i = 0; i < targets.length; i++) {
      if (cancel?.isCancelled == true) {
        onLog('[Воронка] «${funnel.name}» — остановлено', level: 'warn');
        onProgress?.call('Остановлено', done: processed, total: targets.length);
        return FunnelRunSummary(
          ok: false,
          processed: processed,
          succeeded: okCount,
          failed: failCount,
          message: 'Остановлено пользователем',
          cancelled: true,
        );
      }

      final account = targets[i];
      MotherCluster? cluster;
      for (final c in clusters) {
        if (c.motherAccountId == account.id || c.childAccountIds.contains(account.id)) {
          cluster = c;
          break;
        }
      }

      final existingPolicy = policyFor(account.id);
      final existingChatId = existingPolicy.lastCreatedChatId?.trim();
      final hasExistingChannel = existingChatId != null && existingChatId.isNotEmpty;

      final title = resolveTemplate(
        funnel.channelTitle,
        account: account,
        cluster: cluster,
        index: i + 1,
      );
      final aboutRaw = funnel.channelDescription?.trim();
      final about = (aboutRaw == null || aboutRaw.isEmpty)
          ? null
          : resolveTemplate(
              aboutRaw,
              account: account,
              cluster: cluster,
              index: i + 1,
            );

      final channelLink = existingPolicy.lastCreatedInviteUrl?.trim() ?? '';
      final posts = funnel.publications
          .map((p) {
            final text = resolveTemplate(
              p.text,
              account: account,
              cluster: cluster,
              index: i + 1,
              channelLink: channelLink,
            );
            return <String, dynamic>{
              'text': text,
              'delayMs': p.delayAfterMs,
              if (p.mediaPath != null && p.mediaPath!.trim().isNotEmpty)
                'mediaPath': p.mediaPath,
            };
          })
          .where((p) => (p['text'] as String).trim().isNotEmpty || p['mediaPath'] != null)
          .toList();

      if (hasExistingChannel) {
        onLog(
          '[Воронка] ${i + 1}/${targets.length} · ${account.profileDisplayName} '
          '— канал уже есть ($existingChatId), без дубля',
        );
        onProgress?.call(
          '${account.profileDisplayName} · уже есть',
          done: i,
          total: targets.length,
        );

        if (funnel.publishAfterCreate && posts.isNotEmpty) {
          final pub = await MaxMotherService.funnelPublish(
            token: account.apiToken!,
            chatId: existingChatId,
            posts: posts,
            proxy: account.isolation.proxyServer,
            onProgress: (msg) => onLog(msg),
            cancel: cancel,
          );
          processed += 1;
          if (cancel?.isCancelled == true || pub.message == 'Остановлено пользователем') {
            onLog('[Воронка] «${funnel.name}» — остановлено', level: 'warn');
            onProgress?.call('Остановлено', done: processed, total: targets.length);
            return FunnelRunSummary(
              ok: false,
              processed: processed,
              succeeded: okCount,
              failed: failCount,
              message: 'Остановлено пользователем',
              cancelled: true,
            );
          }
          if (pub.inviteUrl != null && pub.inviteUrl!.trim().isNotEmpty) {
            await savePolicy(
              existingPolicy.copyWith(lastCreatedInviteUrl: pub.inviteUrl),
            );
          }
          if (pub.ok && pub.postsSent > 0) {
            okCount += 1;
            onLog(
              '[Воронка] ✓ ${account.profileDisplayName}: посты в существующий канал '
              '(${pub.postsSent})',
            );
          } else if (pub.ok) {
            okCount += 1;
            onLog('[Воронка] ✓ ${account.profileDisplayName}: канал без новых постов');
          } else {
            failCount += 1;
            onLog(
              '[Воронка] ✗ ${account.profileDisplayName}: ${pub.message}',
              level: 'error',
            );
          }
        } else {
          // No posts to send — still refresh invite URL if missing (for {channel_link}).
          if (existingPolicy.lastCreatedInviteUrl == null ||
              existingPolicy.lastCreatedInviteUrl!.trim().isEmpty) {
            final pub = await MaxMotherService.funnelPublish(
              token: account.apiToken!,
              chatId: existingChatId,
              posts: const [],
              proxy: account.isolation.proxyServer,
              onProgress: (msg) => onLog(msg),
              cancel: cancel,
            );
            if (pub.inviteUrl != null && pub.inviteUrl!.trim().isNotEmpty) {
              await savePolicy(
                existingPolicy.copyWith(lastCreatedInviteUrl: pub.inviteUrl),
              );
              onLog(
                '[Воронка] ✓ ${account.profileDisplayName}: сохранена ссылка канала',
              );
            }
          }
          processed += 1;
          okCount += 1;
          onLog('[Воронка] ✓ ${account.profileDisplayName}: пропуск создания');
        }

        onProgress?.call(
          account.profileDisplayName,
          done: processed,
          total: targets.length,
        );

        if (i < targets.length - 1 && funnel.accountGapMs > 0) {
          await delayUnlessCancelled(
            Duration(milliseconds: funnel.accountGapMs),
            token: cancel,
          );
        }
        continue;
      }

      onLog('[Воронка] ${i + 1}/${targets.length} · ${account.profileDisplayName} → «$title»');
      onProgress?.call(
        '${account.profileDisplayName} → «$title»',
        done: i,
        total: targets.length,
      );

      final result = await MaxMotherService.funnelSetup(
        token: account.apiToken!,
        title: title.isEmpty ? account.profileDisplayName : title,
        description: about,
        photoPath: funnel.channelPhotoPath,
        posts: posts,
        publish: funnel.publishAfterCreate,
        privateChannel: funnel.privateChannel,
        commentsEnabled: funnel.commentsEnabled,
        proxy: account.isolation.proxyServer,
        onProgress: (msg) => onLog(msg),
        cancel: cancel,
      );

      if (cancel?.isCancelled == true || result.message == 'Остановлено пользователем') {
        onLog('[Воронка] «${funnel.name}» — остановлено', level: 'warn');
        onProgress?.call('Остановлено', done: processed, total: targets.length);
        return FunnelRunSummary(
          ok: false,
          processed: processed,
          succeeded: okCount,
          failed: failCount,
          message: 'Остановлено пользователем',
          cancelled: true,
        );
      }

      processed += 1;

      if (result.ok && result.chatId != null) {
        okCount += 1;
        final flags = <String>[
          if (about != null)
            result.descriptionApplied ? 'описание✓' : 'описание✗',
          if (funnel.channelPhotoPath != null &&
              funnel.channelPhotoPath!.trim().isNotEmpty)
            result.avatarApplied ? 'фото✓' : 'фото✗',
        ];
        onLog(
          '[Воронка] ✓ ${account.profileDisplayName}: chat ${result.chatId}'
          '${flags.isNotEmpty ? ' · ${flags.join(', ')}' : ''}'
          '${result.postsSent > 0 ? ', постов ${result.postsSent}' : ''}'
          '${result.inviteUrl != null ? ' · ${result.inviteUrl}' : ''}',
        );
        if (about != null && !result.descriptionApplied) {
          onLog('[Воронка] описание не применилось через API', level: 'warn');
        }
        if (funnel.channelPhotoPath != null &&
            funnel.channelPhotoPath!.trim().isNotEmpty &&
            !result.avatarApplied) {
          onLog('[Воронка] фото канала не установилось через API', level: 'warn');
        }
        final policy = policyFor(account.id);
        await savePolicy(
          policy.copyWith(
            lastCreatedChatId: result.chatId,
            lastCreatedTitle: result.title ?? title,
            lastCreatedInviteUrl: result.inviteUrl,
          ),
        );
      } else {
        failCount += 1;
        onLog(
          '[Воронка] ✗ ${account.profileDisplayName}: ${result.message}',
          level: 'error',
        );
      }

      onProgress?.call(
        account.profileDisplayName,
        done: processed,
        total: targets.length,
      );

      if (i < targets.length - 1 && funnel.accountGapMs > 0) {
        await delayUnlessCancelled(
          Duration(milliseconds: funnel.accountGapMs),
          token: cancel,
        );
      }
    }

    final summary =
        'Готово: успешно $okCount · ошибок $failCount · всего ${targets.length}';
    onLog('[Воронка] «${funnel.name}» — $summary');
    onProgress?.call(summary, done: processed, total: targets.length);
    return FunnelRunSummary(
      ok: failCount == 0,
      processed: targets.length,
      succeeded: okCount,
      failed: failCount,
      message: summary,
    );
  }

  /// Publish funnel posts into already-created channels ([AccountChannelPolicy.lastCreatedChatId]).
  Future<FunnelRunSummary> publishOnly({
    required ChannelFunnel funnel,
    required List<MaxAccount> accounts,
    required List<MotherCluster> clusters,
    required AccountChannelPolicy Function(String accountId) policyFor,
    Set<String>? accountIds,
    required FunnelLog onLog,
    ActionCancelToken? cancel,
    void Function(String message, {int? done, int? total})? onProgress,
  }) async {
    final idFilter = accountIds;
    final candidates = <MaxAccount>[];
    for (final account in accounts) {
      if (idFilter != null && !idFilter.contains(account.id)) continue;
      final policy = policyFor(account.id);
      if (!policy.canCreateChannels) continue;
      if (!policy.funnelIds.contains(funnel.id)) continue;
      if (!account.hasApiSession) {
        onLog(
          '[Воронка] «${account.profileDisplayName}» — нет токена, пропуск',
          level: 'warn',
        );
        continue;
      }
      candidates.add(account);
    }

    final targets = <({MaxAccount account, String chatId, String? chatTitle})>[];
    for (final account in candidates) {
      final policy = policyFor(account.id);
      final chatId = policy.lastCreatedChatId?.trim();
      if (chatId == null || chatId.isEmpty) {
        onLog(
          '[Воронка] «${account.profileDisplayName}» — нет созданного канала, пропуск',
          level: 'warn',
        );
        continue;
      }
      targets.add((
        account: account,
        chatId: chatId,
        chatTitle: policy.lastCreatedTitle,
      ));
    }

    if (targets.isEmpty) {
      onLog(
        '[Воронка] «${funnel.name}» — некому публиковать '
        '(нужны аккаунты воронки с lastCreatedChatId)',
        level: 'warn',
      );
      return FunnelRunSummary(
        ok: false,
        processed: 0,
        succeeded: 0,
        failed: 0,
        message: 'Нет аккаунтов с созданным каналом',
      );
    }

    if (funnel.publicationCount == 0) {
      return FunnelRunSummary(
        ok: false,
        processed: 0,
        succeeded: 0,
        failed: 0,
        message: 'В воронке нет постов',
      );
    }

    onLog(
      '[Воронка] «${funnel.name}» — публикация для ${targets.length} акк., '
      'постов: ${funnel.publicationCount}',
    );
    onProgress?.call('Публикация…', done: 0, total: targets.length);

    var okCount = 0;
    var failCount = 0;
    var processed = 0;

    for (var i = 0; i < targets.length; i++) {
      if (cancel?.isCancelled == true) {
        onLog('[Воронка] «${funnel.name}» — остановлено', level: 'warn');
        onProgress?.call('Остановлено', done: processed, total: targets.length);
        return FunnelRunSummary(
          ok: false,
          processed: processed,
          succeeded: okCount,
          failed: failCount,
          message: 'Остановлено пользователем',
          cancelled: true,
        );
      }

      final target = targets[i];
      final account = target.account;
      MotherCluster? cluster;
      for (final c in clusters) {
        if (c.motherAccountId == account.id || c.childAccountIds.contains(account.id)) {
          cluster = c;
          break;
        }
      }

      final posts = funnel.publications
          .map((p) {
            final text = resolveTemplate(
              p.text,
              account: account,
              cluster: cluster,
              index: i + 1,
              channelLink: policyFor(account.id).lastCreatedInviteUrl,
            );
            return <String, dynamic>{
              'text': text,
              'delayMs': p.delayAfterMs,
              if (p.mediaPath != null && p.mediaPath!.trim().isNotEmpty)
                'mediaPath': p.mediaPath,
            };
          })
          .where((p) => (p['text'] as String).trim().isNotEmpty || p['mediaPath'] != null)
          .toList();

      final label = target.chatTitle?.trim().isNotEmpty == true
          ? target.chatTitle!.trim()
          : target.chatId;
      onLog(
        '[Воронка] ${i + 1}/${targets.length} · ${account.profileDisplayName} → «$label»',
      );
      onProgress?.call(
        '${account.profileDisplayName} → посты',
        done: i,
        total: targets.length,
      );

      final result = await MaxMotherService.funnelPublish(
        token: account.apiToken!,
        chatId: target.chatId,
        posts: posts,
        proxy: account.isolation.proxyServer,
        onProgress: (msg) => onLog(msg),
        cancel: cancel,
      );

      if (cancel?.isCancelled == true || result.message == 'Остановлено пользователем') {
        onLog('[Воронка] «${funnel.name}» — остановлено', level: 'warn');
        onProgress?.call('Остановлено', done: processed, total: targets.length);
        return FunnelRunSummary(
          ok: false,
          processed: processed,
          succeeded: okCount,
          failed: failCount,
          message: 'Остановлено пользователем',
          cancelled: true,
        );
      }

      processed += 1;

      if (result.ok && result.postsSent > 0) {
        okCount += 1;
        onLog(
          '[Воронка] ✓ ${account.profileDisplayName}: постов ${result.postsSent}'
          '${result.photoFailures > 0 ? ' (фото✗ ${result.photoFailures})' : ''}',
        );
      } else if (result.ok) {
        failCount += 1;
        onLog(
          '[Воронка] ✗ ${account.profileDisplayName}: посты не ушли',
          level: 'error',
        );
      } else {
        failCount += 1;
        onLog(
          '[Воронка] ✗ ${account.profileDisplayName}: ${result.message}',
          level: 'error',
        );
      }

      onProgress?.call(
        account.profileDisplayName,
        done: processed,
        total: targets.length,
      );

      if (i < targets.length - 1 && funnel.accountGapMs > 0) {
        await delayUnlessCancelled(
          Duration(milliseconds: funnel.accountGapMs),
          token: cancel,
        );
      }
    }

    final summary =
        'Публикация: успешно $okCount · ошибок $failCount · всего ${targets.length}';
    onLog('[Воронка] «${funnel.name}» — $summary');
    onProgress?.call(summary, done: processed, total: targets.length);
    return FunnelRunSummary(
      ok: failCount == 0,
      processed: targets.length,
      succeeded: okCount,
      failed: failCount,
      message: summary,
    );
  }
}
