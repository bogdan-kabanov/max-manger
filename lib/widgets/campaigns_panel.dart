import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/account_map_state.dart';
import '../models/active_action.dart';
import '../models/join_message_template.dart';
import '../models/max_account.dart';
import '../models/pipeline_journal_event.dart';
import '../models/template_send_scope.dart';
import '../models/template_sent_record.dart';
import '../providers/app_state.dart';
import '../services/pipeline_group_planner.dart';
import 'join_template_chat_editor.dart';

/// Campaigns: who sends, templates, launch, send history.
class CampaignsPanel extends StatefulWidget {
  const CampaignsPanel({super.key});

  @override
  State<CampaignsPanel> createState() => _CampaignsPanelState();
}

class _CampaignsPanelState extends State<CampaignsPanel> {
  int _tabIndex = 0;
  String? _selectedTemplateId;

  void _ensureTemplate(AppState state) {
    final templates = state.joinMessageTemplates;
    if (templates.isEmpty) {
      _selectedTemplateId = null;
      return;
    }
    if (_selectedTemplateId == null ||
        !templates.any((t) => t.id == _selectedTemplateId)) {
      _selectedTemplateId = templates.first.id;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _ensureTemplate(state);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(
                  value: 0,
                  label: Text('Кто шлёт'),
                  icon: Icon(Icons.account_tree_outlined, size: 16),
                ),
                ButtonSegment(
                  value: 1,
                  label: Text('Шаблоны'),
                  icon: Icon(Icons.chat_bubble_outline, size: 16),
                ),
                ButtonSegment(
                  value: 2,
                  label: Text('Запуск'),
                  icon: Icon(Icons.play_arrow_outlined, size: 16),
                ),
                ButtonSegment(
                  value: 3,
                  label: Text('История'),
                  icon: Icon(Icons.history, size: 16),
                ),
              ],
              selected: {_tabIndex},
              onSelectionChanged: (v) => setState(() => _tabIndex = v.first),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: switch (_tabIndex) {
            1 => _TemplatesTab(
                selectedTemplateId: _selectedTemplateId,
                onSelect: (id) => setState(() => _selectedTemplateId = id),
              ),
            2 => _LaunchTab(selectedTemplateId: _selectedTemplateId),
            3 => const _HistoryTab(),
            _ => _WhoSendsTab(
                selectedTemplateId: _selectedTemplateId,
                onSelectTemplate: (id) => setState(() => _selectedTemplateId = id),
              ),
          },
        ),
      ],
    );
  }
}

// ─── Кто шлёт ───────────────────────────────────────────────────────────────

class _WhoSendsTab extends StatelessWidget {
  const _WhoSendsTab({
    required this.selectedTemplateId,
    required this.onSelectTemplate,
  });

  final String? selectedTemplateId;
  final ValueChanged<String> onSelectTemplate;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final clusters = state.motherClusters;
    final templates = state.joinMessageTemplates;

