import 'dart:ui';

import 'map_workflow.dart';

enum AccountMapEdgeType { motherChild, forwardLink, message }

enum AccountMapActivityType { forwardLink, childJoin, invite, error, info }

class AccountNodePosition {
  const AccountNodePosition({
    required this.accountId,
    required this.x,
    required this.y,
  });

  final String accountId;
  final double x;
  final double y;

  Offset get offset => Offset(x, y);

  AccountNodePosition copyWith({double? x, double? y}) {
    return AccountNodePosition(
      accountId: accountId,
      x: x ?? this.x,
      y: y ?? this.y,
    );
  }

  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'x': x,
        'y': y,
      };

  factory AccountNodePosition.fromJson(Map<String, dynamic> json) {
    return AccountNodePosition(
      accountId: json['accountId'] as String,
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
    );
  }
}

class AccountMapEdge {
  const AccountMapEdge({
    required this.fromAccountId,
    required this.toAccountId,
    this.type = AccountMapEdgeType.motherChild,
  });

  final String fromAccountId;
  final String toAccountId;
  final AccountMapEdgeType type;

  String get key => '$fromAccountId->$toAccountId:${type.name}';

  Map<String, dynamic> toJson() => {
        'fromAccountId': fromAccountId,
        'toAccountId': toAccountId,
        'type': type.name,
      };

  factory AccountMapEdge.fromJson(Map<String, dynamic> json) {
    return AccountMapEdge(
      fromAccountId: json['fromAccountId'] as String,
      toAccountId: json['toAccountId'] as String,
      type: AccountMapEdgeType.values.firstWhere(
        (v) => v.name == json['type'],
        orElse: () => AccountMapEdgeType.motherChild,
      ),
    );
  }
}

class AccountMapActivity {
  AccountMapActivity({
    required this.fromAccountId,
    required this.toAccountId,
    required this.type,
    required this.message,
    required this.at,
  });

  final String? fromAccountId;
  final String? toAccountId;
  final AccountMapActivityType type;
  final String message;
  final DateTime at;

  bool get isRecent => DateTime.now().difference(at).inSeconds < 8;
}

class AccountMapState {
  const AccountMapState({
    this.positions = const [],
    this.edges = const [],
    this.motherAccountId,
    this.childAccountIds = const {},
    this.workflowNodes = const [],
    this.workflowEdges = const [],
  });

  final List<AccountNodePosition> positions;
  final List<AccountMapEdge> edges;
  final String? motherAccountId;
  final Set<String> childAccountIds;
  final List<MapWorkflowNode> workflowNodes;
  final List<WorkflowMapEdge> workflowEdges;

  Map<String, dynamic> toJson() => {
        'positions': positions.map((p) => p.toJson()).toList(),
        'edges': edges.map((e) => e.toJson()).toList(),
        if (motherAccountId != null) 'motherAccountId': motherAccountId,
        'childAccountIds': childAccountIds.toList(),
        'workflowNodes': workflowNodes.map((n) => n.toJson()).toList(),
        'workflowEdges': workflowEdges.map((e) => e.toJson()).toList(),
      };

  factory AccountMapState.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const AccountMapState();
    return AccountMapState(
      positions: (json['positions'] as List<dynamic>? ?? [])
          .map((e) => AccountNodePosition.fromJson(e as Map<String, dynamic>))
          .toList(),
      edges: (json['edges'] as List<dynamic>? ?? [])
          .map((e) => AccountMapEdge.fromJson(e as Map<String, dynamic>))
          .toList(),
      motherAccountId: json['motherAccountId'] as String?,
      childAccountIds: (json['childAccountIds'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toSet(),
      workflowNodes: (json['workflowNodes'] as List<dynamic>? ?? [])
          .map((e) => MapWorkflowNode.fromJson(e as Map<String, dynamic>))
          .toList(),
      workflowEdges: (json['workflowEdges'] as List<dynamic>? ?? [])
          .map((e) => WorkflowMapEdge.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  AccountMapState copyWith({
    List<AccountNodePosition>? positions,
    List<AccountMapEdge>? edges,
    String? motherAccountId,
    Set<String>? childAccountIds,
    List<MapWorkflowNode>? workflowNodes,
    List<WorkflowMapEdge>? workflowEdges,
  }) {
    return AccountMapState(
      positions: positions ?? this.positions,
      edges: edges ?? this.edges,
      motherAccountId: motherAccountId ?? this.motherAccountId,
      childAccountIds: childAccountIds ?? this.childAccountIds,
      workflowNodes: workflowNodes ?? this.workflowNodes,
      workflowEdges: workflowEdges ?? this.workflowEdges,
    );
  }
}
