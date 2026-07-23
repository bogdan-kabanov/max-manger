import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/max_account.dart';
import '../../providers/app_state.dart';
import '../../services/max_auth_service.dart';

/// Slim account identity tab — profile fields for the selected account.
class AccountMapPanel extends StatefulWidget {
  const AccountMapPanel({super.key, required this.accountId});

  final String accountId;

  @override
  State<AccountMapPanel> createState() => _AccountMapPanelState();
}

class _AccountMapPanelState extends State<AccountMapPanel> {
  bool _refreshing = false;

  Future<void> _refreshProfile(MaxAccount account) async {
    setState(() => _refreshing = true);
    final result = await context.read<AppState>().refreshAccountProfile(account);
    if (!mounted) return;
    setState(() => _refreshing = false);
    final fresh = context.read<AppState>().accountById(account.id);
    final phone = fresh?.phone?.trim();
    final id = fresh?.viewerId;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.ok
              ? [
                  'Инфо обновлено',
                  if (phone != null && phone.isNotEmpty) phone,
                  if (id != null) 'id $id',
                ].join(' · ')
              : (result.error ?? 'Не удалось обновить'),
        ),
      ),
    );
  }

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label скопирован'), duration: const Duration(seconds: 2)),
    );
  }

  String _authLabel(MaxAuthMethod method) {
    return switch (method) {
      MaxAuthMethod.qr => 'QR',
      MaxAuthMethod.sms => 'SMS',
      MaxAuthMethod.token => 'токен',
    };
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final account = state.accountById(widget.accountId);
    if (account == null) {
      return const Center(child: Text('Аккаунт не найден'));
    }

    final theme = Theme.of(context);
    final groups = state.groupsForAccount(widget.accountId);
    final totalChats = groups.fold<int>(
      0,
      (sum, g) => sum + (g.group?.targetChats.length ?? 0),
    );
    final phone = account.phone?.trim();
    final token = account.apiToken;

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
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            if (account.hasApiSession)
              IconButton(
                tooltip: 'Обновить инфо с MAX',
                onPressed: _refreshing ? null : () => _refreshProfile(account),
                icon: _refreshing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync, size: 20),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text('Данные профиля', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        _ProfileRow(
          label: 'имя',
          value: (account.firstName?.trim().isNotEmpty == true)
              ? account.firstName!.trim()
              : '—',
          onCopy: account.firstName?.trim().isNotEmpty == true
              ? () => _copy('Имя', account.firstName!.trim())
              : null,
        ),
        _ProfileRow(
          label: 'фамилия',
          value: (account.lastName?.trim().isNotEmpty == true)
              ? account.lastName!.trim()
              : '—',
          onCopy: account.lastName?.trim().isNotEmpty == true
              ? () => _copy('Фамилия', account.lastName!.trim())
              : null,
        ),
        _ProfileRow(
          label: 'описание',
          value: (account.description?.trim().isNotEmpty == true)
              ? account.description!.trim()
              : '—',
          onCopy: account.description?.trim().isNotEmpty == true
              ? () => _copy('Описание', account.description!.trim())
              : null,
        ),
        _ProfileRow(
          label: 'телефон',
          value: (phone != null && phone.isNotEmpty) ? phone : '—',
          onCopy: (phone != null && phone.isNotEmpty) ? () => _copy('Телефон', phone) : null,
        ),
        _ProfileRow(
          label: 'viewerId',
          value: account.viewerId?.toString() ?? '—',
          onCopy: account.viewerId != null
              ? () => _copy('viewerId', '${account.viewerId}')
              : null,
        ),
        _ProfileRow(
          label: 'статус',
          value: account.healthStatus.longLabel,
        ),
        _ProfileRow(
          label: 'вход',
          value: _authLabel(account.authMethod),
        ),
        _ProfileRow(
          label: 'токен',
          value: token != null && token.isNotEmpty
              ? MaxAuthService.tokenPreview(token)
              : 'нет',
          onCopy: token != null && token.isNotEmpty ? () => _copy('Токен', token) : null,
        ),
        _ProfileRow(
          label: 'прокси',
          value: (account.isolation.proxyServer?.trim().isNotEmpty == true) ? 'есть' : 'нет',
        ),
        if (account.lastError != null && account.healthStatus.isProblem)
          _ProfileRow(label: 'ошибка', value: account.lastError!),
        if (account.isUzbek) const _ProfileRow(label: 'регион', value: 'UZ (+998)'),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => state.setBrowserDrawerOpen(true),
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('Открыть MAX'),
        ),
        const SizedBox(height: 20),
        Text('На карте', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        _StatTile(
          icon: Icons.folder_outlined,
          label: 'Групп',
          value: '${groups.length}',
        ),
        _StatTile(
          icon: Icons.chat_bubble_outline,
          label: 'Чатов в группах',
          value: '$totalChats',
        ),
      ],
    );
  }
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.label,
    required this.value,
    this.onCopy,
  });

  final String label;
  final String value;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
          if (onCopy != null)
            IconButton(
              onPressed: onCopy,
              icon: const Icon(Icons.copy, size: 14),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              tooltip: 'Копировать',
            ),
        ],
      ),
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
