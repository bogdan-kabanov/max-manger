import 'package:uuid/uuid.dart';

import 'map_workflow.dart';

/// Named message pack sent by an account after joining a group chat.
class JoinMessageTemplate {
  const JoinMessageTemplate({
    required this.id,
    required this.name,
    this.messages = const [],
    this.delayMs = 5000,
    this.chatGapMs = 60000,
    this.repeatEnabled = false,
    this.repeatIntervalMs = 3600000,
    this.enabled = true,
  });

  final String id;
  final String name;
  final List<BroadcastMessageStep> messages;

  /// Pause after join before the first message.
  final int delayMs;

  /// Gap between chats when broadcasting (1st at 0, 2nd after 1×gap, …).
  final int chatGapMs;

  /// When true, after a broadcast finishes, schedule another after [repeatIntervalMs].
  final bool repeatEnabled;

  /// Interval between automatic re-broadcasts when [repeatEnabled].
  final int repeatIntervalMs;

  /// When false, assigned accounts skip writing.
  final bool enabled;

  bool get hasMessages => messages.any((m) => m.hasContent);

  bool get isActive => enabled && hasMessages;

  int get messageCount => messages.where((m) => m.hasContent).length;

  JoinMessageTemplate copyWith({
    String? name,
    List<BroadcastMessageStep>? messages,
    int? delayMs,
    int? chatGapMs,
    bool? repeatEnabled,
    int? repeatIntervalMs,
    bool? enabled,
  }) {
    return JoinMessageTemplate(
      id: id,
      name: name ?? this.name,
      messages: messages ?? this.messages,
      delayMs: delayMs ?? this.delayMs,
      chatGapMs: chatGapMs ?? this.chatGapMs,
      repeatEnabled: repeatEnabled ?? this.repeatEnabled,
      repeatIntervalMs: repeatIntervalMs ?? this.repeatIntervalMs,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'messages': messages.map((m) => m.toJson()).toList(),
        'delayMs': delayMs,
        'chatGapMs': chatGapMs,
        'repeatEnabled': repeatEnabled,
        'repeatIntervalMs': repeatIntervalMs,
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
      chatGapMs: (json['chatGapMs'] as num?)?.toInt() ?? 60000,
      repeatEnabled: json['repeatEnabled'] == true,
      repeatIntervalMs: (json['repeatIntervalMs'] as num?)?.toInt() ?? 3600000,
      enabled: json['enabled'] != false,
    );
  }

  static JoinMessageTemplate create({
    String? name,
    List<BroadcastMessageStep>? messages,
    int delayMs = 5000,
    int chatGapMs = 60000,
  }) {
    return JoinMessageTemplate(
      id: const Uuid().v4(),
      name: name ?? 'Шаблон',
      messages: messages ??
          [
            BroadcastMessageStep(
              id: const Uuid().v4(),
              text: '',
            ),
          ],
      delayMs: delayMs,
      chatGapMs: chatGapMs,
    );
  }
}
