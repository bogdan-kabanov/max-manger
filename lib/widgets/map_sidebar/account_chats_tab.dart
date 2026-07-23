import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/account_map_state.dart';
import '../../models/map_workflow.dart';
import '../../providers/app_state.dart';
import 'map_chat_checkbox_list.dart';

/// Chats page: catalogs are loaded and shown **per mother** — never mixed.
class AccountChatsTab extends StatefulWidget {
  const AccountChatsTab({super.key, this.focusAccountId});

  /// Optional: expand the cluster that contains this account.
  final String? focusAccountId;

  @override
  State<AccountChatsTab> createState() => _AccountChatsTabState();
}

class _AccountChatsTabState extends State<AccountChatsTab> {
  /// clusterId → selected map-group id for assignment
  final Map<String, String?> _groupByCluster = {};

  /// clusterId → selected chat titles for that mother's map-group
  final Map<String, Set<String>> _selectedByCluster = {};

  /// clusterId → dirty flag
  final Map<String, bool> _dirtyByCluster = {};

  /// motherAccountId currently loading
  final Set<String> _loadingMothers = {};

  String? _expandedClusterId;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = context.read<AppState>();
    _ensureExpanded(state);
    _syncSelections(state);
  }

  void _ensureExpanded(AppState state) {
    if (_expandedClusterId != null) return;
    final focus = widget.focusAccountId ?? state.selectedAccount?.id;
    if (focus != null) {
      final cluster = state.clusterContainingAccount(focus);
      if (cluster != null) {
        _expandedClusterId = cluster.id;
        return;
      }
    }
    if (state.motherClusters.isNotEmpty) {
      _expandedClusterId = state.motherClusters.first.id;
    }
  }

  void _syncSelections(AppState state) {
    for (final cluster in state.motherClusters) {
      final motherId = cluster.motherAccountId;
      if (motherId == null) continue;
      final groups = state.groupsForAccount(motherId);
      var groupId = _groupByCluster[cluster.id];
      if (groupId != null && !groups.any((g) => g.id == groupId)) {
        groupId = null;
      }
      groupId ??= groups.isNotEmpty ? groups.first.id : null;
      _groupByCluster[cluster.id] = groupId;
      if (groupId != null && !(_dirtyByCluster[cluster.id] ?? false)) {
        final node = state.workflowNodes.byId(groupId);
        _selectedByCluster[cluster.id] = {...?node?.group?.targetChats};
      } else {
        _selectedByCluster.putIfAbsent(cluster.id, () => {});
      }
    }
  }

  Future<void> _loadMother(AppState state, String motherId) async {
    setState(() => _loadingMothers.add(motherId));
    try {
      await state.refreshAccountChatCatalog(motherId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Чаты матки «${state.accountById(motherId)?.label ?? motherId}» обновлены',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _loadingMothers.remove(motherId));
    }
  }

  Future<void> _loadAllMothers(AppState state) async {
    final mothers = state.motherClusters
        .map((c) => c.motherAccountId)
        .whereType<String>()
        .toList();
    for (final id in mothers) {
      if (!mounted) return;
      await _loadMother(state, id);
    }
  }

  Future<void> _saveCluster(AppState state, MotherCluster cluster) async {
    final groupId = _groupByCluster[cluster.id];
    if (groupId == null) return;
    final node = state.workflowNodes.byId(groupId);
    if (node == null || !node.isGroup) return;

    final chats = (_selectedByCluster[cluster.id] ?? {}).toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    await state.updateWorkflowNode(
      node.copyWith(group: GroupWorkflowConfig(targetChats: chats)),
    );
    if (!mounted) return;
    setState(() => _dirtyByCluster[cluster.id] = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Чаты сохранены · ${cluster.name}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final clusters = state.motherClusters
        .where((c) => c.motherAccountId != null)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Чаты по маткам',
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'У каждой матки свой каталог MAX. Чаты разных маток не смешиваются.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              if (clusters.isNotEmpty)
                FilledButton.tonalIcon(
                  onPressed: _loadingMothers.isNotEmpty ? null : () => _loadAllMothers(state),
                  icon: _loadingMothers.isNotEmpty
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 18),
                  label: const Text('Загрузить все матки'),
                ),
            ],
          ),
        ),
        Expanded(
          child: clusters.isEmpty
              ? _NoMothersFallback(focusAccountId: widget.focusAccountId)
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  itemCount: clusters.length,
                  itemBuilder: (context, index) {
                    final cluster = clusters[index];
                    return _MotherChatsSection(
                      cluster: cluster,
                      expanded: _expandedClusterId == cluster.id,
                      onExpand: (open) => setState(() {
                        _expandedClusterId = open ? cluster.id : null;
                      }),
                      groupId: _groupByCluster[cluster.id],
                      selectedChats: _selectedByCluster[cluster.id] ?? {},
                      dirty: _dirtyByCluster[cluster.id] ?? false,
                      loading: _loadingMothers.contains(cluster.motherAccountId),
                      onGroupChanged: (id) {
                        final node = id != null ? state.workflowNodes.byId(id) : null;
                        setState(() {
                          _groupByCluster[cluster.id] = id;
                          _selectedByCluster[cluster.id] = {...?node?.group?.targetChats};
                          _dirtyByCluster[cluster.id] = false;
                        });
                        if (id != null) state.selectWorkflowNode(id);
                      },
                      onChatsChanged: (next) => setState(() {
                        _selectedByCluster[cluster.id] = next;
                        _dirtyByCluster[cluster.id] = true;
                      }),
                      onLoad: () => _loadMother(state, cluster.motherAccountId!),
                      onSave: () => _saveCluster(state, cluster),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _MotherChatsSection extends StatelessWidget {
  const _MotherChatsSection({
    required this.cluster,
    required this.expanded,
    required this.onExpand,
    required this.groupId,
    required this.selectedChats,
    required this.dirty,
    required this.loading,
    required this.onGroupChanged,
    required this.onChatsChanged,
    required this.onLoad,
    required this.onSave,
  });

  final MotherCluster cluster;
  final bool expanded;
  final ValueChanged<bool> onExpand;
  final String? groupId;
  final Set<String> selectedChats;
  final bool dirty;
  final bool loading;
  final ValueChanged<String?> onGroupChanged;
  final ValueChanged<Set<String>> onChatsChanged;
  final VoidCallback onLoad;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final motherId = cluster.motherAccountId!;
    final mother = state.accountById(motherId);
    final channels = state.motherChannelsForAccount(motherId);
    final titles = state.availableChatsForAccount(motherId);
    final mapGroups = state.groupsForAccount(motherId);
    final hasToken = mother?.hasApiSession == true;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: expanded,
        onExpansionChanged: onExpand,
        maintainState: true,
        leading: Icon(Icons.hive_outlined, color: theme.colorScheme.primary),
        title: Text(
          cluster.name,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        ),
        subtitle: Text(
          '${mother?.label ?? motherId} · ${channels.length} чатов · '
          '${cluster.childAccountIds.length} дочерних',
          style: theme.textTheme.bodySmall,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!hasToken)
                  Text(
                    'У матки нет токена — добавьте API-сессию в «Профили».',
                    style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
                  )
                else ...[
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Каталог только этой матки',
                          style: theme.textTheme.labelMedium,
                        ),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: loading ? null : onLoad,
                        icon: loading
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.download, size: 16),
                        label: const Text('Загрузить'),
                        style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (mapGroups.isEmpty)
                    Text(
                      'Создайте группу на карте для матки «${mother?.label ?? ''}» '
                      '(страница «Группы»), чтобы назначить чаты.',
                      style: theme.textTheme.bodySmall,
                    )
                  else ...[
                    InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Группа на карте (этой матки)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: groupId != null && mapGroups.any((g) => g.id == groupId)
                              ? groupId
                              : null,
                          hint: const Text('Выберите группу'),
                          items: [
                            for (final g in mapGroups)
                              DropdownMenuItem(
                                value: g.id,
                                child: Text(
                                  '${g.title} (${g.group?.targetChats.length ?? 0})',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: onGroupChanged,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    MapChatCheckboxList(
                      availableChats: titles,
                      selectedChats: selectedChats,
                      onChanged: onChatsChanged,
                      emptyHint: channels.isEmpty
                          ? 'Нажмите «Загрузить», чтобы получить чаты этой матки из MAX.'
                          : null,
                    ),
                    if (channels.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        'id · тип — только для контроля, выбор по названию',
                        style: theme.textTheme.bodySmall?.copyWith(fontSize: 10, color: Colors.white54),
                      ),
                      const SizedBox(height: 4),
                      ...channels.take(3).map(
                            (c) => Text(
                              '${c.title} · ${c.chatId}${c.type != null ? ' · ${c.type}' : ''}',
                              style: const TextStyle(fontSize: 10, fontFamily: 'Consolas', color: Colors.white38),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      if (channels.length > 3)
                        Text(
                          '… ещё ${channels.length - 3}',
                          style: const TextStyle(fontSize: 10, color: Colors.white38),
                        ),
                    ],
                    const SizedBox(height: 10),
                    FilledButton(
                      onPressed: dirty && groupId != null ? onSave : null,
                      child: Text(dirty ? 'Сохранить чаты матки' : 'Сохранено'),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// No mother clusters yet — fall back to selected/focus account catalog.
class _NoMothersFallback extends StatefulWidget {
  const _NoMothersFallback({this.focusAccountId});

  final String? focusAccountId;

  @override
  State<_NoMothersFallback> createState() => _NoMothersFallbackState();
}

class _NoMothersFallbackState extends State<_NoMothersFallback> {
  String? _groupId;
  Set<String> _selected = {};
  bool _dirty = false;
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final accountId = widget.focusAccountId ?? state.selectedAccount?.id;
    if (accountId == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Сначала создайте кластер во вкладке «Раздача»\n'
            'или выберите аккаунт в «Профили».',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      );
    }

    final account = state.accountById(accountId);
    final catalogId = state.chatCatalogAccountId(accountId);
    final catalogAccount = state.accountById(catalogId);
    final groups = state.groupsForAccount(accountId);
    final titles = state.availableChatsForAccount(accountId);

    _groupId ??= groups.isNotEmpty ? groups.first.id : null;
    if (_groupId != null && !_dirty) {
      final node = state.workflowNodes.byId(_groupId!);
      _selected = {...?node?.group?.targetChats};
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Маток пока нет. Чаты грузятся для аккаунта '
          '«${catalogAccount?.label ?? account?.label ?? accountId}».',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Text(
          'Создайте кластер во вкладке «Раздача» — тогда чаты разделятся по аккаунтам.',
          style: theme.textTheme.bodySmall?.copyWith(color: Colors.white54),
        ),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          onPressed: _loading || catalogAccount?.hasApiSession != true
              ? null
              : () async {
                  setState(() => _loading = true);
                  try {
                    await state.refreshAccountChatCatalog(accountId);
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
                    }
                  } finally {
                    if (mounted) setState(() => _loading = false);
                  }
                },
          icon: _loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh, size: 18),
          label: const Text('Загрузить чаты'),
        ),
        const SizedBox(height: 12),
        if (groups.isEmpty)
          const Text('Создайте группу на странице «Группы».')
        else ...[
          InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Группа на карте',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                value: _groupId,
                items: [
                  for (final g in groups)
                    DropdownMenuItem(value: g.id, child: Text(g.title)),
                ],
                onChanged: (id) {
                  final node = id != null ? state.workflowNodes.byId(id) : null;
                  setState(() {
                    _groupId = id;
                    _selected = {...?node?.group?.targetChats};
                    _dirty = false;
                  });
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          MapChatCheckboxList(
            availableChats: titles,
            selectedChats: _selected,
            onChanged: (next) => setState(() {
              _selected = next;
              _dirty = true;
            }),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _dirty && _groupId != null
                ? () async {
                    final node = state.workflowNodes.byId(_groupId!);
                    if (node == null) return;
                    final chats = _selected.toList()
                      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
                    await state.updateWorkflowNode(
                      node.copyWith(group: GroupWorkflowConfig(targetChats: chats)),
                    );
                    if (!mounted) return;
                    setState(() => _dirty = false);
                  }
                : null,
            child: Text(_dirty ? 'Сохранить' : 'Сохранено'),
          ),
        ],
      ],
    );
  }
}
