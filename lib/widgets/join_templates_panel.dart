import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/account_map_state.dart';
import '../models/app_nav_page.dart';
import '../models/join_message_template.dart';
import '../models/map_workflow.dart';
import '../models/matka_template_binding.dart';
import '../models/max_account.dart';
import '../models/template_send_scope.dart';
import '../providers/app_state.dart';
import '../services/desktop_file_picker.dart';
import 'post_forward_panel.dart';
import 'template_channels_panel.dart';

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
    final result = await showDialog<_TemplateMessagesEditResult>(
      context: context,
      builder: (ctx) => _TemplateChatEditorDialog(template: template),
    );
    if (result == null || !mounted) return;
    await context.read<AppState>().updateJoinMessageTemplate(
          template.copyWith(
            messages: result.messages,
            delayMs: result.delayMs,
            enabled: result.enabled,
          ),
        );
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

    final historyCount = state.countTemplateSentHistory(templateId);
    var scope = TemplateSendScope.freshOnly;
    final go = await showDialog<TemplateSendScope>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('Написать в каналы?'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Шаблон «${template.name}» · дочек: $withToken · '
                      'сообщений: ${template.messageCount}\n'
                      'В истории уже слали: $historyCount',
                      style: const TextStyle(height: 1.35),
                    ),
                    const SizedBox(height: 12),
                    for (final option in TemplateSendScope.values)
                      RadioListTile<TemplateSendScope>(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: option,
                        groupValue: scope,
                        title: Text(option.title, style: const TextStyle(fontSize: 13)),
                        subtitle: Text(
                          option.subtitle,
                          style: const TextStyle(fontSize: 11),
                        ),
                        onChanged: (v) {
                          if (v == null) return;
                          setLocal(() => scope = v);
                        },
                      ),
                    const SizedBox(height: 4),
                    Text(
                      'Выборочно по аккаунтам: отметьте дочек в списке слева/ниже '
                      'перед запуском. Матки не пишут.',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                    if (historyCount > 0) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: () async {
                            final ok = await showDialog<bool>(
                              context: ctx,
                              builder: (c2) => AlertDialog(
                                title: const Text('Сбросить историю?'),
                                content: Text(
                                  'У шаблона «${template.name}» очистится список '
                                  '«уже слали» ($historyCount). Потом снова можно '
                                  'слать как в новые.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(c2, false),
                                    child: const Text('Отмена'),
                                  ),
                                  FilledButton(
                                    onPressed: () => Navigator.pop(c2, true),
                                    child: const Text('Сбросить'),
                                  ),
                                ],
                              ),
                            );
                            if (ok == true) {
                              await state.clearTemplateSentHistory(templateId);
                              if (ctx.mounted) Navigator.pop(ctx);
                            }
                          },
                          child: const Text('Сбросить историю отправок'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Отмена'),
                ),
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

    final sent = await state.broadcastTemplateToExistingGroups(
      templateId: templateId,
      onlyAccountIds: _selectedAccountIds.isNotEmpty ? _selectedAccountIds : null,
      scope: go,
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
                'Шаблоны после вступления · вкладка «Посты» — смотреть ленту группы и пересылать в чаты.',
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
              ButtonSegment(
                value: 3,
                label: Text('Посты'),
                icon: Icon(Icons.forward_to_inbox_outlined, size: 16),
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
                  onSelect: (id) => setState(() => _selectedTemplateId = id),
                  onAdd: _addTemplate,
                  onRename: _renameSelected,
                  onDelete: _deleteSelected,
                  onEditMessages:
                      template == null ? null : () => _editMessages(template),
                  onToggleEnabled: template == null
                      ? null
                      : (v) => state.updateJoinMessageTemplate(
                            template.copyWith(enabled: v),
                          ),
                )
              : _tabIndex == 1
                  ? _MatkiBindingsTab(
                      state: state,
                      selectedTemplateId: _selectedTemplateId,
                    )
                  : _tabIndex == 2
                      ? _AccountsTab(
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
                          onSelectAllVisible: (ids) => setState(() =>
                              _selectedAccountIds
                                ..clear()
                                ..addAll(ids)),
                          onClearSelection: () =>
                              setState(() => _selectedAccountIds.clear()),
                          onApplySelected: _applyToSelectedAccounts,
                          onClearSelected: _clearSelectedAccounts,
                          onApplyCluster: _applyToCluster,
                          onPickTemplateForAccount: (accountId, templateId) =>
                              state.setAccountJoinTemplate(accountId, templateId),
                        )
                      : const PostForwardPanel(),
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
    required this.onSelect,
    required this.onAdd,
    required this.onRename,
    required this.onDelete,
    required this.onEditMessages,
    required this.onToggleEnabled,
  });

  final List<JoinMessageTemplate> templates;
  final String? selectedId;
  final JoinMessageTemplate? selected;
  final ValueChanged<String> onSelect;
  final VoidCallback onAdd;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback? onEditMessages;
  final ValueChanged<bool>? onToggleEnabled;

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
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: SizedBox(
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
          ),
          if (selected != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Row(
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
                  Text(
                    selected!.enabled ? 'Вкл' : 'Выкл',
                    style: TextStyle(
                      fontSize: 11,
                      color: selected!.enabled
                          ? const Color(0xFFA5D6A7)
                          : Colors.white54,
                    ),
                  ),
                  Switch(
                    value: selected!.enabled,
                    onChanged: onToggleEnabled,
                  ),
                ],
              ),
            ),
            Expanded(
              child: TemplateChannelsPanel(
                key: ValueKey(selected!.id),
                template: selected!,
                onEditMessages: onEditMessages,
              ),
            ),
          ] else
            const Expanded(
              child: Center(
                child: Text(
                  'Выберите шаблон',
                  style: TextStyle(color: Colors.white54),
                ),
              ),
            ),
        ],
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
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 4,
                      children: [
                        const Text(
                          'В кластере пока нет дочерних — назначьте вручную:',
                          style: TextStyle(fontSize: 11, color: Colors.white54),
                        ),
                        TextButton(
                          onPressed: () =>
                              context.read<AppState>().setNavPage(AppNavPage.mother),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text(
                            'Ещё → Матка',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
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

class _TemplateMessagesEditResult {
  const _TemplateMessagesEditResult({
    required this.messages,
    required this.delayMs,
    required this.enabled,
  });

  final List<BroadcastMessageStep> messages;
  final int delayMs;
  final bool enabled;
}

class _DraftBubble {
  _DraftBubble({
    required this.id,
    required this.text,
    this.mediaPath,
    this.delayAfterMs = 3000,
  });

  final String id;
  final TextEditingController text;
  String? mediaPath;
  int delayAfterMs;

  void dispose() => text.dispose();
}

class _TemplateChatEditorDialog extends StatefulWidget {
  const _TemplateChatEditorDialog({required this.template});

  final JoinMessageTemplate template;

  @override
  State<_TemplateChatEditorDialog> createState() =>
      _TemplateChatEditorDialogState();
}

class _TemplateChatEditorDialogState extends State<_TemplateChatEditorDialog> {
  late final TextEditingController _delayCtrl;
  late final TextEditingController _composerCtrl;
  late bool _enabled;
  final _drafts = <_DraftBubble>[];
  String? _composerMedia;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    final t = widget.template;
    _enabled = t.enabled;
    _delayCtrl = TextEditingController(
      text: (t.delayMs / 1000).toStringAsFixed(t.delayMs % 1000 == 0 ? 0 : 1),
    );
    _composerCtrl = TextEditingController();
    for (final m in t.messages) {
      if (!m.hasContent) continue;
      _drafts.add(
        _DraftBubble(
          id: m.id,
          text: TextEditingController(text: m.text),
          mediaPath: m.mediaPath,
          delayAfterMs: m.delayAfterMs,
        ),
      );
    }
  }

  @override
  void dispose() {
    _delayCtrl.dispose();
    _composerCtrl.dispose();
    _scroll.dispose();
    for (final d in _drafts) {
      d.dispose();
    }
    super.dispose();
  }

  Future<void> _pickComposerPhoto() async {
    final path = await DesktopFilePicker.pickImage(title: 'Фото к сообщению');
    if (path != null && mounted) setState(() => _composerMedia = path);
  }

  Future<void> _pickBubblePhoto(int index) async {
    final path = await DesktopFilePicker.pickImage(title: 'Фото к сообщению');
    if (path != null && mounted) {
      setState(() => _drafts[index].mediaPath = path);
    }
  }

  void _addFromComposer() {
    final text = _composerCtrl.text.trim();
    final media = _composerMedia?.trim();
    if (text.isEmpty && (media == null || media.isEmpty)) return;
    setState(() {
      _drafts.add(
        _DraftBubble(
          id: const Uuid().v4(),
          text: TextEditingController(text: text),
          mediaPath: media,
        ),
      );
      _composerCtrl.clear();
      _composerMedia = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  void _save() {
    final pendingText = _composerCtrl.text.trim();
    final pendingMedia = _composerMedia?.trim();
    if (pendingText.isNotEmpty ||
        (pendingMedia != null && pendingMedia.isNotEmpty)) {
      _drafts.add(
        _DraftBubble(
          id: const Uuid().v4(),
          text: TextEditingController(text: pendingText),
          mediaPath: pendingMedia,
        ),
      );
      _composerCtrl.clear();
      _composerMedia = null;
    }

    final raw = _delayCtrl.text.trim().replaceAll(',', '.');
    final sec = double.tryParse(raw);
    final delayMs = sec == null
        ? widget.template.delayMs
        : (sec * 1000).round().clamp(200, 120000);
    final messages = <BroadcastMessageStep>[
      for (final d in _drafts)
        if (d.text.text.trim().isNotEmpty ||
            (d.mediaPath != null && d.mediaPath!.trim().isNotEmpty))
          BroadcastMessageStep(
            id: d.id,
            text: d.text.text.trim(),
            delayAfterMs: d.delayAfterMs,
            mediaPath: d.mediaPath,
          ),
    ];
    Navigator.pop(
      context,
      _TemplateMessagesEditResult(
        messages: messages,
        delayMs: delayMs,
        enabled: _enabled,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bubbleColor = scheme.primaryContainer.withValues(alpha: 0.55);
    final composerReady = _composerCtrl.text.trim().isNotEmpty ||
        (_composerMedia != null && _composerMedia!.trim().isNotEmpty);

    return AlertDialog(
      title: Text('Чат · ${widget.template.name}'),
      content: SizedBox(
        width: 460,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('Включён', style: TextStyle(fontSize: 13)),
                    value: _enabled,
                    onChanged: (v) => setState(() => _enabled = v),
                  ),
                ),
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: _delayCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Пауза сек',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Ссылка: [текст](https://…) · канал воронки: {channel_link}',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: scheme.outlineVariant.withValues(alpha: 0.4),
                  ),
                ),
                child: _drafts.isEmpty
                    ? Center(
                        child: Text(
                          'Пока пусто — напишите ниже\nи добавьте фото при желании',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurfaceVariant,
                            height: 1.35,
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
                        itemCount: _drafts.length,
                        itemBuilder: (context, index) {
                          final d = _drafts[index];
                          final media = d.mediaPath;
                          final mediaOk =
                              media != null && File(media).existsSync();
                          return Align(
                            alignment: Alignment.centerRight,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 340),
                              child: Container(
                                margin: const EdgeInsets.only(bottom: 10),
                                padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
                                decoration: BoxDecoration(
                                  color: bubbleColor,
                                  borderRadius: const BorderRadius.only(
                                    topLeft: Radius.circular(14),
                                    topRight: Radius.circular(14),
                                    bottomLeft: Radius.circular(14),
                                    bottomRight: Radius.circular(4),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          'Сообщение ${index + 1}',
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: scheme.onPrimaryContainer
                                                .withValues(alpha: 0.7),
                                          ),
                                        ),
                                        const Spacer(),
                                        IconButton(
                                          tooltip: 'Фото',
                                          visualDensity: VisualDensity.compact,
                                          onPressed: () => _pickBubblePhoto(index),
                                          icon: const Icon(
                                            Icons.photo_outlined,
                                            size: 16,
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: 'Удалить',
                                          visualDensity: VisualDensity.compact,
                                          onPressed: () => setState(() {
                                            _drafts.removeAt(index).dispose();
                                          }),
                                          icon: const Icon(Icons.close, size: 16),
                                        ),
                                      ],
                                    ),
                                    if (mediaOk)
                                      Padding(
                                        padding: const EdgeInsets.only(bottom: 6),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(8),
                                          child: Stack(
                                            children: [
                                              Image.file(
                                                File(media),
                                                height: 140,
                                                width: double.infinity,
                                                fit: BoxFit.cover,
                                              ),
                                              Positioned(
                                                top: 4,
                                                right: 4,
                                                child: Material(
                                                  color: Colors.black54,
                                                  shape: const CircleBorder(),
                                                  child: InkWell(
                                                    customBorder:
                                                        const CircleBorder(),
                                                    onTap: () => setState(
                                                      () => d.mediaPath = null,
                                                    ),
                                                    child: const Padding(
                                                      padding: EdgeInsets.all(4),
                                                      child: Icon(
                                                        Icons.close,
                                                        size: 14,
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      )
                                    else if (media != null)
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(bottom: 6),
                                        child: Text(
                                          'Файл не найден: $media',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: scheme.error,
                                          ),
                                        ),
                                      ),
                                    TextField(
                                      controller: d.text,
                                      minLines: 1,
                                      maxLines: 6,
                                      style: const TextStyle(fontSize: 13),
                                      decoration: const InputDecoration(
                                        hintText: 'Текст сообщения…',
                                        isDense: true,
                                        border: InputBorder.none,
                                        contentPadding: EdgeInsets.zero,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
            const SizedBox(height: 8),
            if (_composerMedia != null) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(_composerMedia!),
                        height: 72,
                        width: 72,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          height: 72,
                          width: 72,
                          color: scheme.errorContainer,
                          child: const Icon(Icons.broken_image_outlined),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 2,
                      right: 2,
                      child: Material(
                        color: Colors.black54,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => setState(() => _composerMedia = null),
                          child: const Padding(
                            padding: EdgeInsets.all(3),
                            child: Icon(Icons.close, size: 12, color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: 'Прикрепить фото',
                  onPressed: _pickComposerPhoto,
                  icon: Icon(
                    Icons.photo_outlined,
                    color: _composerMedia != null
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _composerCtrl,
                    minLines: 1,
                    maxLines: 4,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _addFromComposer(),
                    decoration: const InputDecoration(
                      hintText: 'Новое сообщение…',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filled(
                  tooltip: 'Добавить в чат',
                  onPressed: composerReady ? _addFromComposer : null,
                  icon: const Icon(Icons.send_rounded, size: 18),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

