import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:vyuh_node_flow/vyuh_node_flow.dart';

import '../../models/account_map_state.dart';
import '../../models/map_workflow.dart';
import '../../providers/app_state.dart';
import 'account_node_card.dart';
import 'broadcast_config_sheet.dart' show senderLabelFor;
import 'map_flow_data.dart';
import 'map_flow_graph.dart';
import 'workflow_node_card.dart';

class AccountMapCanvas extends StatefulWidget {
  const AccountMapCanvas({super.key});

  @override
  State<AccountMapCanvas> createState() => _AccountMapCanvasState();
}

class _AccountMapCanvasState extends State<AccountMapCanvas> {
  late final NodeFlowController<MapFlowNodeData, void> _controller;
  final _focusNode = FocusNode();

  String? _graphFingerprint;
  bool _pendingFit = true;
  bool _linkMode = false;
  String? _linkSourceAccountId;

  @override
  void initState() {
    super.initState();
    _controller = NodeFlowController<MapFlowNodeData, void>(
      config: NodeFlowConfig(showAttribution: false),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _syncGraph(AppState state, {bool fit = false}) {
    final fingerprint = MapFlowGraphBuilder.fingerprint(state);
    if (!fit && fingerprint == _graphFingerprint) return;

    final savedViewport = _controller.viewport;
    _graphFingerprint = fingerprint;
    final graph = MapFlowGraphBuilder.fromAppState(state);
    _controller.loadGraph(
      NodeGraph<MapFlowNodeData, void>(
        nodes: graph.nodes,
        connections: graph.connections,
        viewport: fit ? graph.viewport : savedViewport,
      ),
    );

    if (fit || _pendingFit) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _controller.fitToView();
        _pendingFit = false;
      });
    }
  }

  NodeFlowTheme _mapTheme(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final base = isDark ? NodeFlowTheme.dark : NodeFlowTheme.light;

    return base.copyWith(
      backgroundColor: theme.colorScheme.surfaceContainerLowest,
      gridTheme: base.gridTheme.copyWith(
        style: GridStyles.dots,
        color: theme.dividerColor.withValues(alpha: 0.22),
        size: 24,
        thickness: 1,
      ),
      nodeTheme: base.nodeTheme.copyWith(
        backgroundColor: Colors.transparent,
        selectedBackgroundColor: Colors.transparent,
        highlightBackgroundColor: Colors.transparent,
        borderColor: Colors.transparent,
        selectedBorderColor: Colors.transparent,
        highlightBorderColor: Colors.transparent,
        borderWidth: 0,
        selectedBorderWidth: 0,
      ),
      portTheme: base.portTheme.copyWith(
        size: Size.zero,
        color: Colors.transparent,
        connectedColor: Colors.transparent,
        highlightColor: Colors.transparent,
        borderColor: Colors.transparent,
        borderWidth: 0,
      ),
      connectionTheme: base.connectionTheme.copyWith(
        style: ConnectionStyles.smoothstep,
        strokeWidth: 2,
      ),
    );
  }

  String? _activityLabelFor(String accountId, AppState state) {
    final activity = state.mapActivity;
    if (activity == null || !activity.isRecent) return null;
    if (activity.toAccountId == accountId || activity.fromAccountId == accountId) {
      return activity.message;
    }
    return null;
  }

  void _onNodeTap(AppState state, Node<MapFlowNodeData> node) {
    switch (node.data.kind) {
      case MapFlowNodeKind.account:
        if (_linkMode) {
          setState(() => _linkSourceAccountId = node.id);
          state.selectWorkflowNode(null);
          state.selectAccountById(node.id, openBrowser: false);
          return;
        }
        state.selectWorkflowNode(null);
        state.selectAccountById(node.id, openBrowser: false);
      case MapFlowNodeKind.workflowGroup:
        state.selectWorkflowNode(node.id);
      case MapFlowNodeKind.workflowBroadcast:
        if (_linkMode && _linkSourceAccountId != null) {
          final accountLabel = state.accountById(_linkSourceAccountId)?.label ?? 'Аккаунт';
          final accountId = _linkSourceAccountId!;
          state.addWorkflowSenderEdge(accountId: accountId, workflowId: node.id);
          setState(() {
            _linkMode = false;
            _linkSourceAccountId = null;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('«$accountLabel» → «${state.workflowNodes.byId(node.id)?.title ?? 'Рассылка'}»')),
          );
          return;
        }
        state.selectWorkflowNode(node.id);
    }
  }

  Future<void> _onNodeDoubleTap(AppState state, Node<MapFlowNodeData> node) async {
    switch (node.data.kind) {
      case MapFlowNodeKind.account:
        final account = state.accountById(node.id);
        if (account != null) await state.openAccountOnMap(account);
      case MapFlowNodeKind.workflowGroup:
      case MapFlowNodeKind.workflowBroadcast:
        break;
    }
  }

  void _onNodeDragStop(AppState state, Node<MapFlowNodeData> node) {
    final position = node.position.value;
    switch (node.data.kind) {
      case MapFlowNodeKind.account:
        state.moveAccountOnMap(node.id, position);
      case MapFlowNodeKind.workflowGroup:
      case MapFlowNodeKind.workflowBroadcast:
        state.moveWorkflowNode(node.id, position);
    }
  }

  int _childCount(AppState state, String groupId) {
    return state.broadcastsInGroup(groupId).length;
  }

  int _chatCount(AppState state, String groupId) {
    return state.workflowNodes.byId(groupId)?.group?.targetChats.length ?? 0;
  }

  Widget _buildNode(BuildContext context, AppState state, Node<MapFlowNodeData> node) {
    switch (node.data.kind) {
      case MapFlowNodeKind.account:
        final account = state.accountById(node.id);
        if (account == null) return const SizedBox.shrink();
        return AccountNodeCard(
          account: account,
          selected: state.selectedAccount?.id == account.id && state.selectedWorkflowNodeId == null,
          isMother: state.isMotherAccount(account.id),
          isChild: state.isChildAccount(account.id),
          activityLabel: _activityLabelFor(account.id, state),
          highlightLink: _linkMode && _linkSourceAccountId == account.id,
          onTap: () => _onNodeTap(state, node),
          onOpen: () => state.openAccountOnMap(account),
        );
      case MapFlowNodeKind.workflowGroup:
        final workflow = state.workflowNodes.byId(node.id);
        if (workflow == null) return const SizedBox.shrink();
        return WorkflowGroupCard(
          node: workflow,
          selected: state.selectedWorkflowNodeId == workflow.id,
          childCount: _childCount(state, workflow.id),
          chatCount: _chatCount(state, workflow.id),
          onTap: () => _onNodeTap(state, node),
          onEdit: () => state.selectWorkflowNode(workflow.id),
        );
      case MapFlowNodeKind.workflowBroadcast:
        final workflow = state.workflowNodes.byId(node.id);
        if (workflow == null) return const SizedBox.shrink();
        return WorkflowBroadcastCard(
          node: workflow,
          selected: state.selectedWorkflowNodeId == workflow.id,
          senderLabel: senderLabelFor(state, workflow.id),
          onTap: () => _onNodeTap(state, node),
          onEdit: () => state.selectWorkflowNode(workflow.id),
          onRun: () => state.runBroadcastWorkflow(workflow.id),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final hasContent = state.accounts.isNotEmpty || state.workflowNodes.isNotEmpty;

    _syncGraph(state);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MapToolbar(
          linkMode: _linkMode,
          onFit: () => _syncGraph(state, fit: true),
          onAddGroup: () async {
            if (state.selectedAccount == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Сначала выберите аккаунт на карте')),
              );
              return;
            }
            await state.addWorkflowGroupForAccount(state.selectedAccount!.id);
            _graphFingerprint = null;
            _pendingFit = true;
            _syncGraph(state, fit: true);
          },
          onAddBroadcast: () async {
            final parent = state.selectedWorkflowNodeId != null
                ? state.workflowNodes.byId(state.selectedWorkflowNodeId!)
                : null;
            if (parent?.isGroup != true) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Выберите группу на карте, чтобы создать рассылку')),
              );
              return;
            }
            await state.addWorkflowBroadcast(parentGroupId: parent!.id);
            _graphFingerprint = null;
            _pendingFit = true;
            _syncGraph(state, fit: true);
          },
          onToggleLink: () => setState(() {
            _linkMode = !_linkMode;
            _linkSourceAccountId = null;
          }),
        ),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLowest,
              border: Border(
                left: BorderSide(color: theme.dividerColor.withValues(alpha: 0.3)),
                right: BorderSide(color: theme.dividerColor.withValues(alpha: 0.3)),
              ),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                NodeFlowEditor<MapFlowNodeData, void>(
                  controller: _controller,
                  theme: _mapTheme(context),
                  portBuilder: (_, _, _) => const SizedBox.shrink(),
                  events: NodeFlowEvents<MapFlowNodeData, void>(
                    onInit: () {
                      if (_pendingFit) {
                        _controller.fitToView();
                        _pendingFit = false;
                      }
                    },
                    node: NodeEvents<MapFlowNodeData>(
                      onTap: (node) => _onNodeTap(state, node),
                      onDoubleTap: (node) => _onNodeDoubleTap(state, node),
                      onDragStop: (node) => _onNodeDragStop(state, node),
                      onBeforeDelete: (_) async => false,
                    ),
                    connection: ConnectionEvents<MapFlowNodeData, void>(
                      onBeforeStart: (_) => ConnectionValidationResult.deny(),
                      onBeforeComplete: (_) => ConnectionValidationResult.deny(),
                    ),
                  ),
                  nodeBuilder: (context, node) => _buildNode(context, state, node),
                ),
                if (!hasContent)
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Добавьте аккаунты слева или создайте блок на карте',
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 12),
                        FilledButton.tonalIcon(
                          onPressed: state.selectedAccount == null
                              ? null
                              : () => state.addWorkflowGroupForAccount(state.selectedAccount!.id),
                          icon: const Icon(Icons.folder_outlined, size: 18),
                          label: const Text('Создать группу'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (_linkMode)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
            child: Text(
              _linkSourceAccountId == null
                  ? 'Режим связи: нажмите аккаунт-отправитель, затем карточку «Рассылка»'
                  : 'Теперь нажмите карточку «Рассылка» для привязки отправителя',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (state.mapActivity != null && state.mapActivity!.isRecent)
          _ActivityBar(activity: state.mapActivity!),
      ],
    );
  }
}