    if (clusters.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Сначала создайте родительский кластер во вкладке «Аккаунты».',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54),
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: clusters.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final cluster = clusters[i];
        final mother = cluster.motherAccountId == null
            ? null
            : state.accountById(cluster.motherAccountId!);
        final mode = cluster.effectiveSendMode;
        final assignedTemplateId = _clusterTemplateId(state, cluster);
        final writers = _writerLabels(state, cluster);

        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      cluster.isSolo ? Icons.person_outline : Icons.account_tree_outlined,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            mother?.label ?? cluster.name,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                          Text(
                            cluster.isSolo
                                ? 'Родитель без дочерних — шлёт сам'
                                : 'Дочерних: ${cluster.childCount}',
                            style: const TextStyle(fontSize: 12, color: Colors.white54),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Кто отправляет сообщения',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                SegmentedButton<ClusterSendMode>(
                  segments: [
                    const ButtonSegment(
                      value: ClusterSendMode.parent,
                      label: Text('Родитель'),
                      icon: Icon(Icons.person, size: 16),
                    ),
                    ButtonSegment(
                      value: ClusterSendMode.children,
                      label: const Text('Дочерние'),
                      icon: const Icon(Icons.groups, size: 16),
                      enabled: !cluster.isSolo,
                    ),
                  ],
                  selected: {mode},
                  onSelectionChanged: (v) async {
                    if (cluster.isSolo) return;
                    await state.applyClusterCampaignConfig(
                      clusterId: cluster.id,
                      sendMode: v.first,
                      templateId: assignedTemplateId ?? selectedTemplateId,
                    );
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  value: assignedTemplateId ??
                      (templates.any((t) => t.id == selectedTemplateId)
                          ? selectedTemplateId
                          : null),
                  decoration: const InputDecoration(
                    labelText: 'Шаблон сообщений',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Не назначен'),
                    ),
                    for (final t in templates)
                      DropdownMenuItem<String?>(
                        value: t.id,
                        child: Text(
                          '${t.name}${t.isActive ? '' : ' (выкл)'} · ${t.messageCount} сообщ.',
                        ),
                      ),
                  ],
                  onChanged: (v) async {
                    if (v != null) onSelectTemplate(v);
                    await state.applyClusterCampaignConfig(
                      clusterId: cluster.id,
                      sendMode: mode,
                      templateId: v,
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          v == null
                              ? 'Шаблон снят'
                              : 'Шаблон назначен · ${mode.label}',
                        ),
                      ),
                    );
                  },
                ),
                if (writers.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Будут слать: ${writers.join(', ')}',
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  String? _clusterTemplateId(AppState state, MotherCluster cluster) {
    final mid = cluster.motherAccountId;
    if (cluster.effectiveSendMode == ClusterSendMode.parent && mid != null) {
      return state.joinTemplateByAccountId[mid];
    }
    for (final id in cluster.childAccountIds) {
      final t = state.joinTemplateByAccountId[id];
      if (t != null) return t;
    }
    if (mid != null) return state.joinTemplateByAccountId[mid];
    return null;
  }

  List<String> _writerLabels(AppState state, MotherCluster cluster) {
    final ids = <String>{};
    if (cluster.effectiveSendMode == ClusterSendMode.parent) {
      if (cluster.motherAccountId != null) ids.add(cluster.motherAccountId!);
    } else {
      ids.addAll(cluster.childAccountIds);
    }
    return [
      for (final id in ids)
        if (state.accountById(id) != null) state.accountById(id)!.label,
    ];
  }
}

// ─── Шаблоны ────────────────────────────────────────────────────────────────

class _TemplatesTab extends StatefulWidget {
  const _TemplatesTab({
    required this.selectedTemplateId,
    required this.onSelect,
  });

  final String? selectedTemplateId;
  final ValueChanged<String> onSelect;

  @override
  State<_TemplatesTab> createState() => _TemplatesTabState();
}

class _TemplatesTabState extends State<_TemplatesTab> {
  int _viewIndex = 0; // 0 = chat, 1 = already sent

  Future<void> _add() async {
    final t = await context.read<AppState>().addJoinMessageTemplate();
    if (!mounted) return;
    widget.onSelect(t.id);
    setState(() => _viewIndex = 0);
  }

