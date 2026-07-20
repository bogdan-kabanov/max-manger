import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/automation_rule.dart';
import '../models/map_workflow.dart';
import '../providers/app_state.dart';
import '../services/browser_session_manager.dart';
import 'ai_chat_panel.dart';
import 'map_sidebar/account_chats_tab.dart';
import 'map_sidebar/account_map_panel.dart';
import 'map_sidebar/map_log_panel.dart';
import 'map_sidebar/workflow_groups_tab.dart';
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

  String _headerTitle(AppState state) {
    if (state.selectedAccount != null) return 'Аккаунт';
    return 'Автоматизация';
  }

  String? _headerSubtitle(AppState state) => state.selectedAccount?.label;

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
          Expanded(
            child: _AutomationTabs(
              key: ValueKey(state.selectedAccount?.id ?? 'global'),
              accountId: state.selectedAccount?.id,
              state: state,
              nameController: _nameController,
              keywordsController: _keywordsController,
              replyController: _replyController,
              onAddRule: () => _addRule(context),
            ),
          ),
          const MapLogPanel(),
        ],
      ),
    );
  }
}

class _AutomationTabs extends StatefulWidget {
  const _AutomationTabs({
    super.key,
    required this.state,
    required this.nameController,
    required this.keywordsController,
    required this.replyController,
    required this.onAddRule,
    this.accountId,
  });

  final String? accountId;
  final AppState state;
  final TextEditingController nameController;
  final TextEditingController keywordsController;
  final TextEditingController replyController;
  final VoidCallback onAddRule;

  @override
  State<_AutomationTabs> createState() => _AutomationTabsState();
}

class _AutomationTabsState extends State<_AutomationTabs> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String? _lastAutoJumpNodeId;

  bool get _hasAccount => widget.accountId != null;

  List<String> get _labels => [
    if (_hasAccount) ...['Аккаунт', 'Группы', 'Чаты'],
    'Автоответы',
    'ИИ-бот',
    'Сценарии',
    'Матка',
    'Каналы',
  ];

  int get _groupsTabIndex => _hasAccount ? 1 : -1;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _labels.length, vsync: this);
    _maybeJumpToGroups(widget.state);
  }

  @override
  void didUpdateWidget(covariant _AutomationTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountId != widget.accountId ||
        oldWidget.state.selectedWorkflowNodeId != widget.state.selectedWorkflowNodeId) {
      final labels = _labels;
      if (_tabController.length != labels.length) {
        final oldIndex = _tabController.index;
        _tabController.dispose();
        _tabController = TabController(
          length: labels.length,
          vsync: this,
          initialIndex: oldIndex.clamp(0, labels.length - 1),
        );
      }
      _maybeJumpToGroups(widget.state);
    }
  }

  void _maybeJumpToGroups(AppState state) {
    if (!_hasAccount || _groupsTabIndex < 0) return;
    final nodeId = state.selectedWorkflowNodeId;
    if (nodeId == null || nodeId == _lastAutoJumpNodeId) return;
    final node = state.workflowNodes.byId(nodeId);
    if (node == null) return;
    if (!node.isGroup && !node.isBroadcast) return;
    _lastAutoJumpNodeId = nodeId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_tabController.index != _groupsTabIndex) {
        _tabController.animateTo(_groupsTabIndex);
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final browser = context.watch<BrowserSessionManager>();
    final labels = _labels;
    final accountId = widget.accountId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_hasAccount)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Выберите аккаунт слева или на карте — появятся вкладки Группы и Чаты.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [for (final label in labels) Tab(text: label)],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              if (_hasAccount && accountId != null) ...[
                AccountMapPanel(key: ValueKey('acc-$accountId'), accountId: accountId),
                WorkflowGroupsTab(key: ValueKey('grp-$accountId'), accountId: accountId),
                AccountChatsTab(key: ValueKey('cht-$accountId'), accountId: accountId),
              ],
              _AutoReplyTab(
                state: widget.state,
                browser: browser,
                nameController: widget.nameController,
                keywordsController: widget.keywordsController,
                replyController: widget.replyController,
                onAddRule: widget.onAddRule,
              ),
              const AiChatPanel(),
              const ScenarioPanel(),
              const MotherPanel(),
              const ChannelCatalogPanel(),
            ],
          ),
        ),
      ],
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
