import 'package:flutter/material.dart';
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
                        ],
                      ),
                    ],
                  ),
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
}
