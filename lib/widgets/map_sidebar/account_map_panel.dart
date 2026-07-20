import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_state.dart';

class AccountMapPanel extends StatelessWidget {
  const AccountMapPanel({super.key, required this.accountId});

  final String accountId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final account = state.accountById(accountId);
    if (account == null) {
      return const Center(child: Text('Аккаунт не найден'));
    }

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
              Row(
                children: [
                  Icon(Icons.person_outline, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      account.label,
                      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                account.hasApiSession ? 'Токен подключён' : 'Нет API-токена',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Text(
                'Аккаунт — точка входа. Создайте группу, чтобы настроить чаты и рассылки.',
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
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            onPressed: () => state.setBrowserDrawerOpen(true),
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('Открыть MAX'),
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('Группы (${groups.length})', style: theme.textTheme.titleSmall),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: groups.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Нет групп. Создайте первую — она появится на карте и свяжется с аккаунтом.'),
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
