import 'package:flutter/material.dart';
import 'package:vyuh_node_flow/vyuh_node_flow.dart';

import '../../models/account_map_state.dart';
import '../../models/map_workflow.dart';
import '../../providers/app_state.dart';
import 'account_node_card.dart';
import 'map_flow_data.dart';

class MapFlowGraphBuilder {
  static NodeGraph<MapFlowNodeData, void> fromAppState(AppState state) {
    final accountIds = state.accounts.map((a) => a.id).toSet();
    final workflowIds = state.workflowNodes.map((n) => n.id).toSet();

    final nodes = <Node<MapFlowNodeData>>[
      for (final workflow in state.workflowNodes.where((n) => n.isGroup))
        _workflowGroupNode(workflow),
      for (final account in state.accounts)
        _accountNode(account.id, state.positionForAccount(account.id)),
      for (final workflow in state.workflowNodes.where((n) => n.isBroadcast))
        _workflowBroadcastNode(workflow),
    ];

    final connections = <Connection<void>>[
      for (final edge in state.accountMap.edges)
        if (accountIds.contains(edge.fromAccountId) && accountIds.contains(edge.toAccountId))
          _accountEdge(edge),
      for (final edge in state.workflowEdges.where((e) => e.kind == WorkflowEdgeKind.owner))
        if (accountIds.contains(edge.fromId) && workflowIds.contains(edge.toId))
          _ownerEdge(edge),
      for (final edge in state.workflowEdges.where((e) => e.kind == WorkflowEdgeKind.contains))
        if (workflowIds.contains(edge.fromId) && workflowIds.contains(edge.toId))
          _containsEdge(edge),
      for (final edge in state.workflowEdges.where((e) => e.kind == WorkflowEdgeKind.sender))
        if (accountIds.contains(edge.fromId) && workflowIds.contains(edge.toId))
          _senderEdge(edge),
    ];

    return NodeGraph<MapFlowNodeData, void>(
      nodes: nodes,
      connections: connections,
    );
  }

  static String fingerprint(AppState state) {
    final accounts = state.accounts
        .map((a) => '${a.id}:${a.label}:${a.hasApiSession}')
        .join(';');
    final workflows = state.workflowNodes
        .map((n) {
          final b = n.broadcast;
          final g = n.group;
          return '${n.id}:${n.kind.name}:${n.title}:${n.x}:${n.y}:${n.width}:${n.height}:'
              '${n.parentGroupId}:${g?.targetChats.join(',')}:${b?.enabled}:${b?.steps.length}:'
              '${b?.senderAccountId}:${b?.targetChats.length}';
        })
        .join(';');
    final accountEdges = state.accountMap.edges.map((e) => e.key).join(';');
    final workflowEdges = state.workflowEdges.map((e) => e.key).join(';');
    final roles = '${state.motherAccountId}|${state.childAccountIds.join(',')}';
    return '$accounts|$workflows|$accountEdges|$workflowEdges|$roles';
  }

  static Node<MapFlowNodeData> _accountNode(String accountId, Offset position) {
    const height = AccountNodeCard.nodeHeight;
    return Node<MapFlowNodeData>(
      id: accountId,
      type: MapFlowNodeTypes.account,
      position: position,
      size: const Size(AccountNodeCard.nodeWidth, AccountNodeCard.nodeHeight),
      data: const MapFlowNodeData(MapFlowNodeKind.account),
      ports: _accountPorts(height),
    );
  }

  static Node<MapFlowNodeData> _workflowGroupNode(MapWorkflowNode workflow) {
    final height = workflow.height - 22;
    return Node<MapFlowNodeData>(
      id: workflow.id,
      type: MapFlowNodeTypes.workflowGroup,
      position: Offset(workflow.x, workflow.y),
      size: Size(workflow.width, height),
      data: const MapFlowNodeData(MapFlowNodeKind.workflowGroup),
      layer: NodeRenderLayer.background,
      initialZIndex: -1,
      ports: [
        Port(
          id: 'in',
          name: 'in',
          type: PortType.input,
          position: PortPosition.left,
          offset: Offset(0, height / 2),
          isConnectable: false,
        ),
        Port(
          id: 'out',
          name: 'out',
          type: PortType.output,
          position: PortPosition.right,
          offset: Offset(0, height / 2),
          isConnectable: false,
        ),
      ],
    );
  }

  static Node<MapFlowNodeData> _workflowBroadcastNode(MapWorkflowNode workflow) {
    final height = workflow.height - 22;
    return Node<MapFlowNodeData>(
      id: workflow.id,
      type: MapFlowNodeTypes.workflowBroadcast,
      position: Offset(workflow.x, workflow.y),
      size: Size(workflow.width, height),
      data: const MapFlowNodeData(MapFlowNodeKind.workflowBroadcast),
      ports: _broadcastPorts(height),
      initialZIndex: 1,
    );
  }

  static List<Port> _accountPorts(double height) {
    return [
      Port(
        id: 'in',
        name: 'in',
        type: PortType.input,
        position: PortPosition.left,
        offset: Offset(0, height / 2),
        isConnectable: false,
      ),
      Port(
        id: 'out',
        name: 'out',
        type: PortType.output,
        position: PortPosition.right,
        offset: Offset(0, height / 2),
        isConnectable: false,
      ),
    ];
  }

  static List<Port> _broadcastPorts(double height) {
    return [
      Port(
        id: 'in',
        name: 'in',
        type: PortType.input,
        position: PortPosition.left,
        offset: Offset(0, height / 2),
        isConnectable: false,
      ),
    ];
  }

  static Connection<void> _accountEdge(AccountMapEdge edge) {
    final color = switch (edge.type) {
      AccountMapEdgeType.motherChild => Colors.orangeAccent,
      AccountMapEdgeType.forwardLink => Colors.lightBlueAccent,
      AccountMapEdgeType.message => Colors.purpleAccent,
    };
    return Connection<void>(
      id: edge.key,
      sourceNodeId: edge.fromAccountId,
      sourcePortId: 'out',
      targetNodeId: edge.toAccountId,
      targetPortId: 'in',
      color: color.withValues(alpha: 0.7),
      style: ConnectionStyles.smoothstep,
    );
  }

  static Connection<void> _ownerEdge(WorkflowMapEdge edge) {
    return Connection<void>(
      id: edge.key,
      sourceNodeId: edge.fromId,
      sourcePortId: 'out',
      targetNodeId: edge.toId,
      targetPortId: 'in',
      color: Colors.blueAccent.withValues(alpha: 0.75),
      style: ConnectionStyles.smoothstep,
    );
  }

  static Connection<void> _containsEdge(WorkflowMapEdge edge) {
    return Connection<void>(
      id: edge.key,
      sourceNodeId: edge.fromId,
      sourcePortId: 'out',
      targetNodeId: edge.toId,
      targetPortId: 'in',
      color: Colors.deepPurpleAccent.withValues(alpha: 0.65),
      style: ConnectionStyles.step,
    );
  }

  static Connection<void> _senderEdge(WorkflowMapEdge edge) {
    return Connection<void>(
      id: edge.key,
      sourceNodeId: edge.fromId,
      sourcePortId: 'out',
      targetNodeId: edge.toId,
      targetPortId: 'in',
      color: Colors.tealAccent.withValues(alpha: 0.75),
      style: ConnectionStyles.bezier,
      animated: true,
    );
  }
}
