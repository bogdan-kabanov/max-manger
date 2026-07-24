import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/active_action.dart';
import '../providers/app_state.dart';

/// Lists tracked long-running jobs with stop / clear controls.
class ActiveActionsPanel extends StatelessWidget {
  const ActiveActionsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final actions = state.activeActions;
    final running = state.runningActionsCount;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Действия',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      running > 0
                          ? 'Сейчас выполняется: $running'
                          : 'Нет активных задач',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (running > 0)
                TextButton.icon(
                  onPressed: () => state.cancelAllActions(),
                  icon: const Icon(Icons.stop_circle_outlined, size: 18),
                  label: const Text('Стоп все'),
                ),
              if (actions.any((a) => !a.isActive))
                TextButton.icon(
                  onPressed: () => state.clearFinishedActions(),
                  icon: const Icon(Icons.clear_all, size: 18),
                  label: const Text('Очистить'),
                ),
            ],
          ),
        ),
        Expanded(
          child: actions.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.pending_actions_outlined,
                          size: 48,
                          color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Здесь появятся запущенные\nвступления, рассылки, воронки…',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                  itemCount: actions.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    return _ActionCard(action: actions[index]);
                  },
                ),
        ),
      ],
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.action});

  final ActiveAction action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final statusColor = switch (action.status) {
      ActiveActionStatus.running => scheme.primary,
      ActiveActionStatus.cancelling => scheme.tertiary,
      ActiveActionStatus.completed => scheme.secondary,
      ActiveActionStatus.failed => scheme.error,
      ActiveActionStatus.cancelled => scheme.outline,
    };
    final progress = (action.done != null && action.total != null && action.total! > 0)
        ? (action.done! / action.total!).clamp(0.0, 1.0)
        : null;
    final waitRem = action.waitRemaining;

    return Card(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: statusColor.withValues(alpha: 0.18),
                  child: Icon(
                    _iconFor(action.kind),
                    size: 18,
                    color: statusColor,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        action.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      if (action.subtitle != null && action.subtitle!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          action.subtitle!,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: statusColor.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              action.status.label,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: statusColor,
                              ),
                            ),
                          ),
                          Text(
                            _formatElapsed(action.elapsed),
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          if (action.done != null && action.total != null)
                            Text(
                              '${action.done}/${action.total}',
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          if (waitRem != null && waitRem > Duration.zero)
                            Text(
                              'ещё ${_formatCountdown(waitRem)}',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: scheme.primary,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Подробный лог',
                  onPressed: () => _openDetailLog(context, action.id),
                  icon: const Icon(Icons.terminal, size: 20),
                ),
                if (action.isActive)
                  IconButton(
                    tooltip: 'Остановить',
                    onPressed: action.status == ActiveActionStatus.cancelling
                        ? null
                        : () => context.read<AppState>().cancelAction(action.id),
                    icon: action.status == ActiveActionStatus.cancelling
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.stop_circle_outlined),
                  ),
              ],
            ),
            if (action.progressMessage.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                action.progressMessage,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: scheme.onSurface.withValues(alpha: 0.85),
                ),
              ),
            ],
            if (action.isActive) ...[
              const SizedBox(height: 10),
              if (progress != null)
                LinearProgressIndicator(value: progress)
              else
                const LinearProgressIndicator(),
            ],
          ],
        ),
      ),
    );
  }

  static void _openDetailLog(BuildContext context, String actionId) {
    showDialog<void>(
      context: context,
      builder: (ctx) => _ActionDetailLogDialog(actionId: actionId),
    );
  }

  static IconData _iconFor(ActiveActionKind kind) {
    return switch (kind) {
      ActiveActionKind.joinChannels => Icons.login,
      ActiveActionKind.inviteChildren => Icons.person_add_alt_1,
      ActiveActionKind.forwardLinks => Icons.forward_to_inbox,
      ActiveActionKind.forwardAndJoin => Icons.swap_horiz,
      ActiveActionKind.childrenJoin => Icons.group_add,
      ActiveActionKind.motherDeploy => Icons.hive_outlined,
      ActiveActionKind.massInvite => Icons.groups,
      ActiveActionKind.leaveGroups => Icons.logout,
      ActiveActionKind.discoverChannels => Icons.travel_explore,
      ActiveActionKind.postJoinMessage => Icons.mail_outline,
      ActiveActionKind.broadcast => Icons.campaign_outlined,
      ActiveActionKind.funnel => Icons.filter_alt_outlined,
      ActiveActionKind.other => Icons.bolt_outlined,
    };
  }

  static String _formatElapsed(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    if (m <= 0) return '${s}с';
    return '${m}м ${s.toString().padLeft(2, '0')}с';
  }

  static String _formatCountdown(Duration d) {
    final totalSec = d.inSeconds;
    if (totalSec <= 0) return '0с';
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    if (m <= 0) return '${s}с';
    return '${m}м ${s.toString().padLeft(2, '0')}с';
  }
}

