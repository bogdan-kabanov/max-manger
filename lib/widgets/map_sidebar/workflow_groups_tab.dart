import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/map_workflow.dart';
import '../../providers/app_state.dart';
import 'broadcast_map_panel.dart';
import 'group_map_panel.dart';

/// Workflow groups for the selected account — list or group/broadcast detail.
class WorkflowGroupsTab extends StatelessWidget {
  const WorkflowGroupsTab({super.key, required this.accountId});

  final String accountId;

  bool _belongsToAccount(AppState state, String groupId) {
    return state.ownerAccountIdForGroup(groupId) == accountId;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final selectedId = state.selectedWorkflowNodeId;
    if (selectedId != null) {
      final node = state.workflowNodes.byId(selectedId);
      if (node != null) {
        if (node.isGroup && _belongsToAccount(state, node.id)) {
          return GroupMapPanel(
            key: ValueKey(node.id),
            node: node,
            includeChats: false,
            onBack: () => state.selectWorkflowNode(null),
          );
        }
        if (node.isBroadcast &&
            node.parentGroupId != null &&
            _belongsToAccount(state, node.parentGroupId!)) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => state.selectWorkflowNode(node.parentGroupId),
                    icon: const Icon(Icons.arrow_back, size: 18),
                    label: const Text('К группе'),
                  ),
                ),
              ),
              Expanded(
                child: BroadcastMapPanel(key: ValueKey(node.id), node: node),
              ),
            ],
          );
        }
      }
    }

    return _GroupsList(accountId: accountId);
  }
}

class _GroupsList extends StatelessWidget {
  const _GroupsList({required this.accountId});

  final String accountId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final account = state.accountById(accountId);
    final groups = state.groupsForAccount(accountId);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Группы',
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                account == null
                    ? 'Папки на карте: чаты и рассылки внутри.'
                    : 'Аккаунт «${account.label}». Чаты — на вкладке «Чаты».',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FilledButton.icon(
            onPressed: () async {
              await state.addWorkflowGroupForAccount(accountId);
            },
            icon: const Icon(Icons.folder_outlined, size: 18),
            label: const Text('Создать группу'),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: groups.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Нет групп. Создайте первую — она появится на карте.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  itemCount: groups.length,
                  itemBuilder: (context, index) {
                    final group = groups[index];
                    final chatCount = group.group?.targetChats.length ?? 0;
                    final broadcastCount = state.broadcastsInGroup(group.id).length;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(group.title),
                        subtitle: Text('$chatCount чатов · $broadcastCount рассылок'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => state.selectWorkflowNode(group.id),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
