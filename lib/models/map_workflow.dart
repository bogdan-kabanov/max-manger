class BroadcastMessageStep {
  const BroadcastMessageStep({
    required this.id,
    required this.text,
    this.delayAfterMs = 3000,
    this.mediaPath,
  });

  final String id;
  final String text;
  final int delayAfterMs;

  /// Optional local image path (photo attach).
  final String? mediaPath;

  bool get hasContent =>
      text.trim().isNotEmpty || (mediaPath != null && mediaPath!.trim().isNotEmpty);

  BroadcastMessageStep copyWith({
    String? text,
    int? delayAfterMs,
    String? mediaPath,
    bool clearMedia = false,
  }) {
    return BroadcastMessageStep(
      id: id,
      text: text ?? this.text,
      delayAfterMs: delayAfterMs ?? this.delayAfterMs,
      mediaPath: clearMedia ? null : (mediaPath ?? this.mediaPath),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'delayAfterMs': delayAfterMs,
        if (mediaPath != null && mediaPath!.trim().isNotEmpty) 'mediaPath': mediaPath,
      };

  factory BroadcastMessageStep.fromJson(Map<String, dynamic> json) {
    return BroadcastMessageStep(
      id: json['id'] as String? ?? DateTime.now().microsecondsSinceEpoch.toString(),
      text: json['text'] as String? ?? '',
      delayAfterMs: json['delayAfterMs'] as int? ?? 3000,
      mediaPath: (json['mediaPath'] as String?)?.trim().isNotEmpty == true
          ? (json['mediaPath'] as String).trim()
          : null,
    );
  }
}

class BroadcastWorkflowConfig {
  const BroadcastWorkflowConfig({
    this.senderAccountId,
    this.targetChats = const [],
    this.steps = const [],
    this.intervalMinutes = 0,
    this.enabled = false,
  });

  final String? senderAccountId;
  final List<String> targetChats;
  final List<BroadcastMessageStep> steps;
  final int intervalMinutes;
  final bool enabled;

  BroadcastWorkflowConfig copyWith({
    String? senderAccountId,
    List<String>? targetChats,
    List<BroadcastMessageStep>? steps,
    int? intervalMinutes,
    bool? enabled,
  }) {
    return BroadcastWorkflowConfig(
      senderAccountId: senderAccountId ?? this.senderAccountId,
      targetChats: targetChats ?? this.targetChats,
      steps: steps ?? this.steps,
      intervalMinutes: intervalMinutes ?? this.intervalMinutes,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
        if (senderAccountId != null) 'senderAccountId': senderAccountId,
        'targetChats': targetChats,
        'steps': steps.map((s) => s.toJson()).toList(),
        'intervalMinutes': intervalMinutes,
        'enabled': enabled,
      };

  factory BroadcastWorkflowConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const BroadcastWorkflowConfig();
    return BroadcastWorkflowConfig(
      senderAccountId: json['senderAccountId'] as String?,
      targetChats: (json['targetChats'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .where((s) => s.trim().isNotEmpty)
          .toList(),
      steps: (json['steps'] as List<dynamic>? ?? [])
          .map((e) => BroadcastMessageStep.fromJson(e as Map<String, dynamic>))
          .toList(),
      intervalMinutes: json['intervalMinutes'] as int? ?? 0,
      enabled: json['enabled'] as bool? ?? false,
    );
  }
}

class GroupWorkflowConfig {
  const GroupWorkflowConfig({this.targetChats = const []});

  /// Чаты/группы MAX, в которых работает бот в рамках этой карточки.
  final List<String> targetChats;

  GroupWorkflowConfig copyWith({List<String>? targetChats}) {
    return GroupWorkflowConfig(targetChats: targetChats ?? this.targetChats);
  }

  Map<String, dynamic> toJson() => {'targetChats': targetChats};

  factory GroupWorkflowConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const GroupWorkflowConfig();
    return GroupWorkflowConfig(
      targetChats: (json['targetChats'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .where((s) => s.trim().isNotEmpty)
          .toList(),
    );
  }
}

enum MapWorkflowNodeKind { group, broadcast }

class MapWorkflowNode {
  const MapWorkflowNode({
    required this.id,
    required this.kind,
    required this.title,
    required this.x,
    required this.y,
    this.width = 300,
    this.height = 200,
    this.parentGroupId,
    this.group,
    this.broadcast,
  });

  final String id;
  final MapWorkflowNodeKind kind;
  final String title;
  final double x;
  final double y;
  final double width;
  final double height;
  final String? parentGroupId;
  final GroupWorkflowConfig? group;
  final BroadcastWorkflowConfig? broadcast;

  bool get isGroup => kind == MapWorkflowNodeKind.group;
  bool get isBroadcast => kind == MapWorkflowNodeKind.broadcast;

  MapWorkflowNode copyWith({
    String? title,
    double? x,
    double? y,
    double? width,
    double? height,
    String? parentGroupId,
    GroupWorkflowConfig? group,
    BroadcastWorkflowConfig? broadcast,
  }) {
    return MapWorkflowNode(
      id: id,
      kind: kind,
      title: title ?? this.title,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      parentGroupId: parentGroupId ?? this.parentGroupId,
      group: group ?? this.group,
      broadcast: broadcast ?? this.broadcast,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'title': title,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        if (parentGroupId != null) 'parentGroupId': parentGroupId,
        if (group != null) 'group': group!.toJson(),
        if (broadcast != null) 'broadcast': broadcast!.toJson(),
      };

  factory MapWorkflowNode.fromJson(Map<String, dynamic> json) {
    final kind = MapWorkflowNodeKind.values.firstWhere(
      (v) => v.name == json['kind'],
      orElse: () => MapWorkflowNodeKind.broadcast,
    );
    return MapWorkflowNode(
      id: json['id'] as String,
      kind: kind,
      title: json['title'] as String? ?? 'Блок',
      x: (json['x'] as num?)?.toDouble() ?? 600,
      y: (json['y'] as num?)?.toDouble() ?? 120,
      width: (json['width'] as num?)?.toDouble() ?? (kind == MapWorkflowNodeKind.group ? 320 : 220),
      height: (json['height'] as num?)?.toDouble() ?? (kind == MapWorkflowNodeKind.group ? 220 : 130),
      parentGroupId: json['parentGroupId'] as String?,
      group: kind == MapWorkflowNodeKind.group
          ? GroupWorkflowConfig.fromJson(json['group'] as Map<String, dynamic>?)
          : null,
      broadcast: kind == MapWorkflowNodeKind.broadcast
          ? BroadcastWorkflowConfig.fromJson(json['broadcast'] as Map<String, dynamic>?)
          : null,
    );
  }
}

enum WorkflowEdgeKind { owner, contains, sender }

class WorkflowMapEdge {
  const WorkflowMapEdge({
    required this.fromId,
    required this.toId,
    this.kind = WorkflowEdgeKind.sender,
  });

  final String fromId;
  final String toId;
  final WorkflowEdgeKind kind;

  String get key => '$fromId->$toId:${kind.name}';

  Map<String, dynamic> toJson() => {
        'fromId': fromId,
        'toId': toId,
        'kind': kind.name,
      };

  factory WorkflowMapEdge.fromJson(Map<String, dynamic> json) {
    return WorkflowMapEdge(
      fromId: json['fromId'] as String,
      toId: json['toId'] as String,
      kind: WorkflowEdgeKind.values.firstWhere(
        (v) => v.name == json['kind'],
        orElse: () => WorkflowEdgeKind.sender,
      ),
    );
  }
}

extension MapWorkflowNodeListX on List<MapWorkflowNode> {
  MapWorkflowNode? byId(String id) {
    for (final n in this) {
      if (n.id == id) return n;
    }
    return null;
  }
}
