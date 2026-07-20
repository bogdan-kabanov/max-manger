import 'package:flutter/material.dart';

import '../../models/map_workflow.dart';

class WorkflowGroupCard extends StatelessWidget {
  const WorkflowGroupCard({
    super.key,
    required this.node,
    required this.selected,
    required this.childCount,
    this.chatCount = 0,
    required this.onTap,
    required this.onEdit,
  });

  final MapWorkflowNode node;
  final bool selected;
  final int childCount;
  final int chatCount;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: node.width,
      height: node.height - 22,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
        border: Border.all(
          color: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.outline.withValues(alpha: 0.35),
          width: selected ? 2 : 1,
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            left: 12,
            top: 10,
            right: 12,
            child: Row(
              children: [
                Icon(Icons.folder_outlined, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    node.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  tooltip: 'Настройки группы',
                  onPressed: onEdit,
                  icon: const Icon(Icons.settings_outlined, size: 16),
                ),
              ],
            ),
          ),
          Positioned(
            left: 12,
            bottom: 12,
            child: Text(
              '$chatCount чатов · $childCount рассылок',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class WorkflowBroadcastCard extends StatelessWidget {
  const WorkflowBroadcastCard({
    super.key,
    required this.node,
    required this.selected,
    required this.senderLabel,
    required this.onTap,
    required this.onEdit,
    required this.onRun,
  });

  final MapWorkflowNode node;
  final bool selected;
  final String? senderLabel;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cfg = node.broadcast;
    final msgCount = cfg?.steps.length ?? 0;
    final chatCount = cfg?.targetChats.length ?? 0;
    final enabled = cfg?.enabled == true;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: node.width,
      height: node.height - 22,
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.45),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
        border: Border.all(
          color: selected
              ? theme.colorScheme.tertiary
              : theme.colorScheme.outline.withValues(alpha: 0.35),
          width: selected ? 2 : 1,
        ),
        boxShadow: [
          if (enabled)
            BoxShadow(
              color: theme.colorScheme.tertiary.withValues(alpha: 0.2),
              blurRadius: 12,
              spreadRadius: 1,
            ),
        ],
      ),
      child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.campaign_outlined, size: 18, color: theme.colorScheme.tertiary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      node.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                    ),
                  ),
                  if (enabled)
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: Colors.greenAccent,
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '$msgCount сообщ. · $chatCount чатов',
                style: theme.textTheme.bodySmall,
              ),
              Text(
                senderLabel != null ? 'От: $senderLabel' : 'Нет отправителя',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: senderLabel != null
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.error,
                ),
              ),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onEdit,
                      icon: const Icon(Icons.tune, size: 14),
                      label: const Text('Настроить', style: TextStyle(fontSize: 11)),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filledTonal(
                    tooltip: 'Запустить сейчас',
                    visualDensity: VisualDensity.compact,
                    onPressed: onRun,
                    icon: const Icon(Icons.play_arrow, size: 18),
                  ),
                ],
              ),
            ],
          ),
        ),
    );
  }
}