class _MapToolbar extends StatelessWidget {
  const _MapToolbar({
    required this.linkMode,
    required this.onFit,
    required this.onAddGroup,
    required this.onAddBroadcast,
    required this.onToggleLink,
  });

  final bool linkMode;
  final VoidCallback onFit;
  final VoidCallback onAddGroup;
  final VoidCallback onAddBroadcast;
  final VoidCallback onToggleLink;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor.withValues(alpha: 0.3))),
      ),
      child: Row(
        children: [
          const Icon(Icons.hub_outlined, size: 18),
          const SizedBox(width: 6),
          const Text('Карта', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: onAddGroup,
            icon: const Icon(Icons.folder_outlined, size: 16),
            label: const Text('Группа'),
            style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
          ),
          const SizedBox(width: 4),
          OutlinedButton.icon(
            onPressed: onAddBroadcast,
            icon: const Icon(Icons.campaign_outlined, size: 16),
            label: const Text('Рассылка'),
            style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: linkMode ? 'Отменить связь' : 'Связать аккаунт → рассылку',
            visualDensity: VisualDensity.compact,
            onPressed: onToggleLink,
            icon: Icon(linkMode ? Icons.link_off : Icons.link, size: 18),
            color: linkMode ? Theme.of(context).colorScheme.primary : null,
          ),
          const Spacer(),
          if (state.accountMap.edgesFromClusters().isNotEmpty) ...[
            Container(
              width: 10,
              height: 3,
              decoration: BoxDecoration(
                color: const Color(0xFFFF9800),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'матка→доч. ${state.accountMap.edgesFromClusters().length}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: const Color(0xFFFF9800)),
            ),
            const SizedBox(width: 10),
          ],
          Text(
            '${state.accounts.length} акк. · ${state.workflowNodes.length} блоков',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          IconButton(
            tooltip: 'Показать всё',
            visualDensity: VisualDensity.compact,
            onPressed: onFit,
            icon: const Icon(Icons.fit_screen, size: 18),
          ),
          FilledButton.tonalIcon(
            onPressed: state.selectedAccount == null
                ? null
                : () => state.setBrowserDrawerOpen(!state.browserDrawerOpen),
            icon: Icon(state.browserDrawerOpen ? Icons.expand_more : Icons.open_in_new, size: 16),
            label: Text(state.browserDrawerOpen ? 'Скрыть' : 'MAX'),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActivityBar extends StatelessWidget {
  const _ActivityBar({required this.activity});

  final AccountMapActivity activity;

  @override
  Widget build(BuildContext context) {
    final color = switch (activity.type) {
      AccountMapActivityType.error => Colors.redAccent,
      AccountMapActivityType.childJoin => Colors.greenAccent,
      AccountMapActivityType.invite => Colors.blueAccent,
      _ => Colors.orangeAccent,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: color.withValues(alpha: 0.12),
      child: Row(
        children: [
          Icon(Icons.bolt, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(activity.message, style: TextStyle(fontSize: 12, color: color))),
        ],
      ),
    );
  }
}
