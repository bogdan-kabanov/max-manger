enum MapFlowNodeKind { account, workflowGroup, workflowBroadcast }

class MapFlowNodeData {
  const MapFlowNodeData(this.kind);

  final MapFlowNodeKind kind;
}

abstract final class MapFlowNodeTypes {
  static const account = 'account';
  static const workflowGroup = 'workflow_group';
  static const workflowBroadcast = 'workflow_broadcast';
}
