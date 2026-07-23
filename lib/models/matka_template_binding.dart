import 'package:uuid/uuid.dart';

/// When a join-message template should run for a matka's children.
enum MatkaTemplateTrigger {
  onJoin,
  dailyAt;

  String get label => switch (this) {
        onJoin => 'Сразу после входа',
        dailyAt => 'Ежедневно в указанное время',
      };

  static MatkaTemplateTrigger fromJson(String? raw) {
    return switch (raw) {
      'dailyAt' => MatkaTemplateTrigger.dailyAt,
      _ => MatkaTemplateTrigger.onJoin,
    };
  }
}

/// Binds a message template to a matka with a trigger (on-join or daily HH:mm).
class MatkaTemplateBinding {
  const MatkaTemplateBinding({
    required this.id,
    required this.motherAccountId,
    required this.templateId,
    this.trigger = MatkaTemplateTrigger.onJoin,
    this.hour = 12,
    this.minute = 0,
    this.enabled = true,
  });

  final String id;
  final String motherAccountId;
  final String templateId;
  final MatkaTemplateTrigger trigger;

  /// Local time for [MatkaTemplateTrigger.dailyAt].
  final int hour;
  final int minute;
  final bool enabled;

  String get timeLabel {
    final h = hour.clamp(0, 23).toString().padLeft(2, '0');
    final m = minute.clamp(0, 59).toString().padLeft(2, '0');
    return '$h:$m';
  }

  MatkaTemplateBinding copyWith({
    String? motherAccountId,
    String? templateId,
    MatkaTemplateTrigger? trigger,
    int? hour,
    int? minute,
    bool? enabled,
  }) {
    return MatkaTemplateBinding(
      id: id,
      motherAccountId: motherAccountId ?? this.motherAccountId,
      templateId: templateId ?? this.templateId,
      trigger: trigger ?? this.trigger,
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'motherAccountId': motherAccountId,
        'templateId': templateId,
        'trigger': trigger.name,
        'hour': hour,
        'minute': minute,
        'enabled': enabled,
      };

  factory MatkaTemplateBinding.fromJson(Map<String, dynamic> json) {
    return MatkaTemplateBinding(
      id: (json['id'] as String?) ?? const Uuid().v4(),
      motherAccountId: json['motherAccountId']?.toString() ?? '',
      templateId: json['templateId']?.toString() ?? '',
      trigger: MatkaTemplateTrigger.fromJson(json['trigger']?.toString()),
      hour: (json['hour'] as num?)?.toInt().clamp(0, 23) ?? 12,
      minute: (json['minute'] as num?)?.toInt().clamp(0, 59) ?? 0,
      enabled: json['enabled'] != false,
    );
  }

  static MatkaTemplateBinding create({
    required String motherAccountId,
    required String templateId,
    MatkaTemplateTrigger trigger = MatkaTemplateTrigger.onJoin,
    int hour = 12,
    int minute = 0,
  }) {
    return MatkaTemplateBinding(
      id: const Uuid().v4(),
      motherAccountId: motherAccountId,
      templateId: templateId,
      trigger: trigger,
      hour: hour,
      minute: minute,
    );
  }
}