  Future<void> _rename(JoinMessageTemplate template) async {
    final ctrl = TextEditingController(text: template.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Название шаблона'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Название',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () {
              final v = ctrl.text.trim();
              if (v.isEmpty) return;
              Navigator.pop(ctx, v);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || !mounted) return;
    await context.read<AppState>().updateJoinMessageTemplate(
          template.copyWith(name: name),
        );
  }

  Future<void> _delete(JoinMessageTemplate template) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить шаблон?'),
        content: Text('«${template.name}» будет снят со всех аккаунтов.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppState>().removeJoinMessageTemplate(template.id);
  }

  Future<void> _applyOneClick(AppState state, JoinMessageTemplate template) async {
    final accounts = state.accounts;
    if (accounts.isEmpty) return;
    final selected = <String>{
      for (final a in accounts)
        if (state.joinTemplateByAccountId[a.id] == template.id) a.id,
    };

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: Text('Назначить «${template.name}»'),
              content: SizedBox(
                width: 420,
                height: 360,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Отметьте аккаунты — шаблон применится в 1 клик.',
                      style: TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        itemCount: accounts.length,
                        itemBuilder: (_, i) {
                          final a = accounts[i];
                          final checked = selected.contains(a.id);
                          return CheckboxListTile(
                            dense: true,
                            value: checked,
                            title: Text(a.label, style: const TextStyle(fontSize: 13)),
                            subtitle: Text(
                              state.isMotherAccount(a.id)
                                  ? 'родитель'
                                  : (state.isChildAccount(a.id) ? 'дочерний' : 'аккаунт'),
                              style: const TextStyle(fontSize: 11),
                            ),
                            onChanged: (v) {
                              setLocal(() {
                                if (v == true) {
                                  selected.add(a.id);
                                } else {
                                  selected.remove(a.id);
                                }
                              });
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text('Назначить (${selected.length})'),
                ),
              ],
            );
          },
        );
      },
    );
    if (ok != true || !mounted) return;

    final previous = [
      for (final e in state.joinTemplateByAccountId.entries)
        if (e.value == template.id) e.key,
    ];
    final toClear = previous.where((id) => !selected.contains(id));
    if (toClear.isNotEmpty) {
      await state.clearJoinTemplateForAccounts(toClear);
    }
    if (selected.isNotEmpty) {
      await state.applyJoinTemplateToAccounts(
        templateId: template.id,
        accountIds: selected,
      );
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Шаблон на ${selected.length} акк.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final templates = state.joinMessageTemplates;
    final selected = state.joinMessageTemplateById(widget.selectedTemplateId);
    final sentCount = selected == null
        ? 0
        : state.countTemplateSentHistory(selected.id);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: _add,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Создать'),
              ),
              const SizedBox(width: 8),
              if (selected != null)
                FilledButton.tonalIcon(
                  onPressed: () => _applyOneClick(state, selected),
                  icon: const Icon(Icons.bolt, size: 18),
                  label: const Text('Назначить аккаунтам'),
                ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Чат шаблона и таблица «уже слали» по группам / аккаунтам',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
              ),
            ],
          ),
        ),
        if (templates.isEmpty)
          const Expanded(
            child: Center(
              child: Text(
                'Создайте шаблон сообщений',
                style: TextStyle(color: Colors.white54),
              ),
            ),
          )
        else ...[
          SizedBox(
            height: 44,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              scrollDirection: Axis.horizontal,
              itemCount: templates.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, i) {
                final t = templates[i];
                return ChoiceChip(
                  selected: t.id == widget.selectedTemplateId,
                  label: Text(t.name),
                  onSelected: (_) {
                    widget.onSelect(t.id);
                    setState(() => _viewIndex = 0);
                  },
                );
              },
            ),
          ),
          if (selected != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      selected.name,
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                  ),
                  SegmentedButton<int>(
                    segments: [
                      const ButtonSegment(
                        value: 0,
                        label: Text('Чат'),
                        icon: Icon(Icons.chat_bubble_outline, size: 16),
                      ),
                      ButtonSegment(
                        value: 1,
                        label: Text('Уже слали ($sentCount)'),
                        icon: const Icon(Icons.table_rows_outlined, size: 16),
                      ),
                    ],
                    selected: {_viewIndex},
                    onSelectionChanged: (v) => setState(() => _viewIndex = v.first),
                  ),
                  const SizedBox(width: 8),
                  Switch(
                    value: selected.enabled,
                    onChanged: (v) => state.updateJoinMessageTemplate(
                      selected.copyWith(enabled: v),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Переименовать',
                    onPressed: () => _rename(selected),
                    icon: const Icon(Icons.drive_file_rename_outline),
                  ),
                  IconButton(
                    tooltip: 'Удалить',
                    onPressed: () => _delete(selected),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            ),
            if (_viewIndex == 0) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _GapField(
                      label: 'Пауза между чатами, сек',
                      ms: selected.chatGapMs,
                      onChanged: (ms) => state.updateJoinMessageTemplate(
                        selected.copyWith(chatGapMs: ms),
                      ),
                    ),
                    _GapField(
                      label: 'Пауза после вступления, сек',
                      ms: selected.delayMs,
                      onChanged: (ms) => state.updateJoinMessageTemplate(
                        selected.copyWith(delayMs: ms),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: JoinTemplateChatEditor(
                    key: ValueKey('chat-editor-${selected.id}'),
                    templateId: selected.id,
                  ),
                ),
              ),
            ] else
              Expanded(
                child: _SentHistoryTable(
                  templateId: selected.id,
                  showTemplateColumn: false,
                  emptyText: 'По шаблону «${selected.name}» ещё ничего не слали',
                  onClear: sentCount == 0
                      ? null
                      : () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Сбросить историю?'),
                              content: Text(
                                'У шаблона «${selected.name}» очистится список '
                                '«уже слали» ($sentCount).',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('Отмена'),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('Сбросить'),
                                ),
                              ],
                            ),
                          );
                          if (ok == true && context.mounted) {
                            await state.clearTemplateSentHistory(selected.id);
                          }
                        },
                ),
              ),
          ],
        ],
      ],
    );
  }
}

