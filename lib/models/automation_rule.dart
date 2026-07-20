enum AutomationRuleType { keywordReply, autoReply }

class AutomationRule {
  AutomationRule({
    required this.id,
    required this.accountId,
    required this.name,
    required this.type,
    required this.enabled,
    this.keywords = const [],
    this.replyText = '',
    this.matchContains = true,
  });

  final String id;
  final String accountId;
  final String name;
  final AutomationRuleType type;
  final bool enabled;
  final List<String> keywords;
  final String replyText;
  final bool matchContains;

  AutomationRule copyWith({
    String? name,
    bool? enabled,
    List<String>? keywords,
    String? replyText,
    bool? matchContains,
  }) {
    return AutomationRule(
      id: id,
      accountId: accountId,
      name: name ?? this.name,
      type: type,
      enabled: enabled ?? this.enabled,
      keywords: keywords ?? this.keywords,
      replyText: replyText ?? this.replyText,
      matchContains: matchContains ?? this.matchContains,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'accountId': accountId,
        'name': name,
        'type': type.name,
        'enabled': enabled,
        'keywords': keywords,
        'replyText': replyText,
        'matchContains': matchContains,
      };

  factory AutomationRule.fromJson(Map<String, dynamic> json) {
    return AutomationRule(
      id: json['id'] as String,
      accountId: json['accountId'] as String,
      name: json['name'] as String,
      type: AutomationRuleType.values.byName(json['type'] as String),
      enabled: json['enabled'] as bool? ?? true,
      keywords: (json['keywords'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      replyText: json['replyText'] as String? ?? '',
      matchContains: json['matchContains'] as bool? ?? true,
    );
  }
}
