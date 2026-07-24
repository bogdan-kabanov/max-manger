import 'dart:ui';

import 'package:uuid/uuid.dart';

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

/// One mother account with its own set of child accounts.
enum ClusterSendMode {
  /// Parent account writes (solo clusters always use this).
  parent,
  /// Child accounts write.
  children;

  String get label => switch (this) {
        ClusterSendMode.parent => 'Родитель сам',
        ClusterSendMode.children => 'Дочерние',
      };

  static ClusterSendMode fromJson(Object? raw, {required bool hasChildren}) {
    final s = raw?.toString().trim().toLowerCase();
    if (s == 'parent' || s == 'mother' || s == 'solo') {
      return ClusterSendMode.parent;
    }
    if (s == 'children' || s == 'child') {
      return ClusterSendMode.children;
    }
    return hasChildren ? ClusterSendMode.children : ClusterSendMode.parent;
  }
}

class MotherCluster {
  const MotherCluster({
    required this.id,
    required this.name,
    this.motherAccountId,
    this.childAccountIds = const {},
    this.sendMode = ClusterSendMode.children,
    this.postJoinWriteEnabled = false,
    this.postJoinMessages = const [],
    this.postJoinDelayMs = 5000,
  });

  final String id;
  final String name;
  final String? motherAccountId;
  final Set<String> childAccountIds;

  /// Who sends templates for groups of this parent.
  /// When [childAccountIds] is empty, effective mode is always [ClusterSendMode.parent].
  final ClusterSendMode sendMode;

  /// After children join a chat, send [postJoinMessages] via API (not web clicker).
  final bool postJoinWriteEnabled;
  final List<BroadcastMessageStep> postJoinMessages;
  /// Pause after join before the first message.
  final int postJoinDelayMs;

  int get childCount => childAccountIds.length;

  bool get isSolo => childAccountIds.isEmpty;

  /// Resolved writer mode (solo always parent).
  ClusterSendMode get effectiveSendMode =>
      isSolo ? ClusterSendMode.parent : sendMode;

  bool get hasPostJoinMessages =>
      postJoinWriteEnabled && postJoinMessages.any((m) => m.text.trim().isNotEmpty);

