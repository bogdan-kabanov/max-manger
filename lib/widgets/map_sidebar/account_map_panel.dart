import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/max_account.dart';
import '../../providers/app_state.dart';

/// Slim account identity tab — no groups/chats clutter.
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

    final theme = Theme.of(context);
    final groups = state.groupsForAccount(accountId);
    final totalChats = groups.fold<int>(
      0,
      (sum, g) => sum + (g.group?.targetChats.length ?? 0),
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
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
          account.healthStatus.longLabel,
          style: theme.textTheme.bodySmall?.copyWith(
            color: switch (account.healthStatus) {
              AccountHealthStatus.ok => Colors.lightGreenAccent,
              AccountHealthStatus.banned => Colors.redAccent,
              AccountHealthStatus.authFailed => Colors.orangeAccent,
              AccountHealthStatus.networkError => Colors.blueGrey.shade200,
              AccountHealthStatus.unknown => null,
            },
          ),
        ),
        Text(
          account.hasApiSession ? 'Токен подключён' : 'Нет API-токена',
          style: theme.textTheme.bodySmall,
        ),
        if (account.lastError != null && account.healthStatus.isProblem) ...[
          const SizedBox(height: 2),
          Text(
            account.lastError!,
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.orangeAccent),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (account.viewerId != null) ...[
          const SizedBox(height: 2),
          Text('viewerId ${account.viewerId}', style: theme.textTheme.bodySmall),
        ],
        if (account.phone?.trim().isNotEmpty == true) ...[
          const SizedBox(height: 2),
          Text(account.phone!.trim(), style: theme.textTheme.bodySmall),
        ],
        const SizedBox(height: 16),
        Text(
          'Группы и чаты — на соседних вкладках. Здесь только сам аккаунт.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => state.setBrowserDrawerOpen(true),
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('Открыть MAX'),
        ),
        const SizedBox(height: 20),
        Text('Кратко', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        _StatTile(
          icon: Icons.folder_outlined,
          label: 'Групп на карте',
          value: '${groups.length}',
        ),
        _StatTile(
          icon: Icons.chat_bubble_outline,
          label: 'Чатов в группах',
          value: '$totalChats',
        ),
        _StatTile(
          icon: Icons.vpn_key_outlined,
          label: 'Прокси',
          value: (account.isolation.proxyServer?.trim().isNotEmpty == true) ? 'есть' : 'нет',
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, size: 20),
      title: Text(label, style: const TextStyle(fontSize: 13)),
      trailing: Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }
}