class _ActionDetailLogDialog extends StatefulWidget {
  const _ActionDetailLogDialog({required this.actionId});

  final String actionId;

  @override
  State<_ActionDetailLogDialog> createState() => _ActionDetailLogDialogState();
}

class _ActionDetailLogDialogState extends State<_ActionDetailLogDialog> {
  final _scroll = ScrollController();
  int _lastLogCount = 0;
  bool _stickToBottom = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final atBottom = _scroll.position.pixels >= _scroll.position.maxScrollExtent - 48;
      _stickToBottom = atBottom;
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _maybeAutoScroll(int logCount) {
    if (!_stickToBottom || logCount == _lastLogCount) {
      _lastLogCount = logCount;
      return;
    }
    _lastLogCount = logCount;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final action = state.actionById(widget.actionId);
    final scheme = Theme.of(context).colorScheme;

    if (action == null) {
      return AlertDialog(
        title: const Text('Лог действия'),
        content: const Text('Действие уже удалено из списка.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      );
    }

    _maybeAutoScroll(action.logs.length);

    final waitRem = action.waitRemaining;
    final statusColor = switch (action.status) {
      ActiveActionStatus.running => scheme.primary,
      ActiveActionStatus.cancelling => scheme.tertiary,
      ActiveActionStatus.completed => scheme.secondary,
      ActiveActionStatus.failed => scheme.error,
      ActiveActionStatus.cancelled => scheme.outline,
    };

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640, minWidth: 420),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
              child: Row(
                children: [
                  Icon(Icons.terminal, size: 20, color: scheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          action.title,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                        if (action.subtitle != null && action.subtitle!.isNotEmpty)
                          Text(
                            action.subtitle!,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: action.logs.isEmpty
                        ? null
                        : () {
                            final text = action.logs
                                .map((e) =>
                                    '${_fmtTime(e.time)} ${e.message}')
                                .join('\n');
                            Clipboard.setData(ClipboardData(text: text));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Лог скопирован')),
                            );
                          },
                    child: const Text('Копировать'),
                  ),
                  IconButton(
                    tooltip: 'Закрыть',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      action.status.label,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: statusColor,
                      ),
                    ),
                  ),
                  Text(
                    'время: ${_ActionCard._formatElapsed(action.elapsed)}',
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                  if (action.done != null && action.total != null)
                    Text(
                      'прогресс: ${action.done}/${action.total}',
                      style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                    ),
                  Text(
                    'строк: ${action.logs.length}',
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                  if (action.isActive)
                    TextButton.icon(
                      onPressed: action.status == ActiveActionStatus.cancelling
                          ? null
                          : () => state.cancelAction(action.id),
                      icon: const Icon(Icons.stop_circle_outlined, size: 16),
                      label: const Text('Стоп'),
                    ),
                ],
              ),
            ),
            if (waitRem != null && waitRem > Duration.zero)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Material(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(
                      children: [
                        Icon(Icons.timer_outlined, size: 18, color: scheme.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Осталось ${_ActionCard._formatCountdown(waitRem)}',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: scheme.primary,
                                  fontSize: 14,
                                ),
                              ),
                              if (action.waitLabel != null && action.waitLabel!.isNotEmpty)
                                Text(
                                  action.waitLabel!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: action.logs.isEmpty
                  ? Center(
                      child: Text(
                        'Пока нет записей — события появятся здесь в реальном времени.',
                        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                      itemCount: action.logs.length,
                      itemBuilder: (context, index) {
                        final line = action.logs[index];
                        final color = line.level == 'error'
                            ? Colors.redAccent
                            : line.level == 'warn'
                                ? Colors.orangeAccent
                                : line.message.contains('✓')
                                    ? const Color(0xFF6BCB77)
                                    : line.message.toLowerCase().contains('пауза')
                                        ? scheme.primary
                                        : null;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: SelectableText.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '${_fmtTime(line.time)}  ',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: scheme.onSurfaceVariant,
                                    fontFamily: 'Consolas',
                                  ),
                                ),
                                TextSpan(
                                  text: line.message,
                                  style: TextStyle(
                                    fontSize: 11,
                                    height: 1.35,
                                    color: color,
                                    fontFamily: 'Consolas',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  static String _fmtTime(DateTime t) {
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
  }
}
