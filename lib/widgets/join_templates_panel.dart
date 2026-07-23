import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/account_map_state.dart';
import '../models/join_message_template.dart';
import '../models/map_workflow.dart';
import '../models/matka_template_binding.dart';
import '../models/max_account.dart';
import '../providers/app_state.dart';

/// Unified place to create post-join message templates and assign them to accounts.
class JoinTemplatesPanel extends StatefulWidget {
  const JoinTemplatesPanel({super.key});

  @override
  State<JoinTemplatesPanel> createState() => _JoinTemplatesPanelState();
}

class _JoinTemplatesPanelState extends State<JoinTemplatesPanel> {
  int _tabIndex = 0;
  String? _selectedTemplateId;
  final _selectedAccountIds = <String>{};

  void _ensureSelectedTemplate(AppState state) {
    final templates = state.joinMessageTemplates;
    if (templates.isEmpty) {
      if (_selectedTemplateId != null) _selectedTemplateId = null;
      return;
    }
    if (_selectedTemplateId == null ||
        !templates.any((t) => t.id == _selectedTemplateId)) {
      _selectedTemplateId = templates.first.id;
    }
  }

  Future<void> _addTemplate() async {
    final state = context.read<AppState>();
    final template = await state.addJoinMessageTemplate();
    if (!mounted) return;
    setState(() {
      _selectedTemplateId = template.id;
      _tabIndex = 0;
    });
  }

  Future<void> _deleteSelected() async {
    final id = _selectedTemplateId;
    if (id == null) return;
    final state = context.read<AppState>();
    final template = state.joinMessageTemplateById(id);
    if (template == null) return;
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
    await state.removeJoinMessageTemplate(id);
    if (!mounted) return;
    setState(() {
      _selectedTemplateId =
          state.joinMessageTemplates.isNotEmpty ? state.joinMessageTemplates.first.id : null;
      _selectedAccountIds.clear();
    });
  }

  Future<void> _renameSelected() async {
    final id = _selectedTemplateId;
    if (id == null) return;
    final state = context.read<AppState>();
    final template = state.joinMessageTemplateById(id);
    if (template == null) return;
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
    await state.updateJoinMessageTemplate(template.copyWith(name: name));
  }

