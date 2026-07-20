import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/automation_rule.dart';
import '../models/map_workflow.dart';
import '../providers/app_state.dart';
import '../services/browser_session_manager.dart';
import 'ai_chat_panel.dart';
import 'map_sidebar/account_map_panel.dart';
import 'map_sidebar/broadcast_map_panel.dart';
import 'map_sidebar/group_map_panel.dart';
import 'map_sidebar/map_log_panel.dart';
import 'channel_catalog_panel.dart';
import 'mother_panel.dart';
import 'scenario_panel.dart';

class AutomationPanel extends StatefulWidget {
  const AutomationPanel({super.key, this.fullWidth = false});

  final bool fullWidth;

  @override
  State<AutomationPanel> createState() => _AutomationPanelState();
}

class _AutomationPanelState extends State<AutomationPanel> {
  final _nameController = TextEditingController();
  final _keywordsController = TextEditingController();
  final _replyController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _keywordsController.dispose();
    _replyController.dispose();
    super.dispose();
  }

  Future<void> _addRule(BuildContext context) async {
    if (_nameController.text.trim().isEmpty || _replyController.text.trim().isEmpty) {
      return;
    }
    await context.read<AppState>().addKeywordRule(
          name: _nameController.text.trim(),
          keywordsRaw: _keywordsController.text,
          replyText: _replyController.text.trim(),
        );
    _nameController.clear();
    _keywordsController.clear();
    _replyController.clear();
  }

  Widget _buildBody(AppState state) {
    final workflowId = state.selectedWorkflowNodeId;
    if (workflowId != null) {
      final node = state.workflowNodes.byId(workflowId);
      if (node != null) {
        if (node.isGroup) {
          return GroupMapPanel(key: ValueKey(node.id), node: node);
        }
        if (node.isBroadcast) {
          return BroadcastMapPanel(key: ValueKey(node.id), node: node);
        }
      }
    }

    final account = state.selectedAccount;
    if (account != null) {
      return _AutomationTabs(
        key: ValueKey('account-${account.id}'),
        includeAccountTab: true,
        accountId: account.id,
        state: state,
        nameController: _nameController,
        keywordsController: _keywordsController,
        replyController: _replyController,
        onAddRule: () => _addRule(context),
      );
    }

    return _AutomationTabs(
      key: const ValueKey('global'),
      includeAccountTab: false,
      state: state,
      nameController: _nameController,
      keywordsController: _keywordsController,
      replyController: _replyController,
      onAddRule: () => _addRule(context),
    );
  }

  String _headerTitle(AppState state) {
    final workflowId = state.selectedWorkflowNodeId;
    if (workflowId != null) {
      final node = state.workflowNodes.byId(workflowId);
      if (node != null) {
        return node.isGroup ? 'Настройки группы' : 'Настройки рассылки';
      }
    }
    if (state.selectedAccount != null) return 'Аккаунт';
    return 'Автоматизация';
  }

  String? _headerSubtitle(AppState state) {
    final workflowId = state.selectedWorkflowNodeId;
    if (workflowId != null) {
      return state.workflowNodes.byId(workflowId)?.title;
    }
    return state.selectedAccount?.label;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    return Container(
      width: widget.fullWidth ? double.infinity : 420,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        border: Border(left: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_headerTitle(state), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                if (_headerSubtitle(state) != null) ...[
                  const SizedBox(height: 4),
                  Text(_headerSubtitle(state)!, style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(child: _buildBody(state)),
          const MapLogPanel(),
        ],
      ),
    );
  }
}

class _AutomationTabs extends StatelessWidget {
  const _AutomationTabs({
    super.key,
    required this.includeAccountTab,
    required this.state,
    required this.nameController,
    required this.keywordsController,
    required this.replyController,
    required this.onAddRule,
    this.accountId,
  });

  final bool includeAccountTab;
  final String? accountId;
  final AppState state;
  final TextEditingController nameController;
  final TextEditingController keywordsController;
  final TextEditingController replyController;
  final VoidCallback onAddRule;

  static const _automationTabLabels = [
    'Автоответы',
    'ИИ-бот',
    'Сценарии',
    'Матка',
    'Каналы',
  ];

  @override
  Widget build(BuildContext context) {
    final browser = context.watch<BrowserSessionManager>();
    final tabLabels = [
      if (includeAccountTab) 'Аккаунт',
      ..._automationTabLabels,
    ];

    return DefaultTabController(
      length: tabLabels.length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!includeAccountTab)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Выберите аккаунт слева или на карте — настройки привяжутся к нему.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [for (final label in tabLabels) Tab(text: label)],
          ),
          Expanded(
            child: TabBarView(
              children: [
                if (includeAccountTab && accountId != null)
                  AccountMapPanel(key: ValueKey(accountId), accountId: accountId!),
                _AutoReplyTab(
                  state: state,
                  browser: browser,
                  nameController: nameController,
                  keywordsController: keywordsController,
                  replyController: replyController,
                  onAddRule: onAddRule,
                ),
                const AiChatPanel(),
                const ScenarioPanel(),
                const MotherPanel(),
                const ChannelCatalogPanel(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AutoReplyTab extends StatelessWidget {
  const _AutoReplyTab({
    required this.state,
    required this.browser,
    required this.nameController,
    required this.keywordsController,
    required this.replyController,
    required this.onAddRule,
  });

  final AppState state;
  final BrowserSessionManager browser;
  final TextEditingController nameController;
  final TextEditingController keywordsController;
  final TextEditingController replyController;
  final VoidCallback onAddRule;

  @override
  Widget build(BuildContext context) {
    final rules = state.rulesForSelected();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Автоответы включены'),
                value: state.automationEnabled,
                onChanged: state.selectedAccount == null ? null : state.setAutomationEnabled,
              ),
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Название правила'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: keywordsController,
                decoration: const InputDecoration(
                  labelText: 'Ключевые слова',
                  hintText: 'цена, прайс',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: replyController,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Текст автоответа'),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: state.selectedAccount == null ? null : onAddRule,
                icon: const Icon(Icons.add),
                label: const Text('Добавить правило'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: state.selectedAccount == null ? null : () => browser.runScan(force: true),
                icon: const Icon(Icons.search),
                label: const Text('Сканировать чат'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: rules.isEmpty
              ? const Center(child: Text('Правил пока нет'))
              : ListView.builder(
                  itemCount: rules.length,
                  itemBuilder: (context, index) => _RuleTile(
                    rule: rules[index],
                    onToggle: (value) => state.toggleRule(rules[index], value),
                    onDelete: () => state.removeRule(rules[index]),
                  ),
                ),
        ),
      ],
    );
  }
}

class _RuleTile extends StatelessWidget {
  const _RuleTile({
    required this.rule,
    required this.onToggle,
    required this.onDelete,
  });

  final AutomationRule rule;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(rule.name),
      subtitle: Text('${rule.keywords.join(', ')} → ${rule.replyText}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(value: rule.enabled, onChanged: onToggle),
          IconButton(icon: const Icon(Icons.delete_outline), onPressed: onDelete),
        ],
      ),
    );
  }
}