  MotherCluster copyWith({
    String? name,
    String? motherAccountId,
    Set<String>? childAccountIds,
    bool clearMother = false,
    ClusterSendMode? sendMode,
    bool? postJoinWriteEnabled,
    List<BroadcastMessageStep>? postJoinMessages,
    int? postJoinDelayMs,
  }) {
    return MotherCluster(
      id: id,
      name: name ?? this.name,
      motherAccountId: clearMother ? null : (motherAccountId ?? this.motherAccountId),
      childAccountIds: childAccountIds ?? this.childAccountIds,
      sendMode: sendMode ?? this.sendMode,
      postJoinWriteEnabled: postJoinWriteEnabled ?? this.postJoinWriteEnabled,
      postJoinMessages: postJoinMessages ?? this.postJoinMessages,
      postJoinDelayMs: postJoinDelayMs ?? this.postJoinDelayMs,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (motherAccountId != null) 'motherAccountId': motherAccountId,
        'childAccountIds': childAccountIds.toList(),
        'sendMode': sendMode.name,
        'postJoinWriteEnabled': postJoinWriteEnabled,
        'postJoinMessages': postJoinMessages.map((m) => m.toJson()).toList(),
        'postJoinDelayMs': postJoinDelayMs,
      };

  factory MotherCluster.fromJson(Map<String, dynamic> json) {
    final children = (json['childAccountIds'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toSet();
    return MotherCluster(
      id: (json['id'] as String?) ?? const Uuid().v4(),
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? (json['name'] as String).trim()
          : 'Родитель',
      motherAccountId: json['motherAccountId'] as String?,
      childAccountIds: children,
      sendMode: ClusterSendMode.fromJson(
        json['sendMode'],
        hasChildren: children.isNotEmpty,
      ),
      postJoinWriteEnabled: json['postJoinWriteEnabled'] == true,
      postJoinMessages: (json['postJoinMessages'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(BroadcastMessageStep.fromJson)
          .toList(),
      postJoinDelayMs: (json['postJoinDelayMs'] as num?)?.toInt() ?? 5000,
    );
  }

  static MotherCluster create({String? name, String? motherAccountId, Set<String>? childAccountIds}) {
    final kids = childAccountIds ?? const <String>{};
    return MotherCluster(
      id: const Uuid().v4(),
      name: name ?? 'Родитель',
      motherAccountId: motherAccountId,
      childAccountIds: kids,
      sendMode: kids.isEmpty ? ClusterSendMode.parent : ClusterSendMode.children,
    );
  }
}

class AccountMapState {
  const AccountMapState({
    this.positions = const [],
    this.edges = const [],
    this.motherClusters = const [],
    this.workflowNodes = const [],
    this.workflowEdges = const [],
  });

  final List<AccountNodePosition> positions;
  final List<AccountMapEdge> edges;
  final List<MotherCluster> motherClusters;
  final List<MapWorkflowNode> workflowNodes;
  final List<WorkflowMapEdge> workflowEdges;

  /// Legacy / convenience: first cluster's mother (or null).
  String? get motherAccountId =>
      motherClusters.isEmpty ? null : motherClusters.first.motherAccountId;

  /// Legacy / convenience: union of all child ids across clusters.
  Set<String> get childAccountIds => {
        for (final c in motherClusters) ...c.childAccountIds,
      };

  Set<String> get allMotherAccountIds => {
        for (final c in motherClusters)
          if (c.motherAccountId != null) c.motherAccountId!,
      };

  bool isMotherAccount(String accountId) => allMotherAccountIds.contains(accountId);

  bool isChildAccount(String accountId) => childAccountIds.contains(accountId);

  MotherCluster? clusterById(String id) {
    for (final c in motherClusters) {
      if (c.id == id) return c;
    }
    return null;
  }

  MotherCluster? clusterForMother(String motherAccountId) {
    for (final c in motherClusters) {
      if (c.motherAccountId == motherAccountId) return c;
    }
    return null;
  }

  /// Account ids already used as mother or child in other clusters.
  Set<String> occupiedAccountIds({String? exceptClusterId}) {
    final occupied = <String>{};
    for (final c in motherClusters) {
      if (exceptClusterId != null && c.id == exceptClusterId) continue;
      if (c.motherAccountId != null) occupied.add(c.motherAccountId!);
      occupied.addAll(c.childAccountIds);
    }
    return occupied;
  }

  List<AccountMapEdge> edgesFromClusters() {
    final edges = <AccountMapEdge>[];
    for (final c in motherClusters) {
      final motherId = c.motherAccountId;
      if (motherId == null) continue;
      for (final childId in c.childAccountIds) {
        if (childId == motherId) continue;
        edges.add(AccountMapEdge(fromAccountId: motherId, toAccountId: childId));
      }
    }
    return edges;
  }

  Map<String, dynamic> toJson() => {
        'positions': positions.map((p) => p.toJson()).toList(),
        'edges': edges.map((e) => e.toJson()).toList(),
        'motherClusters': motherClusters.map((c) => c.toJson()).toList(),
        // Keep legacy fields for older builds reading the same file.
        if (motherAccountId != null) 'motherAccountId': motherAccountId,
        'childAccountIds': childAccountIds.toList(),
        'workflowNodes': workflowNodes.map((n) => n.toJson()).toList(),
        'workflowEdges': workflowEdges.map((e) => e.toJson()).toList(),
      };

  factory AccountMapState.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const AccountMapState();

    final rawClusters = json['motherClusters'] as List<dynamic>?;
    var clusters = (rawClusters ?? [])
        .whereType<Map<String, dynamic>>()
        .map(MotherCluster.fromJson)
        .toList();

    // Migrate legacy single-mother fields.
    if (clusters.isEmpty) {
      final legacyMother = json['motherAccountId'] as String?;
      final legacyChildren = (json['childAccountIds'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toSet();
      if (legacyMother != null || legacyChildren.isNotEmpty) {
        clusters = [
          MotherCluster(
            id: const Uuid().v4(),
            name: 'Родитель 1',
            motherAccountId: legacyMother,
            childAccountIds: legacyChildren,
          ),
        ];
      }
    }

    final loadedEdges = (json['edges'] as List<dynamic>? ?? [])
        .map((e) => AccountMapEdge.fromJson(e as Map<String, dynamic>))
        .toList();

    final state = AccountMapState(
      positions: (json['positions'] as List<dynamic>? ?? [])
          .map((e) => AccountNodePosition.fromJson(e as Map<String, dynamic>))
          .toList(),
      edges: loadedEdges,
      motherClusters: clusters,
      workflowNodes: (json['workflowNodes'] as List<dynamic>? ?? [])
          .map((e) => MapWorkflowNode.fromJson(e as Map<String, dynamic>))
          .toList(),
      workflowEdges: (json['workflowEdges'] as List<dynamic>? ?? [])
          .map((e) => WorkflowMapEdge.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

    // Prefer edges rebuilt from clusters when clusters exist.
    if (clusters.isNotEmpty) {
      return state.copyWith(edges: state.edgesFromClusters());
    }
    return state;
  }

  AccountMapState copyWith({
    List<AccountNodePosition>? positions,
    List<AccountMapEdge>? edges,
    List<MotherCluster>? motherClusters,
    List<MapWorkflowNode>? workflowNodes,
    List<WorkflowMapEdge>? workflowEdges,
  }) {
    return AccountMapState(
      positions: positions ?? this.positions,
      edges: edges ?? this.edges,
      motherClusters: motherClusters ?? this.motherClusters,
      workflowNodes: workflowNodes ?? this.workflowNodes,
      workflowEdges: workflowEdges ?? this.workflowEdges,
    );
  }
}