  Future<void> _editMessages(JoinMessageTemplate template) async {
    var delaySec = (template.delayMs / 1000).toStringAsFixed(
      template.delayMs % 1000 == 0 ? 0 : 1,
    );
    final delayCtrl = TextEditingController(text: delaySec);
    final controllers = <TextEditingController>[
      for (final m in template.messages)
        if (m.text.trim().isNotEmpty) TextEditingController(text: m.text),
    ];
    if (controllers.isEmpty) controllers.add(TextEditingController());
    var enabled = template.enabled;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('Сообщения · ${template.name}'),
          content: SizedBox(
            width: 440,
            height: 460,
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Включён', style: TextStyle(fontSize: 13)),
                  value: enabled,
                  onChanged: (v) => setLocal(() => enabled = v),
                ),
                TextField(
                  controller: delayCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Пауза после вступления (сек)',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: ListView(
                    children: [
                      for (var i = 0; i < controllers.length; i++) ...[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: TextField(
                                controller: controllers[i],
                                minLines: 2,
                                maxLines: 5,
                                decoration: InputDecoration(
                                  labelText: 'Сообщение ${i + 1}',
                                  hintText:
                                      'Присоединяйся ➡️ [МОЙ КАНАЛ]({channel_link})',
                                  helperText: i == 0
                                      ? 'Ссылка: [текст](https://…) · канал воронки: {channel_link}'
                                      : null,
                                  helperMaxLines: 2,
                                  isDense: true,
                                  border: const OutlineInputBorder(),
                                ),
                              ),
                            ),
                            if (controllers.length > 1)
                              IconButton(
                                tooltip: 'Удалить',
                                onPressed: () => setLocal(() {
                                  controllers.removeAt(i).dispose();
                                }),
                                icon: const Icon(Icons.close, size: 18),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => setLocal(() {
                            controllers.add(TextEditingController());
                          }),
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Ещё сообщение'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сохранить')),
          ],
        ),
      ),
    );

    if (saved == true && mounted) {
      final raw = delayCtrl.text.trim().replaceAll(',', '.');
      final sec = double.tryParse(raw);
      final delayMs = sec == null ? template.delayMs : (sec * 1000).round().clamp(200, 120000);
      final messages = <BroadcastMessageStep>[
        for (var i = 0; i < controllers.length; i++)
          if (controllers[i].text.trim().isNotEmpty)
            BroadcastMessageStep(
              id: const Uuid().v4(),
              text: controllers[i].text.trim(),
              delayAfterMs: 3000,
            ),
      ];
      await context.read<AppState>().updateJoinMessageTemplate(
            template.copyWith(
              messages: messages,
              delayMs: delayMs,
              enabled: enabled,
            ),
          );
    }

    delayCtrl.dispose();
    for (final c in controllers) {
      c.dispose();
    }
  }

  Future<void> _applyToSelectedAccounts() async {
    final templateId = _selectedTemplateId;
    if (templateId == null || _selectedAccountIds.isEmpty) return;
    await context.read<AppState>().applyJoinTemplateToAccounts(
          templateId: templateId,
          accountIds: _selectedAccountIds,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Шаблон назначен ${_selectedAccountIds.length} акк.')),
    );
  }

  Future<void> _clearSelectedAccounts() async {
    if (_selectedAccountIds.isEmpty) return;
    await context.read<AppState>().clearJoinTemplateForAccounts(_selectedAccountIds);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Шаблон снят с ${_selectedAccountIds.length} акк.')),
    );
  }

  Future<void> _applyToCluster(MotherCluster cluster) async {
    final templateId = _selectedTemplateId;
    if (templateId == null) return;
    final ids = cluster.childAccountIds;
    if (ids.isEmpty) return;
    await context.read<AppState>().applyJoinTemplateToAccounts(
          templateId: templateId,
          accountIds: ids,
        );
    if (!mounted) return;
    setState(() => _selectedAccountIds.addAll(ids));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Шаблон назначен ${ids.length} доч. кластера «${cluster.name}»',
        ),
      ),
    );
  }

  Future<void> _broadcastSelectedToAllChannels() async {
    final templateId = _selectedTemplateId;
    if (templateId == null) return;
    final state = context.read<AppState>();
    final template = state.joinMessageTemplateById(templateId);
    if (template == null) return;
    if (!template.isActive) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Включите шаблон перед рассылкой')),
      );
      return;
    }
    if (!template.hasMessages) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сначала задайте текст сообщений')),
      );
      return;
    }

    var writers = state.joinTemplateWriterAccountIds(templateId);
    if (_selectedAccountIds.isNotEmpty) {
      writers = writers.intersection(_selectedAccountIds);
    }
    final withToken = state.accounts
        .where(
          (a) =>
              writers.contains(a.id) &&
              a.hasApiSession &&
              state.canSendJoinMessages(a.id),
        )
        .length;

    if (withToken == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Нет дочерних с токеном: привяжите шаблон к матке или назначьте дочкам '
            '(матки сами не пишут)',
          ),
        ),
      );
      return;
    }

    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Написать во все каналы?'),
        content: Text(
          'Шаблон «${template.name}»\n'
          'Дочерних аккаунтов: $withToken\n'
          'Сообщений в шаблоне: ${template.messageCount}\n\n'
          'Пишут только дочерние (и аккаунты без матки). '
          'Матки в чаты не пишут.\n'
          'Для каждого загрузятся его текущие группы/каналы '
          'и туда уйдёт текст шаблона.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Отправить')),
        ],
      ),
    );
    if (go != true || !mounted) return;

    final sent = await state.broadcastTemplateToExistingGroups(
      templateId: templateId,
      onlyAccountIds: _selectedAccountIds.isNotEmpty ? _selectedAccountIds : null,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          sent > 0
              ? 'Отправлено сообщений: $sent'
              : 'Ничего не отправлено. Смотрите журнал: нужен {channel_link} воронки '
                  'и каналы у дочек (не веб-сценарий).',
        ),
        backgroundColor: sent > 0 ? null : Theme.of(context).colorScheme.errorContainer,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _ensureSelectedTemplate(state);
    final scheme = Theme.of(context).colorScheme;
    final template = state.joinMessageTemplateById(_selectedTemplateId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Шаблоны', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              SizedBox(height: 2),
              Text(
                'Создайте шаблоны и привяжите к маткам: сразу после входа или ежедневно в HH:mm.',
                style: TextStyle(fontSize: 12, color: Colors.white60, height: 1.35),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(
                value: 0,
                label: Text('Шаблоны'),
                icon: Icon(Icons.description_outlined, size: 16),
              ),
              ButtonSegment(
                value: 1,
                label: Text('Матки'),
                icon: Icon(Icons.hive_outlined, size: 16),
              ),
              ButtonSegment(
                value: 2,
                label: Text('Аккаунты'),
                icon: Icon(Icons.people_outline, size: 16),
              ),
            ],
            selected: {_tabIndex},
            onSelectionChanged: (v) => setState(() => _tabIndex = v.first),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _tabIndex == 0
              ? _TemplatesTab(
                  templates: state.joinMessageTemplates,
                  selectedId: _selectedTemplateId,
                  selected: template,
                  broadcasting: state.templateBroadcastRunning,
                  onSelect: (id) => setState(() => _selectedTemplateId = id),
                  onAdd: _addTemplate,
                  onRename: _renameSelected,
                  onDelete: _deleteSelected,
                  onEditMessages: template == null ? null : () => _editMessages(template),
                  onToggleEnabled: template == null
                      ? null
                      : (v) => state.updateJoinMessageTemplate(template.copyWith(enabled: v)),
                  onBroadcastAll: template == null || state.templateBroadcastRunning
                      ? null
                      : _broadcastSelectedToAllChannels,
                )
              : _tabIndex == 1
                  ? _MatkiBindingsTab(
                      state: state,
                      selectedTemplateId: _selectedTemplateId,
                    )
                  : _AccountsTab(
                  state: state,
                  scheme: scheme,
                  selectedTemplateId: _selectedTemplateId,
                  selectedAccountIds: _selectedAccountIds,
                  onToggleAccount: (id, selected) {
                    setState(() {
                      if (selected) {
                        _selectedAccountIds.add(id);
                      } else {
                        _selectedAccountIds.remove(id);
                      }
                    });
                  },
                  onSelectAllVisible: (ids) => setState(() => _selectedAccountIds
                    ..clear()
                    ..addAll(ids)),
                  onClearSelection: () => setState(() => _selectedAccountIds.clear()),
                  onApplySelected: _applyToSelectedAccounts,
                  onClearSelected: _clearSelectedAccounts,
                  onApplyCluster: _applyToCluster,
                  onPickTemplateForAccount: (accountId, templateId) =>
                      state.setAccountJoinTemplate(accountId, templateId),
                ),
        ),
      ],
    );
  }
}

