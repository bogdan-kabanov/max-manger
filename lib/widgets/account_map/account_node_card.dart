import 'package:flutter/material.dart';

import '../../models/max_account.dart';

class AccountNodeCard extends StatelessWidget {
  const AccountNodeCard({
    super.key,
    required this.account,
    required this.selected,
    required this.isMother,
    required this.isChild,
    required this.activityLabel,
    required this.onTap,
    required this.onOpen,
    this.highlightLink = false,
  });

  static const nodeWidth = 168.0;
  static const nodeHeight = 118.0;

  final MaxAccount account;
  final bool selected;
  final bool isMother;
  final bool isChild;
  final String? activityLabel;
  final VoidCallback onTap;
  final VoidCallback onOpen;
  final bool highlightLink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderColor = highlightLink
        ? Colors.lightBlueAccent
        : selected
        ? theme.colorScheme.primary
        : isMother
            ? Colors.orangeAccent
            : Colors.transparent;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onDoubleTap: onOpen,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: nodeWidth,
          height: nodeHeight,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.45),
            border: Border.all(color: borderColor, width: selected ? 2 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      account.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                  ),
                  if (isMother) const Icon(Icons.hive, size: 16, color: Colors.orangeAccent),
                  if (isChild)
                    const Icon(Icons.subdirectory_arrow_right, size: 16, color: Colors.lightBlueAccent),
                ],
              ),
              const Spacer(),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  _Badge(
                    label: account.hasApiSession ? 'токен ✓' : 'нет токена',
                    color: account.hasApiSession ? Colors.green : Colors.orangeAccent,
                  ),
                  if (account.viewerId != null)
                    _Badge(label: 'id ${account.viewerId}', color: theme.colorScheme.outline),
                ],
              ),
              if (activityLabel != null) ...[
                const SizedBox(height: 4),
                Text(
                  activityLabel!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 9, color: Colors.orangeAccent.shade200),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(label, style: TextStyle(fontSize: 8, color: color)),
    );
  }
}