class _GapField extends StatefulWidget {
  const _GapField({
    required this.label,
    required this.ms,
    required this.onChanged,
  });

  final String label;
  final int ms;
  final ValueChanged<int> onChanged;

  @override
  State<_GapField> createState() => _GapFieldState();
}

class _GapFieldState extends State<_GapField> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;
  bool _committing = false;

  static String _fmt(int ms) =>
      (ms / 1000).toStringAsFixed(ms % 1000 == 0 ? 0 : 1);

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: _fmt(widget.ms));
    _focus = FocusNode()..addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant _GapField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ms != widget.ms && !_focus.hasFocus) {
      _ctrl.text = _fmt(widget.ms);
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) _commit();
  }

  void _commit() {
    if (_committing) return;
    final sec = double.tryParse(_ctrl.text.trim().replaceAll(',', '.'));
    if (sec == null) {
      _ctrl.text = _fmt(widget.ms);
      return;
    }
    final next = (sec * 1000).round().clamp(0, 600000);
    _ctrl.text = _fmt(next);
    if (next == widget.ms) return;
    _committing = true;
    widget.onChanged(next);
    _committing = false;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 200,
      child: TextField(
        controller: _ctrl,
        focusNode: _focus,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: widget.label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        onEditingComplete: _commit,
        onSubmitted: (_) => _commit(),
        onTapOutside: (_) {
          _commit();
          _focus.unfocus();
        },
      ),
    );
  }
}

// ─── Запуск ─────────────────────────────────────────────────────────────────

class _LaunchTab extends StatefulWidget {
  const _LaunchTab({required this.selectedTemplateId});

  final String? selectedTemplateId;

  @override
  State<_LaunchTab> createState() => _LaunchTabState();
}

class _LaunchTabState extends State<_LaunchTab> {
  bool _busy = false;
  final _selectedMotherIds = <String>{};
  bool _selectionReady = false;

  List<({MotherCluster cluster, MaxAccount mother})> _parents(AppState state) {
    final out = <({MotherCluster cluster, MaxAccount mother})>[];
    for (final c in state.motherClusters) {
      final id = c.motherAccountId;
      if (id == null) continue;
      final a = state.accountById(id);
      if (a != null) out.add((cluster: c, mother: a));
    }
    out.sort((a, b) => a.mother.label.toLowerCase().compareTo(b.mother.label.toLowerCase()));
    return out;
  }

  void _ensureSelection(AppState state) {
    final parents = _parents(state);
    final valid = parents.map((p) => p.mother.id).toSet();
    _selectedMotherIds.removeWhere((id) => !valid.contains(id));
    if (!_selectionReady && _selectedMotherIds.isEmpty && valid.isNotEmpty) {
      _selectedMotherIds.addAll(valid);
      _selectionReady = true;
    }
  }

  Set<String> _writerIdsForSelected(AppState state, String templateId) {
    final allowed = <String>{};
    for (final c in state.motherClusters) {
      final mid = c.motherAccountId;
      if (mid == null || !_selectedMotherIds.contains(mid)) continue;
      if (c.effectiveSendMode == ClusterSendMode.parent) {
        allowed.add(mid);
      } else {
        for (final id in c.childAccountIds) {
          final a = state.accountById(id);
          if (a != null && a.hasApiSession) allowed.add(id);
        }
      }
    }
    final withTemplate = state.joinTemplateWriterAccountIds(templateId);
    final narrowed = withTemplate.intersection(allowed);
    // Solo / parent-mode: still send even if assignment wasn't persisted yet.
    return narrowed.isNotEmpty ? narrowed : allowed;
  }

