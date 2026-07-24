import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/max_account.dart';
import '../providers/app_state.dart';

/// Human-readable role of [accountId] in parent/child clusters.
String accountClusterRoleLabel(AppState state, String accountId) {
  if (state.accountMap.isMotherAccount(accountId)) {
    final cluster = state.accountMap.clusterForMother(accountId);
    final n = cluster?.childCount ?? 0;
    if (n == 0) return 'Родитель · один';
    return 'Родитель · $n доч.';
  }
  if (state.accountMap.isChildAccount(accountId)) {
    final cluster = state.clusterContainingAccount(accountId);
    final parentId = cluster?.motherAccountId;
    final parent = parentId == null ? null : state.accountById(parentId);
    if (parent != null) return 'Дочерний · ${parent.label}';
    return 'Дочерний';
  }
  return '—';
}

enum _ParentEditorResult { cancel, save, clear }

/// Dialog: make [parentAccountId] a parent and pick children (may be empty = solo).
Future<bool> showParentClusterEditor(
  BuildContext context, {
  required String parentAccountId,
}) async {
  final state = context.read<AppState>();
  final parent = state.accountById(parentAccountId);
  if (parent == null) return false;

  final existing = state.accountMap.clusterForMother(parentAccountId);
  final childIds = <String>{...(existing?.childAccountIds ?? const {})};
  childIds.remove(parentAccountId);

  final result = await showDialog<_ParentEditorResult>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          final accounts = state.accounts
              .where((a) => a.id != parentAccountId)
              .toList()
            ..sort(
              (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
            );
          final occupiedElsewhere = state.accountMap.occupiedAccountIds(
            exceptClusterId: existing?.id,
          );

          return AlertDialog(
            title: Text('Родительский: ${parent.label}'),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Дочерние необязательны. Без них аккаунт работает один.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (accounts.isEmpty)
                    const Text(
                      'Нет других аккаунтов — можно сохранить без дочерних.',
                      style: TextStyle(fontSize: 13),
                    )
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 320),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final a in accounts)
                            _ChildPickTile(
                              account: a,
                              selected: childIds.contains(a.id),
                              elsewhere: occupiedElsewhere.contains(a.id) &&
                                  !childIds.contains(a.id),
                              onChanged: (v) => setLocal(() {
                                if (v == true) {
                                  childIds.add(a.id);
                                } else {
                                  childIds.remove(a.id);
                                }
                              }),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    childIds.isEmpty
                        ? 'Режим: один аккаунт (без дочерних)'
                        : 'Выбрано дочерних: ${childIds.length}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(ctx).colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, _ParentEditorResult.cancel),
                child: const Text('Отмена'),
              ),
              if (existing != null)
                TextButton(
                  onPressed: () => Navigator.pop(ctx, _ParentEditorResult.clear),
                  child: Text(
                    'Снять роль',
                    style: TextStyle(color: Theme.of(ctx).colorScheme.error),
                  ),
                ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, _ParentEditorResult.save),
                child: Text(existing == null ? 'Назначить' : 'Сохранить'),
              ),
            ],
          );
        },
      );
    },
  );

  if (!context.mounted) return false;
  if (result == null || result == _ParentEditorResult.cancel) return false;

  if (result == _ParentEditorResult.clear) {
    if (existing != null) {
      await state.removeMotherCluster(existing.id);
      return true;
    }
    return false;
  }

  if (existing != null) {
    await state.setMotherClusterRelations(
      clusterId: existing.id,
      motherId: parentAccountId,
      childIds: childIds,
    );
  } else {
    final index = state.motherClusters.length + 1;
    final cluster = await state.addMotherCluster(
      name: 'Родитель $index',
      motherAccountId: parentAccountId,
    );
    await state.setMotherClusterRelations(
      clusterId: cluster.id,
      motherId: parentAccountId,
      childIds: childIds,
    );
  }
  return true;
}

class _ChildPickTile extends StatelessWidget {
  const _ChildPickTile({
    required this.account,
    required this.selected,
    required this.elsewhere,
    required this.onChanged,
  });

  final MaxAccount account;
  final bool selected;
  final bool elsewhere;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      value: selected,
      onChanged: onChanged,
      title: Text(account.label, style: const TextStyle(fontSize: 13)),
      subtitle: () {
        final parts = <String>[
          if (!account.hasApiSession) 'нет токена',
          if (elsewhere) 'сейчас у другого родителя — переедет сюда',
        ];
        if (parts.isEmpty) return null;
        return Text(
          parts.join(' · '),
          style: TextStyle(
            fontSize: 11,
            color: elsewhere
                ? Theme.of(context).colorScheme.tertiary
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        );
      }(),
    );
  }
}