class _TemplatesTab extends StatelessWidget {
  const _TemplatesTab({
    required this.templates,
    required this.selectedId,
    required this.selected,
    required this.broadcasting,
    required this.onSelect,
    required this.onAdd,
    required this.onRename,
    required this.onDelete,
    required this.onEditMessages,
    required this.onToggleEnabled,
    required this.onBroadcastAll,
  });

  final List<JoinMessageTemplate> templates;
  final String? selectedId;
  final JoinMessageTemplate? selected;
  final bool broadcasting;
  final ValueChanged<String> onSelect;
  final VoidCallback onAdd;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback? onEditMessages;
  final ValueChanged<bool>? onToggleEnabled;
  final VoidCallback? onBroadcastAll;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: onAdd,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Создать'),
              ),
              const Spacer(),
              if (selected != null) ...[
                IconButton(
                  tooltip: 'Переименовать',
                  onPressed: onRename,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                ),
                IconButton(
                  tooltip: 'Удалить',
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline, size: 18),
                ),
              ],
            ],
          ),
        ),
        if (templates.isEmpty)
          const Expanded(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Создайте шаблон сообщений после вступления в группу.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            ),
          )
        else
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
              children: [
                SizedBox(
                  height: 40,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: templates.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (context, i) {
                      final t = templates[i];
                      final selectedChip = t.id == selectedId;
                      return ChoiceChip(
                        selected: selectedChip,
                        label: Text(t.name, style: const TextStyle(fontSize: 12)),
                        onSelected: (_) => onSelect(t.id),
                        visualDensity: VisualDensity.compact,
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                if (selected != null) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  selected!.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                              Switch(
                                value: selected!.enabled,
                                onChanged: onToggleEnabled,
                              ),
                            ],
                          ),
                          Text(
                            selected!.enabled
                                ? 'Шаблон активен'
                                : 'Выключен — аккаунты не будут писать',
                            style: TextStyle(
                              fontSize: 11,
                              color: selected!.enabled
                                  ? const Color(0xFFA5D6A7)
                                  : Colors.white54,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Пауза: ${(selected!.delayMs / 1000).toStringAsFixed(selected!.delayMs % 1000 == 0 ? 0 : 1)} сек · '
                            'сообщений: ${selected!.messageCount}',
                            style: const TextStyle(fontSize: 12, color: Colors.white70),
                          ),
                          const SizedBox(height: 10),
                          if (!selected!.hasMessages)
                            const Text(
                              'Сообщения ещё не заданы.',
                              style: TextStyle(fontSize: 12, color: Colors.orangeAccent),
                            )
                          else
                            for (var i = 0; i < selected!.messages.length; i++)
                              if (selected!.messages[i].text.trim().isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Text(
                                    '${i + 1}. ${selected!.messages[i].text}',
                                    style: const TextStyle(fontSize: 12, height: 1.35),
                                  ),
                                ),
                          const SizedBox(height: 8),
                          FilledButton.icon(
                            onPressed: onEditMessages,
                            icon: const Icon(Icons.message_outlined, size: 18),
                            label: const Text('Редактировать сообщения'),
                          ),
                          const SizedBox(height: 8),
                          FilledButton.tonalIcon(
                            onPressed: onBroadcastAll,
                            icon: broadcasting
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.campaign_outlined, size: 18),
                            label: Text(
                              broadcasting
                                  ? 'Рассылка…'
                                  : 'Написать во все каналы',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'После вступления — автоматически у дочерних. '
                    '«Написать во все каналы» — дочки пишут во все группы, где уже состоят. '
                    'Матки никогда не пишут. На вкладках «Матки» / «Аккаунты» — привязка; '
                    'если отмечены галочки — рассылка только по ним.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontSize: 11,
                          color: Colors.white54,
                        ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _AccountsTab extends StatelessWidget {
  const _AccountsTab({
    required this.state,
    required this.scheme,
    required this.selectedTemplateId,
    required this.selectedAccountIds,
    required this.onToggleAccount,
    required this.onSelectAllVisible,
    required this.onClearSelection,
    required this.onApplySelected,
    required this.onClearSelected,
    required this.onApplyCluster,
    required this.onPickTemplateForAccount,
  });

  final AppState state;
  final ColorScheme scheme;
  final String? selectedTemplateId;
  final Set<String> selectedAccountIds;
  final void Function(String accountId, bool selected) onToggleAccount;
  final ValueChanged<Set<String>> onSelectAllVisible;
  final VoidCallback onClearSelection;
  final VoidCallback onApplySelected;
  final VoidCallback onClearSelected;
  final Future<void> Function(MotherCluster cluster) onApplyCluster;
  final void Function(String accountId, String? templateId) onPickTemplateForAccount;

  @override
  Widget build(BuildContext context) {
    final accounts = state.accounts;
    final clusters = state.motherClusters;
    final templates = state.joinMessageTemplates;
    final assignedIds = {
      for (final c in clusters) ...[
        if (c.motherAccountId != null) c.motherAccountId!,
        ...c.childAccountIds,
      ],
    };
    final unassigned = accounts.where((a) => !assignedIds.contains(a.id)).toList();
    final visibleIds = <String>{
      for (final c in clusters) ...c.childAccountIds,
      for (final a in unassigned) a.id,
    };

    if (accounts.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Сначала добавьте профили на вкладке «Вход».',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70),
          ),
        ),
      );
    }

    return Column(
      children: [
        if (templates.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Card(
              color: scheme.errorContainer.withValues(alpha: 0.35),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Создайте шаблон на вкладке «Шаблоны», затем назначьте его аккаунтам.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              OutlinedButton(
                onPressed: visibleIds.isEmpty
                    ? null
                    : () => onSelectAllVisible(visibleIds),
                child: const Text('Выбрать всех', style: TextStyle(fontSize: 11)),
              ),
              OutlinedButton(
                onPressed: selectedAccountIds.isEmpty ? null : onClearSelection,
                child: const Text('Снять выбор', style: TextStyle(fontSize: 11)),
              ),
              FilledButton(
                onPressed: selectedTemplateId == null || selectedAccountIds.isEmpty
                    ? null
                    : onApplySelected,
                child: Text(
                  'Назначить шаблон (${selectedAccountIds.length})',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              TextButton(
                onPressed: selectedAccountIds.isEmpty ? null : onClearSelected,
                child: const Text('Снять шаблон', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            children: [
              Text(
                'Отметьте аккаунты галочками и нажмите «Назначить шаблон», '
                'либо выберите шаблон у конкретного аккаунта. '
                'Кнопка у кластера назначает выбранный шаблон всем дочерним.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      color: Colors.white60,
                    ),
              ),
              const SizedBox(height: 12),
              for (final cluster in clusters) ...[
                _ClusterHeader(
                  cluster: cluster,
                  mother: state.accountById(cluster.motherAccountId),
                  canApply: selectedTemplateId != null && cluster.childCount > 0,
                  onApply: () => onApplyCluster(cluster),
                  onSelectChildren: () => onSelectAllVisible(cluster.childAccountIds),
                ),
                for (final childId in cluster.childAccountIds)
                  if (state.accountById(childId) != null)
                    _AccountTemplateTile(
                      account: state.accountById(childId)!,
                      roleLabel: 'дочерний',
                      templates: templates,
                      assignedId: state.joinTemplateByAccountId[childId],
                      selected: selectedAccountIds.contains(childId),
                      onSelected: (v) => onToggleAccount(childId, v),
                      onPickTemplate: (id) => onPickTemplateForAccount(childId, id),
                    ),
                if (cluster.childAccountIds.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: Text(
                      'В кластере пока нет дочерних — назначьте их во вкладке «Матка».',
                      style: TextStyle(fontSize: 11, color: Colors.white54),
                    ),
                  ),
                const SizedBox(height: 10),
              ],
              if (unassigned.isNotEmpty) ...[
                const Text(
                  'Без матки',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                ),
                const SizedBox(height: 6),
                for (final account in unassigned)
                  _AccountTemplateTile(
                    account: account,
                    roleLabel: 'аккаунт',
                    templates: templates,
                    assignedId: state.joinTemplateByAccountId[account.id],
                    selected: selectedAccountIds.contains(account.id),
                    onSelected: (v) => onToggleAccount(account.id, v),
                    onPickTemplate: (id) => onPickTemplateForAccount(account.id, id),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _ClusterHeader extends StatelessWidget {
  const _ClusterHeader({
    required this.cluster,
    required this.mother,
    required this.canApply,
    required this.onApply,
    required this.onSelectChildren,
  });

  final MotherCluster cluster;
  final MaxAccount? mother;
  final bool canApply;
  final VoidCallback onApply;
  final VoidCallback onSelectChildren;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          const Icon(Icons.hive_outlined, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${cluster.name}'
              '${mother != null ? ' · ${mother!.profileDisplayName}' : ''}'
              ' · ${cluster.childCount} доч.',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: cluster.childCount == 0 ? null : onSelectChildren,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const Text('Выбрать', style: TextStyle(fontSize: 11)),
          ),
          TextButton(
            onPressed: canApply ? onApply : null,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const Text('Назначить кластеру', style: TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }
}

class _AccountTemplateTile extends StatelessWidget {
  const _AccountTemplateTile({
    required this.account,
    required this.roleLabel,
    required this.templates,
    required this.assignedId,
    required this.selected,
    required this.onSelected,
    required this.onPickTemplate,
  });

  final MaxAccount account;
  final String roleLabel;
  final List<JoinMessageTemplate> templates;
  final String? assignedId;
  final bool selected;
  final ValueChanged<bool> onSelected;
  final ValueChanged<String?> onPickTemplate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final assigned = templates.where((t) => t.id == assignedId).firstOrNull;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Checkbox(
                  value: selected,
                  onChanged: (v) => onSelected(v == true),
                  visualDensity: VisualDensity.compact,
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        account.profileDisplayName,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        roleLabel,
                        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 12, right: 4),
              child: DropdownButtonFormField<String?>(
                key: ValueKey('join-tpl-${account.id}-${assignedId ?? 'none'}'),
                initialValue: assigned?.id,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Шаблон после вступления',
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('— нет —', style: TextStyle(fontSize: 12)),
                  ),
                  for (final t in templates)
                    DropdownMenuItem<String?>(
                      value: t.id,
                      child: Text(
                        '${t.name}${t.enabled ? '' : ' (выкл.)'}',
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: templates.isEmpty ? null : onPickTemplate,
              ),
            ),
            if (assigned != null) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Text(
                  assigned.isActive
                      ? '${assigned.messageCount} сообщ. · пауза ${(assigned.delayMs / 1000).toStringAsFixed(assigned.delayMs % 1000 == 0 ? 0 : 1)}с'
                      : 'Шаблон выключен или пуст',
                  style: TextStyle(
                    fontSize: 10,
                    color: assigned.isActive ? const Color(0xFFA5D6A7) : Colors.orangeAccent,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Bind templates to matkas with onJoin / dailyAt triggers.
class _MatkiBindingsTab extends StatelessWidget {
  const _MatkiBindingsTab({
    required this.state,
    required this.selectedTemplateId,
  });

  final AppState state;
  final String? selectedTemplateId;

  List<MaxAccount> _mothers() {
    final out = <MaxAccount>[];
    for (final c in state.motherClusters) {
      final id = c.motherAccountId;
      if (id == null) continue;
      final a = state.accountById(id);
      if (a != null) out.add(a);
    }
    return out;
  }

  Future<void> _addBinding(BuildContext context, String motherId) async {
    final templates = state.joinMessageTemplates;
    if (templates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сначала создайте шаблон')),
      );
      return;
    }
    var templateId = selectedTemplateId ?? templates.first.id;
    var trigger = MatkaTemplateTrigger.onJoin;
    var hour = 12;
    var minute = 0;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Привязать шаблон'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  value: templateId,
                  decoration: const InputDecoration(
                    labelText: 'Шаблон',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    for (final t in templates)
                      DropdownMenuItem(value: t.id, child: Text(t.name)),
                  ],
                  onChanged: (v) {
                    if (v != null) setLocal(() => templateId = v);
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<MatkaTemplateTrigger>(
                  value: trigger,
                  decoration: const InputDecoration(
                    labelText: 'Когда',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    for (final t in MatkaTemplateTrigger.values)
                      DropdownMenuItem(value: t, child: Text(t.label)),
                  ],
                  onChanged: (v) {
                    if (v != null) setLocal(() => trigger = v);
                  },
                ),
                if (trigger == MatkaTemplateTrigger.dailyAt) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          initialValue: hour.toString().padLeft(2, '0'),
                          decoration: const InputDecoration(
                            labelText: 'Час',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          keyboardType: TextInputType.number,
                          onChanged: (v) {
                            final n = int.tryParse(v);
                            if (n != null) hour = n.clamp(0, 23);
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextFormField(
                          initialValue: minute.toString().padLeft(2, '0'),
                          decoration: const InputDecoration(
                            labelText: 'Мин',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          keyboardType: TextInputType.number,
                          onChanged: (v) {
                            final n = int.tryParse(v);
                            if (n != null) minute = n.clamp(0, 59);
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Добавить')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await state.addMatkaTemplateBinding(
      motherAccountId: motherId,
      templateId: templateId,
      trigger: trigger,
      hour: hour,
      minute: minute,
    );
  }

  @override
  Widget build(BuildContext context) {
    final mothers = _mothers();
    if (mothers.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Нет маток. Создайте кластер на карте профилей.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
      children: [
        for (final mother in mothers) ...[
          ListTile(
            dense: true,
            leading: const Icon(Icons.hive_outlined, size: 20),
            title: Text(mother.label),
            subtitle: Text(
              'Дочек: ${state.motherClusters.where((c) => c.motherAccountId == mother.id).expand((c) => c.childAccountIds).length}',
            ),
            trailing: IconButton(
              tooltip: 'Привязать шаблон',
              icon: const Icon(Icons.add),
              onPressed: () => _addBinding(context, mother.id),
            ),
          ),
          for (final b in state.bindingsForMother(mother.id))
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.only(left: 48, right: 8),
              title: Text(
                state.joinMessageTemplateById(b.templateId)?.name ?? b.templateId,
                style: const TextStyle(fontSize: 13),
              ),
              subtitle: Text(
                b.trigger == MatkaTemplateTrigger.dailyAt
                    ? 'Ежедневно в ${b.timeLabel}${b.enabled ? '' : ' · выкл'}'
                    : 'После входа${b.enabled ? '' : ' · выкл'}',
                style: const TextStyle(fontSize: 11),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    value: b.enabled,
                    onChanged: (v) => state.updateMatkaTemplateBinding(b.copyWith(enabled: v)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () => state.removeMatkaTemplateBinding(b.id),
                  ),
                ],
              ),
            ),
          const Divider(height: 16),
        ],
      ],
    );
  }
}
