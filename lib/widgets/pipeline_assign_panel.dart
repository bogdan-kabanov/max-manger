import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/account_map_state.dart';
import '../models/max_account.dart';
import '../models/max_channel_catalog_entry.dart';
import '../providers/app_state.dart';

enum _AssignFilter { free, mother, all }

/// Soft-assign parsed catalog groups to matkas (no join).
class PipelineAssignPanel extends StatefulWidget {
  const PipelineAssignPanel({super.key});

  @override
  State<PipelineAssignPanel> createState() => _PipelineAssignPanelState();
}

class _PipelineAssignPanelState extends State<PipelineAssignPanel> {
  String? _selectedMotherId;
  _AssignFilter _filter = _AssignFilter.free;
  final _selectedChatIds = <String>{};
  String _query = '';

  void _ensureMother(AppState state) {
    final mothers = _mothers(state);
    if (mothers.isEmpty) {
      _selectedMotherId = null;
      return;
    }
    if (_selectedMotherId == null ||
        !mothers.any((m) => m.id == _selectedMotherId)) {
      _selectedMotherId = mothers.first.id;
    }
  }

  List<MaxAccount> _mothers(AppState state) {
    final out = <MaxAccount>[];
    for (final c in state.motherClusters) {
      final id = c.motherAccountId;
      if (id == null) continue;
      final a = state.accountById(id);
      if (a != null) out.add(a);
    }
    return out;
  }

  MotherCluster? _clusterForMother(AppState state, String motherId) {
    for (final c in state.motherClusters) {
      if (c.motherAccountId == motherId) return c;
    }
    return null;
  }

