import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/map_workflow.dart';
import '../../providers/app_state.dart';
import 'map_chat_checkbox_list.dart';

/// Pick MAX chats for the selected workflow group.
class AccountChatsTab extends StatefulWidget {
  const AccountChatsTab({super.key, required this.accountId});

  final String accountId;

  @override
  State<AccountChatsTab> createState() => _AccountChatsTabState();
}

class _AccountChatsTabState extends State<AccountChatsTab> {
  String? _activeGroupId;
  Set<String> _selectedChats = {};
  bool _loadingCatalog = false;
  bool _dirty = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncFromState(context.read<AppState>(), preferMapSelection: true);
  }

  void _syncFromState(AppState state, {bool preferMapSelection = false}) {
    final groups = state.groupsForAccount(widget.accountId);
    if (groups.isEmpty) {
      _activeGroupId = null;
      _selectedChats = {};
      _dirty = false;
      return;
    }

    String? nextId = _activeGroupId;
    if (preferMapSelection) {
      final selectedId = state.selectedWorkflowNodeId;
      if (selectedId != null) {
        final node = state.workflowNodes.byId(selectedId);
        if (node != null && node.isGroup && groups.any((g) => g.id == node.id)) {
          nextId = node.id;
        } else if (node != null && node.isBroadcast && node.parentGroupId != null) {
          if (groups.any((g) => g.id == node.parentGroupId)) {
            nextId = node.parentGroupId;
          }
        }
      }
    }

    nextId ??= groups.first.id;
    if (!groups.any((g) => g.id == nextId)) {
      nextId = groups.first.id;
    }

    if (nextId != _activeGroupId) {
      final group = groups.firstWhere((g) => g.id == nextId);
      _activeGroupId = nextId;
      _selectedChats = {...?group.group?.targetChats};
      _dirty = false;
    }
  }

  Future<void> _refreshCatalog(AppState state) async {
    setState(() => _loadingCatalog = true);
    try {
      await state.refreshAccountChatCatalog(widget.accountId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Список чатов обновлён')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _loadingCatalog = false);
    }
  }

  Future<void> _save(AppState state) async {
    final groupId = _activeGroupId;
    if (groupId == null) return;
    final node = state.workflowNodes.byId(groupId);
    if (node == null || !node.isGroup) return;

    final chats = _selectedChats.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    await state.updateWorkflowNode(
      node.copyWith(group: GroupWorkflowConfig(targetChats: chats)),
    );
    if (!mounted) return;
    setState(() => _dirty = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Чаты группы сохранены')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final account = state.accountById(widget.accountId);
    final groups = state.groupsForAccount(widget.accountId);

    // Keep local selection valid when groups change.
    if (_activeGroupId != null && !groups.any((g) => g.id == _activeGroupId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _syncFromState(state));
      });
    } else if (_activeGroupId == null && groups.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _syncFromState(state));
      });
    }

    if (groups.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Сначала создайте группу на вкладке «Группы», затем выберите чаты здесь.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      );
    }

    final availableChats = state.availableChatsForAccount(widget.accountId);
    final activeTitle = () {
      for (final g in groups) {
        if (g.id == _activeGroupId) return g.title;
      }
      return null;
    }();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Чаты',
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'Отметьте, в каких группах MAX работает бот для выбранной папки на карте.',
                style: theme.textTheme.bodySmall,
              ),
              if (account != null) ...[
                const SizedBox(height: 2),
                Text('Аккаунт: ${account.label}', style: theme.textTheme.bodySmall),
              ],
              const SizedBox(height: 12),
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Группа на карте',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: _activeGroupId,
                    items: [
                      for (final g in groups)
                        DropdownMenuItem(
                          value: g.id,
                          child: Text(
                            '${g.title} (${g.group?.targetChats.length ?? 0})',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (id) {
                      if (id == null) return;
                      final group = groups.firstWhere((g) => g.id == id);
                      setState(() {
                        _activeGroupId = id;
                        _selectedChats = {...?group.group?.targetChats};
                        _dirty = false;
                      });
                      state.selectWorkflowNode(id);
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  activeTitle == null ? 'Группы MAX' : 'Чаты · $activeTitle',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: _loadingCatalog || account?.hasApiSession != true
                    ? null
                    : () => _refreshCatalog(state),
                icon: _loadingCatalog
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18),
                label: const Text('Загрузить'),
                style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            children: [
              MapChatCheckboxList(
                availableChats: availableChats,
                selectedChats: _selectedChats,
                onChanged: (next) => setState(() {
                  _selectedChats = next;
                  _dirty = true;
                }),
                emptyHint: account?.hasApiSession != true
                    ? 'У аккаунта нет токена — добавьте API-сессию.'
                    : 'Нажмите «Загрузить», чтобы получить группы из MAX.',
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: FilledButton(
            onPressed: _dirty ? () => _save(state) : null,
            child: Text(_dirty ? 'Сохранить чаты' : 'Сохранено'),
          ),
        ),
      ],
    );
  }
}
