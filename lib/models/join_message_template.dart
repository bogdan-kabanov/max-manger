import 'package:uuid/uuid.dart';

import 'map_workflow.dart';

/// Named message pack sent by an account after joining a group chat.
class JoinMessageTemplate {
  const JoinMessageTemplate({
    required this.id,
    required this.name,
    this.messages = const [],
    this.delayMs = 5000,
    this.enabled = true,
  });

  final String id;
  final String name;
  final List<BroadcastMessageStep> messages;

  /// Pause after join before the first message.
  final int delayMs;

  /// When false, assigned accounts skip writing.
  final bool enabled;

  bool get hasMessages => messages.any((m) => m.text.trim().isNotEmpty);

  bool get isActive => enabled && hasMessages;

  int get messageCount => messages.where((m) => m.text.trim().isNotEmpty).length;

  JoinMessageTemplate copyWith({
    String? name,
    List<BroadcastMessageStep>? messages,
    int? delayMs,
    bool? enabled,
  }) {
    return JoinMessageTemplate(
      id: id,
      name: name ?? this.name,
      messages: messages ?? this.messages,
      delayMs: delayMs ?? this.delayMs,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'messages': messages.map((m) => m.toJson()).toList(),
        'delayMs': delayMs,
        'enabled': enabled,
      };

  factory JoinMessageTemplate.fromJson(Map<String, dynamic> json) {
    return JoinMessageTemplate(
      id: (json['id'] as String?) ?? const Uuid().v4(),
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? (json['name'] as String).trim()
          : 'Шаблон',
      messages: (json['messages'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(BroadcastMessageStep.fromJson)
          .toList(),
      delayMs: (json['delayMs'] as num?)?.toInt() ?? 5000,
      enabled: json['enabled'] != false,
    );
  }

  static JoinMessageTemplate create({
    String? name,
    List<BroadcastMessageStep>? messages,
    int delayMs = 5000,
  }) {
    return JoinMessageTemplate(
      id: const Uuid().v4(),
      name: name ?? 'Шаблон',
      messages: messages ??
          [
            BroadcastMessageStep(
              id: const Uuid().v4(),
              text: '',
              delayAfterMs: 3000,
            ),
          ],
      delayMs: delayMs,
    );
  }
}
