import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/map_workflow.dart';
import '../../providers/app_state.dart';
import 'map_chat_checkbox_list.dart';

class GroupMapPanel extends StatefulWidget {
  const GroupMapPanel({
    super.key,
    required this.node,
    this.includeChats = true,
    this.onBack,
  });

  final MapWorkflowNode node;
  final bool includeChats;
  final VoidCallback? onBack;

  @override
  State<GroupMapPanel> createState() => _GroupMapPanelState();
}

class _GroupMapPanelState extends State<GroupMapPanel> {
  late TextEditingController _title;
  late Set<String> _selectedChats;
  bool _loadingCatalog = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.node.title);
    _selectedChats = {...?widget.node.group?.targetChats};
    if (widget.includeChats) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _autoLoadCatalogIfNeeded());
    }
  }

  void _autoLoadCatalogIfNeeded() {
    if (!mounted || _loadingCatalog) return;
    final state = context.read<AppState>();
    final ownerId = _ownerAccountId(state);
    if (ownerId == null) return;
    final account = state.accountById(ownerId);
    if (account?.hasApiSession != true) return;
    if (state.availableChatsForAccount(ownerId).isNotEmpty) return;
    _refreshCatalog(state);
  }

  @override
  void didUpdateWidget(covariant GroupMapPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.id != widget.node.id) {
      _title.text = widget.node.title;
      _selectedChats = {...?widget.node.group?.targetChats};
    }
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  String? _ownerAccountId(AppState state) => state.ownerAccountIdForGroup(widget.node.id);

  Future<void> _refreshCatalog(AppState state) async {
    final ownerId = _ownerAccountId(state) ?? state.selectedAccount?.id;
    if (ownerId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сначала привяжите группу к аккаунту')),
      );
      return;
    }
    setState(() => _loadingCatalog = true);
    try {
      await state.refreshAccountChatCatalog(ownerId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Список групп обновлён')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingCatalog = false);
    }
  }

  Future<void> _save(AppState state) async {
    final chats = widget.includeChats
        ? (_selectedChats.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase())))
        : (widget.node.group?.targetChats ?? const <String>[]);
    await state.updateWorkflowNode(
      widget.node.copyWith(
        title: _title.text.trim().isEmpty ? widget.node.title : _title.text.trim(),
        group: GroupWorkflowConfig(targetChats: chats),
      ),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Группа сохранена')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final ownerId = _ownerAccountId(state);
    final owner = ownerId != null ? state.accountById(ownerId) : null;
    final broadcasts = state.broadcastsInGroup(widget.node.id);
    final availableChats = ownerId != null ? state.availableChatsForAccount(ownerId) : const <String>[];
    final chatCount = widget.node.group?.targetChats.length ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.onBack != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back, size: 18),
                label: const Text('К списку групп'),
              ),
            ),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            children: [
              Row(
                children: [
                  Icon(Icons.folder_outlined, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Группа',
                      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              if (owner != null) ...[
                const SizedBox(height: 4),
                Text('Аккаунт: ${owner.label}', style: theme.textTheme.bodySmall),
              ] else if (state.selectedAccount != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => state.linkGroupToAccount(
                    groupId: widget.node.id,
                    accountId: state.selectedAccount!.id,
                  ),
                  icon: const Icon(Icons.link, size: 18),
                  label: Text('Привязать к «${state.selectedAccount!.label}»'),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: 'Название на карте',
                  border: OutlineInputBorder(),
                ),
              ),
              if (!widget.includeChats) ...[
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.chat_bubble_outline),
                    title: Text('Чаты: $chatCount'),
                    subtitle: const Text('Выбор чатов — на вкладке «Чаты»'),
                    dense: true,
                  ),
                ),
              ],
              if (widget.includeChats) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Группы MAX',
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _loadingCatalog || ownerId == null ? null : () => _refreshCatalog(state),
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
                const SizedBox(height: 4),
                Text(
                  'Отметьте чекбоксами, в каких группах работает бот. Список подгружается из MAX аккаунта.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                MapChatCheckboxList(
                  availableChats: availableChats,
                  selectedChats: _selectedChats,
                  onChanged: (next) => setState(() => _selectedChats = next),
                  emptyHint: ownerId == null
                      ? 'Привяжите карточку к аккаунту, затем нажмите «Загрузить».'
                      : owner?.hasApiSession != true
                          ? 'У аккаунта нет токена — добавьте API-сессию.'
                          : 'Нажмите «Загрузить», чтобы получить группы из MAX.',
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      await state.deleteWorkflowNode(widget.node.id);
                    },
                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                    label: const Text('Удалить', style: TextStyle(color: Colors.redAccent)),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => _save(state),
                    child: const Text('Сохранить'),
                  ),
                ],
              ),
              const Divider(height: 32),
              Row(
                children: [
                  Text('Рассылки (${broadcasts.length})', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  FilledButton.tonalIcon(
                    onPressed: () => state.addWorkflowBroadcast(parentGroupId: widget.node.id),
                    icon: const Icon(Icons.campaign_outlined, size: 18),
                    label: const Text('Создать'),
                    style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (broadcasts.isEmpty)
                Text(
                  'Рассылок пока нет. Создайте — она привяжется к этой группе.',
                  style: theme.textTheme.bodySmall,
                )
              else
                ...broadcasts.map(
                  (b) => Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: Icon(Icons.campaign_outlined, color: theme.colorScheme.tertiary),
                      title: Text(b.title),
                      subtitle: Text(
                        '${b.broadcast?.steps.length ?? 0} сообщ. · '
                        '${b.broadcast?.targetChats.length ?? 0} чатов в рассылке',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => state.selectWorkflowNode(b.id),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
