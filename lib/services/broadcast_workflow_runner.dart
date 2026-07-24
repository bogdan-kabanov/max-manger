import 'dart:async';

import '../models/active_action.dart';
import '../models/map_workflow.dart';
import '../models/max_account.dart';
import '../models/rate_settings.dart';
import 'max_ws_service.dart';

typedef BroadcastLog = void Function(String message, {String level});

class BroadcastWorkflowRunner {
  final Map<String, MaxWsService> _wsByAccount = {};
  final Map<String, Timer> _timers = {};
  RateSettings _rateSettings = RateSettings.defaults;

  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    for (final ws in _wsByAccount.values) {
      unawaited(ws.disconnect());
    }
    _wsByAccount.clear();
  }

  void syncSchedules({
    required List<MapWorkflowNode> nodes,
    required List<WorkflowMapEdge> edges,
    required List<MaxAccount> accounts,
    required BroadcastLog onLog,
    RateSettings rateSettings = RateSettings.defaults,
    Future<void> Function(MapWorkflowNode node)? onScheduledRun,
  }) {
    _rateSettings = rateSettings;
    final desired = <String>{};
    for (final node in nodes) {
      if (!node.isBroadcast) continue;
      final cfg = node.broadcast;
      if (cfg == null || !cfg.enabled || cfg.intervalMinutes < 1) continue;
      if (cfg.steps.isEmpty || cfg.targetChats.isEmpty) continue;
      desired.add(node.id);
      if (_timers.containsKey(node.id)) continue;

      final interval = Duration(minutes: cfg.intervalMinutes);
      _timers[node.id] = Timer.periodic(interval, (_) {
        if (onScheduledRun != null) {
          unawaited(onScheduledRun(node));
        } else {
          unawaited(runBroadcast(
            node: node,
            edges: edges,
            accounts: accounts,
            rateSettings: _rateSettings,
            onLog: onLog,
          ));
        }
      });
      onLog('[Рассылка] «${node.title}» — таймер каждые ${cfg.intervalMinutes} мин');
    }

    for (final key in _timers.keys.toList()) {
      if (!desired.contains(key)) {
        _timers.remove(key)?.cancel();
      }
    }
  }

  String? resolveSenderId(MapWorkflowNode node, List<WorkflowMapEdge> edges) {
    final fromConfig = node.broadcast?.senderAccountId;
    if (fromConfig != null && fromConfig.isNotEmpty) return fromConfig;
    for (final edge in edges) {
      if (edge.toId == node.id && edge.kind == WorkflowEdgeKind.sender) {
        return edge.fromId;
      }
    }
    return null;
  }

  Future<void> runBroadcast({
    required MapWorkflowNode node,
    required List<WorkflowMapEdge> edges,
    required List<MaxAccount> accounts,
    required BroadcastLog onLog,
    RateSettings rateSettings = RateSettings.defaults,
    ActionCancelToken? cancel,
    void Function(String message, {int? done, int? total})? onProgress,
  }) async {
    if (!node.isBroadcast) return;
    final cfg = node.broadcast;
    if (cfg == null || cfg.steps.isEmpty) {
      onLog('[Рассылка] «${node.title}» — нет сообщений', level: 'warn');
      return;
    }
    if (cfg.targetChats.isEmpty) {
      onLog('[Рассылка] «${node.title}» — не указаны чаты', level: 'warn');
      return;
    }

    final senderId = resolveSenderId(node, edges);
    if (senderId == null) {
      onLog('[Рассылка] «${node.title}» — подключите аккаунт-отправитель', level: 'error');
      return;
    }

    MaxAccount? account;
    for (final a in accounts) {
      if (a.id == senderId) {
        account = a;
        break;
      }
    }
    if (account == null || !account.hasApiSession) {
      onLog('[Рассылка] «${node.title}» — у отправителя нет токена', level: 'error');
      return;
    }

    final uzbek = account.isUzbek;
    final messageDelayFloor = uzbek ? rateSettings.uzbekMessageDelayMs : 0;
    final chatGapMs = uzbek ? rateSettings.uzbekChatGapMs : 800;
    final totalSteps = cfg.targetChats.length * cfg.steps.length;
    var done = 0;

    onLog(
      '[Рассылка] «${node.title}» — старт (${cfg.steps.length} сообщ., ${cfg.targetChats.length} чатов)'
      '${uzbek ? ' · узб пауза ${rateSettings.uzbekMessageDelayMs}мс / чаты $chatGapMsмс' : ''}',
    );
    onProgress?.call('Старт…', done: 0, total: totalSteps);

    try {
      final ws = await _wsFor(account, cfg.targetChats, onLog);
      for (final target in cfg.targetChats) {
        if (cancel?.isCancelled == true) {
          onLog('[Рассылка] «${node.title}» — остановлено', level: 'warn');
          onProgress?.call('Остановлено', done: done, total: totalSteps);
          return;
        }
        for (var i = 0; i < cfg.steps.length; i++) {
          if (cancel?.isCancelled == true) {
            onLog('[Рассылка] «${node.title}» — остановлено', level: 'warn');
            onProgress?.call('Остановлено', done: done, total: totalSteps);
            return;
          }
          final step = cfg.steps[i];
          final text = step.text.trim();
          if (text.isEmpty) {
            done += 1;
            continue;
          }
          try {
            await ws.sendToTargetChat(target, text);
            onLog('[Рассылка] ✓ «$target» — сообщение ${i + 1}/${cfg.steps.length}');
          } catch (e) {
            onLog('[Рассылка] ✗ «$target»: $e', level: 'error');
          }
          done += 1;
          onProgress?.call(
            '«$target» · ${i + 1}/${cfg.steps.length}',
            done: done,
            total: totalSteps,
          );
          if (i < cfg.steps.length - 1) {
            final delay = step.delayAfterMs > messageDelayFloor
                ? step.delayAfterMs
                : messageDelayFloor;
            if (delay > 0) {
              onLog('[Рассылка] пауза ${delay}мс…');
              await delayUnlessCancelled(
                Duration(milliseconds: delay),
                token: cancel,
              );
            }
          }
        }
        if (cfg.targetChats.length > 1 && chatGapMs > 0) {
          onLog('[Рассылка] пауза между чатами ${chatGapMs}мс…');
          await delayUnlessCancelled(
            Duration(milliseconds: chatGapMs),
            token: cancel,
          );
        }
      }
      if (cancel?.isCancelled == true) {
        onLog('[Рассылка] «${node.title}» — остановлено', level: 'warn');
        onProgress?.call('Остановлено', done: done, total: totalSteps);
        return;
      }
      onLog('[Рассылка] «${node.title}» — готово');
      onProgress?.call('Готово', done: done, total: totalSteps);
    } catch (e) {
      onLog('[Рассылка] «${node.title}» — ошибка: $e', level: 'error');
      onProgress?.call('Ошибка: $e', done: done, total: totalSteps);
    }
  }

  Future<MaxWsService> _wsFor(
    MaxAccount account,
    List<String> targetChats,
    BroadcastLog onLog,
  ) async {
    var ws = _wsByAccount[account.id];
    if (ws == null) {
      ws = MaxWsService();
      ws.onLog = (msg, {String level = 'info'}) => onLog(msg, level: level);
      _wsByAccount[account.id] = ws;
    }
    await ws.connect(
      token: account.apiToken!,
      deviceId: account.webDeviceId,
      viewerId: account.viewerId,
      targetChats: targetChats,
      proxyUrl: account.isolation.proxyServer,
    );
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    return ws;
  }
}