  List<MaxChannelCatalogEntry> _filtered(AppState state) {
    var list = state.channelCatalog;
    switch (_filter) {
      case _AssignFilter.free:
        list = list.where((e) => !e.isAssigned).toList();
      case _AssignFilter.mother:
        final mid = _selectedMotherId;
        list = mid == null
            ? const []
            : list.where((e) => e.assignedMotherAccountId == mid).toList();
      case _AssignFilter.all:
        break;
    }
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list
          .where(
            (e) =>
                e.title.toLowerCase().contains(q) ||
                e.chatId.contains(q) ||
                (e.inviteHash?.toLowerCase().contains(q) ?? false),
          )
          .toList();
    }
    return list;
  }

  String _motherLabel(AppState state, String? motherId) {
    if (motherId == null || motherId.isEmpty) return 'свободна';
    return state.accountById(motherId)?.label ?? motherId;
  }

  Future<void> _assign(AppState state, {required bool clear}) async {
    if (_selectedChatIds.isEmpty) return;
    final motherId = clear ? null : _selectedMotherId;
    if (!clear && motherId == null) return;

    // Confirm overwrite when assigning groups already owned by another matka.
    if (!clear) {
      final conflicts = state.channelCatalog
          .where(
            (e) =>
                _selectedChatIds.contains(e.chatId) &&
                e.isAssigned &&
                e.assignedMotherAccountId != motherId,
          )
          .toList();
      if (conflicts.isNotEmpty && mounted) {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Переназначить группы?'),
            content: Text(
              '${conflicts.length} уже закреплены за другой маткой. Перенести?',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Перенести')),
            ],
          ),
        );
        if (ok != true) return;
      }
    }

    await state.assignCatalogGroupsToMother(
      chatIds: _selectedChatIds.toList(),
      motherAccountId: motherId,
    );
    if (!mounted) return;
    setState(() => _selectedChatIds.clear());
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _ensureMother(state);
    final mothers = _mothers(state);
    final entries = _filtered(state);
    final scheme = Theme.of(context).colorScheme;
    final freeCount = state.channelCatalog.where((e) => !e.isAssigned).length;
    final assignedToSelected = _selectedMotherId == null
        ? 0
        : state.channelCatalog
            .where((e) => e.assignedMotherAccountId == _selectedMotherId)
            .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Раздача групп',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'Назначьте спарсенные группы маткам. Вступление позже — на шаге «Запуск».',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        if (mothers.isEmpty)
          const Expanded(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Нет маток. Создайте кластер матка→дочки на карте профилей.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DropdownButtonFormField<String>(
              value: _selectedMotherId,
              decoration: const InputDecoration(
                labelText: 'Матка',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final m in mothers)
                  DropdownMenuItem(
                    value: m.id,
                    child: Text(
                      '${m.label} · ${_clusterForMother(state, m.id)?.childAccountIds.length ?? 0} дочек · '
                      '${state.channelCatalog.where((e) => e.assignedMotherAccountId == m.id).length} групп',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) => setState(() {
                _selectedMotherId = v;
                if (_filter == _AssignFilter.mother) _selectedChatIds.clear();
              }),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 6,
              children: [
                FilterChip(
                  label: Text('Свободные ($freeCount)'),
                  selected: _filter == _AssignFilter.free,
                  onSelected: (_) => setState(() {
                    _filter = _AssignFilter.free;
                    _selectedChatIds.clear();
                  }),
                ),
                FilterChip(
                  label: Text('Эта матка ($assignedToSelected)'),
                  selected: _filter == _AssignFilter.mother,
                  onSelected: (_) => setState(() {
                    _filter = _AssignFilter.mother;
                    _selectedChatIds.clear();
                  }),
                ),
                FilterChip(
                  label: Text('Все (${state.channelCatalog.length})'),
                  selected: _filter == _AssignFilter.all,
                  onSelected: (_) => setState(() {
                    _filter = _AssignFilter.all;
                    _selectedChatIds.clear();
                  }),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Поиск…',
                isDense: true,
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.search, size: 18),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                TextButton(
                  onPressed: entries.isEmpty
                      ? null
                      : () => setState(() {
                            _selectedChatIds
                              ..clear()
                              ..addAll(entries.map((e) => e.chatId));
                          }),
                  child: const Text('Выбрать все'),
                ),
                TextButton(
                  onPressed: _selectedChatIds.isEmpty
                      ? null
                      : () => setState(() => _selectedChatIds.clear()),
                  child: const Text('Сбросить выбор'),
                ),
                const Spacer(),
                Text(
                  'Выбрано: ${_selectedChatIds.length}',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Text(
                      state.channelCatalog.isEmpty
                          ? 'Каталог пуст — сначала шаг «Парсинг»'
                          : 'Нет групп по фильтру',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    itemCount: entries.length,
                    itemBuilder: (context, i) {
                      final e = entries[i];
                      final selected = _selectedChatIds.contains(e.chatId);
                      final badge = e.isAssigned
                          ? _motherLabel(state, e.assignedMotherAccountId)
                          : 'свободна';
                      final badgeColor = e.isAssigned
                          ? (e.assignedMotherAccountId == _selectedMotherId
                              ? scheme.primaryContainer
                              : scheme.tertiaryContainer)
                          : scheme.surfaceContainerHighest;
                      return CheckboxListTile(
                        dense: true,
                        value: selected,
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _selectedChatIds.add(e.chatId);
                          } else {
                            _selectedChatIds.remove(e.chatId);
                          }
                        }),
                        title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [
                            if (e.hasInviteLink) 'ссылка ✓' else 'нет ссылки',
                            e.chatId,
                          ].join(' · '),
                          style: const TextStyle(fontSize: 11),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        secondary: Chip(
                          label: Text(badge, style: const TextStyle(fontSize: 10)),
                          visualDensity: VisualDensity.compact,
                          backgroundColor: badgeColor,
                          padding: EdgeInsets.zero,
                          labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _selectedChatIds.isEmpty || _selectedMotherId == null
                        ? null
                        : () => _assign(state, clear: false),
                    icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                    label: const Text('Назначить матке'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _selectedChatIds.isEmpty
                      ? null
                      : () => _assign(state, clear: true),
                  icon: const Icon(Icons.bookmark_remove_outlined, size: 18),
                  label: const Text('Снять с матки'),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