  Future<void> _broadcast(AppState state) async {
    final templateId = widget.selectedTemplateId;
    if (templateId == null || _busy) return;
    if (_selectedMotherIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Отметьте хотя бы одного родителя')),
      );
      return;
    }
    final template = state.joinMessageTemplateById(templateId);
    if (template == null || !template.isActive) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Выберите активный шаблон во вкладке «Шаблоны»')),
      );
      return;
    }

    final writerIds = _writerIdsForSelected(state, templateId);
    final withToken = state.accounts
        .where((a) => writerIds.contains(a.id) && a.hasApiSession)
        .toList();
    if (withToken.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Нет аккаунтов для отправки у выбранных родителей — вкладка «Кто шлёт»'),
        ),
      );
      return;
    }

    var scope = TemplateSendScope.freshOnly;
    final go = await showDialog<TemplateSendScope>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('Отправить шаблон?'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '«${template.name}»\n'
                      'Родителей: ${_selectedMotherIds.length} · '
                      'аккаунтов: ${withToken.length} · '
                      'сообщений: ${template.messageCount}\n'
                      '${withToken.map((a) => a.label).take(6).join(', ')}'
                      '${withToken.length > 6 ? '…' : ''}',
                      style: const TextStyle(height: 1.35),
                    ),
                    const SizedBox(height: 8),
                    for (final option in TemplateSendScope.values)
                      RadioListTile<TemplateSendScope>(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: option,
                        groupValue: scope,
                        title: Text(option.title),
                        subtitle: Text(option.subtitle, style: const TextStyle(fontSize: 11)),
                        onChanged: (v) {
                          if (v != null) setLocal(() => scope = v);
                        },
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, scope),
                  child: const Text('Отправить'),
                ),
              ],
            );
          },
        );
      },
    );
    if (go == null || !mounted) return;

    setState(() => _busy = true);
    try {
      // Ensure selected writers actually have the template (solo parent included).
      await state.applyJoinTemplateToAccounts(
        templateId: templateId,
        accountIds: writerIds,
      );
      final sent = await state.broadcastTemplateToExistingGroups(
        templateId: templateId,
        onlyAccountIds: writerIds,
        scope: go,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            sent > 0 ? 'Отправлено сообщений: $sent' : 'Ничего не отправлено — смотрите журнал',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runJoin(AppState state) async {
    if (_busy) return;
    if (_selectedMotherIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Отметьте хотя бы одного родителя')),
      );
      return;
    }

    final plans = <({String motherId, String label, PipelineLaunchPlan plan})>[];
    for (final mid in _selectedMotherIds) {
      final mother = state.accountById(mid);
      final plan = state.buildPipelineLaunchPlan(
        alreadyJoinedChatIds: state.joinedChatIdsForPipeline(),
        onlyMotherId: mid,
      );
      plans.add((
        motherId: mid,
        label: mother?.label ?? mid,
        plan: plan,
      ));
    }
    final okPlans = plans.where((p) => p.plan.ok).toList();
    if (okPlans.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            plans.map((p) => '«${p.label}»: ${p.plan.error ?? 'пусто'}').join('\n'),
          ),
        ),
      );
      return;
    }

    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Запустить рассылку?'),
        content: Text(
          'Родителей: ${okPlans.length}'
          '${plans.length != okPlans.length ? ' (пропуск ${plans.length - okPlans.length})' : ''}\n\n'
          '${okPlans.map((p) => '«${p.label}»: ${p.plan.summaryLine}').join('\n')}\n\n'
          'Вступление в группы + отправка шаблона по настройке «Кто шлёт».',
          style: const TextStyle(height: 1.35),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Запустить')),
        ],
      ),
    );
    if (go != true || !mounted) return;

    setState(() => _busy = true);
    final action = state.beginAction(
      kind: ActiveActionKind.childrenJoin,
      title: 'Рассылка: запуск',
      subtitle: 'родителей ${okPlans.length}',
    );
    final messages = <String>[];
    try {
      await state.addPipelineJournal(
        kind: PipelineJournalKind.launchPlan,
        message: 'Запуск по ${okPlans.length} родителям',
        detail: okPlans.map((p) => p.label).join(', '),
      );
      for (final row in okPlans) {
        if (action.cancelToken.isCancelled) break;
        state.updateActionProgress(
          action.id,
          message: '«${row.label}» · ${row.plan.summaryLine}',
        );
        final result = await state.runPipelineChildrenJoinByLinks(
          onlyMotherId: row.motherId,
          cancel: action.cancelToken,
          actionId: action.id,
        );
        messages.add('«${row.label}»: ${result.message}');
      }
      final summary = messages.isEmpty ? 'Остановлено' : messages.join('\n');
      state.finishAction(
        action.id,
        status: action.cancelToken.isCancelled
            ? ActiveActionStatus.cancelled
            : ActiveActionStatus.completed,
        message: summary,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(summary), duration: const Duration(seconds: 5)),
      );
    } catch (e) {
      state.finishAction(
        action.id,
        status: ActiveActionStatus.failed,
        message: e.toString(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _ensureSelection(state);
    final parents = _parents(state);
    final template = state.joinMessageTemplateById(widget.selectedTemplateId);
    final writerIds = template == null
        ? <String>{}
        : _writerIdsForSelected(state, template.id);
    final writers = state.accounts.where((a) => writerIds.contains(a.id)).toList();

    var planGroups = 0;
    var planOkCount = 0;
    for (final mid in _selectedMotherIds) {
      final plan = state.buildPipelineLaunchPlan(
        alreadyJoinedChatIds: state.joinedChatIdsForPipeline(),
        onlyMotherId: mid,
      );
      if (plan.ok) {
        planOkCount++;
        planGroups += plan.totalGroups;
      }
    }

    final allSelected =
        parents.isNotEmpty && parents.every((p) => _selectedMotherIds.contains(p.mother.id));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Родители для запуска',
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                      ),
                    ),
                    TextButton(
                      onPressed: parents.isEmpty
                          ? null
                          : () => setState(() {
                                if (allSelected) {
                                  _selectedMotherIds.clear();
                                } else {
                                  _selectedMotherIds
                                    ..clear()
                                    ..addAll(parents.map((p) => p.mother.id));
                                }
                              }),
                      child: Text(allSelected ? 'Снять всех' : 'Выбрать всех'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                if (parents.isEmpty)
                  const Text(
                    'Нет родительских кластеров — создайте во вкладке «Аккаунты».',
                    style: TextStyle(fontSize: 12, color: Colors.white54),
                  )
                else
                  ...parents.map((row) {
                    final mid = row.mother.id;
                    final checked = _selectedMotherIds.contains(mid);
                    final plan = state.buildPipelineLaunchPlan(
                      alreadyJoinedChatIds: state.joinedChatIdsForPipeline(),
                      onlyMotherId: mid,
                    );
                    final mode = row.cluster.effectiveSendMode;
                    return CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: checked,
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            _selectedMotherIds.add(mid);
                          } else {
                            _selectedMotherIds.remove(mid);
                          }
                        });
                      },
                      title: Text(row.mother.label),
                      subtitle: Text(
                        '${mode.label}'
                        '${row.cluster.isSolo ? '' : ' · доч. ${row.cluster.childCount}'}'
                        ' · ${plan.ok ? plan.summaryLine : (plan.error ?? 'нет групп')}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    );
                  }),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Запустить рассылку',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
                const SizedBox(height: 6),
                Text(
                  _selectedMotherIds.isEmpty
                      ? 'Отметьте родителей выше'
                      : 'Выбрано: ${_selectedMotherIds.length} · '
                          'готовы к вступлению: $planOkCount · групп: $planGroups\n'
                          'Шаблон: ${template?.name ?? 'не выбран'} · '
                          'пишут: ${writers.length}'
                          '${writers.isEmpty ? '' : ' (${writers.map((a) => a.label).take(4).join(', ')}'
                              '${writers.length > 4 ? '…' : ''})'}',
                  style: const TextStyle(fontSize: 12, color: Colors.white70, height: 1.35),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _busy || _selectedMotherIds.isEmpty || planOkCount == 0
                      ? null
                      : () => _runJoin(state),
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow, size: 20),
                  label: Text(
                    _busy
                        ? 'Идёт запуск…'
                        : 'Запустить (${_selectedMotherIds.length})',
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: _busy || template == null || _selectedMotherIds.isEmpty
                      ? null
                      : () => _broadcast(state),
                  icon: const Icon(Icons.send, size: 18),
                  label: const Text('Только отправить шаблон в уже вступившие'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─── История ────────────────────────────────────────────────────────────────

class _HistoryTab extends StatefulWidget {
  const _HistoryTab();

  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab> {
  String? _filterTemplateId;
  String? _filterAccountId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<String?>(
                  value: _filterTemplateId,
                  decoration: const InputDecoration(
                    labelText: 'Шаблон',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('Все')),
                    for (final t in state.joinMessageTemplates)
                      DropdownMenuItem(value: t.id, child: Text(t.name)),
                  ],
                  onChanged: (v) => setState(() => _filterTemplateId = v),
                ),
              ),
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<String?>(
                  value: _filterAccountId,
                  decoration: const InputDecoration(
                    labelText: 'Аккаунт',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('Все')),
                    for (final a in state.accounts)
                      DropdownMenuItem(value: a.id, child: Text(a.label)),
                  ],
                  onChanged: (v) => setState(() => _filterAccountId = v),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _SentHistoryTable(
            templateId: _filterTemplateId,
            accountId: _filterAccountId,
            showTemplateColumn: true,
            emptyText: 'Пока нет отправок — после запуска здесь появятся группы и аккаунты',
          ),
        ),
      ],
    );
  }
}

/// Table: which account already sent which template into which group.
class _SentHistoryTable extends StatefulWidget {
  const _SentHistoryTable({
    this.templateId,
    this.accountId,
    this.showTemplateColumn = true,
    this.emptyText = 'Пока нет отправок',
    this.onClear,
  });

  final String? templateId;
  final String? accountId;
  final bool showTemplateColumn;
  final String emptyText;
  final VoidCallback? onClear;

  @override
  State<_SentHistoryTable> createState() => _SentHistoryTableState();
}

class _SentHistoryTableState extends State<_SentHistoryTable> {
  String _search = '';

  String _groupTitle(AppState state, TemplateSentRecord r) {
    if (r.title.trim().isNotEmpty) return r.title.trim();
    for (final e in state.channelCatalog) {
      if (e.chatId == r.chatId) return e.title;
    }
    return '—';
  }

  String _whenLabel(DateTime? when) {
    if (when == null) return '—';
    return '${when.day.toString().padLeft(2, '0')}.'
        '${when.month.toString().padLeft(2, '0')}.'
        '${when.year.toString().substring(2)} '
        '${when.hour.toString().padLeft(2, '0')}:'
        '${when.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    var rows = state.templateSentHistory(
      templateId: widget.templateId,
      accountId: widget.accountId,
    );
    final q = _search.trim().toLowerCase();
    if (q.isNotEmpty) {
      rows = rows.where((r) {
        final account = state.accountById(r.accountId)?.label ?? r.accountId;
        final template =
            state.joinMessageTemplateById(r.templateId)?.name ?? r.templateId;
        final group = _groupTitle(state, r);
        return account.toLowerCase().contains(q) ||
            template.toLowerCase().contains(q) ||
            group.toLowerCase().contains(q) ||
            r.chatId.toLowerCase().contains(q);
      }).toList();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  onChanged: (v) => setState(() => _search = v),
                  decoration: InputDecoration(
                    hintText: 'Поиск по аккаунту, группе…',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    isDense: true,
                    border: const OutlineInputBorder(),
                    suffixText: '${rows.length}',
                  ),
                ),
              ),
              if (widget.onClear != null) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: widget.onClear,
                  child: const Text('Сбросить'),
                ),
              ],
            ],
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Text(
                    widget.emptyText,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white54),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    return SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      scrollDirection: Axis.horizontal,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minWidth: constraints.maxWidth - 24),
                        child: SingleChildScrollView(
                          child: DataTable(
                            showCheckboxColumn: false,
                            headingRowHeight: 40,
                            dataRowMinHeight: 44,
                            dataRowMaxHeight: 56,
                            columnSpacing: 16,
                            columns: [
                              const DataColumn(label: Text('Когда')),
                              const DataColumn(label: Text('Аккаунт')),
                              if (widget.showTemplateColumn)
                                const DataColumn(label: Text('Шаблон')),
                              const DataColumn(label: Text('Группа')),
                              const DataColumn(label: Text('Chat ID')),
                            ],
                            rows: [
                              for (final r in rows)
                                DataRow(
                                  cells: [
                                    DataCell(Text(_whenLabel(r.sentAt))),
                                    DataCell(
                                      Text(
                                        state.accountById(r.accountId)?.label ??
                                            r.accountId,
                                      ),
                                    ),
                                    if (widget.showTemplateColumn)
                                      DataCell(
                                        Text(
                                          state
                                                  .joinMessageTemplateById(r.templateId)
                                                  ?.name ??
                                              r.templateId,
                                        ),
                                      ),
                                    DataCell(
                                      ConstrainedBox(
                                        constraints: const BoxConstraints(maxWidth: 260),
                                        child: Text(
                                          _groupTitle(state, r),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                    DataCell(
                                      Text(
                                        r.chatId,
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: Colors.white54,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
