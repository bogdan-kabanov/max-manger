import 'macro_step.dart';

enum MacroTarget { web, emulator }

class MacroScenario {
  MacroScenario({
    required this.id,
    required this.accountId,
    required this.name,
    required this.steps,
    this.enabled = false,
    this.intervalMinutes = 60,
    this.lastRunAt,
    this.target = MacroTarget.web,
  });

  final String id;
  final String accountId;
  final String name;
  final List<MacroStep> steps;
  final bool enabled;
  final int intervalMinutes;
  final DateTime? lastRunAt;
  final MacroTarget target;

  bool get isEmulator => target == MacroTarget.emulator;

  MacroScenario copyWith({
    String? name,
    List<MacroStep>? steps,
    bool? enabled,
    int? intervalMinutes,
    DateTime? lastRunAt,
    MacroTarget? target,
  }) {
    return MacroScenario(
      id: id,
      accountId: accountId,
      name: name ?? this.name,
      steps: steps ?? this.steps,
      enabled: enabled ?? this.enabled,
      intervalMinutes: intervalMinutes ?? this.intervalMinutes,
      lastRunAt: lastRunAt ?? this.lastRunAt,
      target: target ?? this.target,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'accountId': accountId,
        'name': name,
        'steps': steps.map((s) => s.toJson()).toList(),
        'enabled': enabled,
        'intervalMinutes': intervalMinutes,
        'lastRunAt': lastRunAt?.toIso8601String(),
        'target': target.name,
      };

  factory MacroScenario.fromJson(Map<String, dynamic> json) {
    MacroTarget target;
    try {
      target = MacroTarget.values.byName(json['target'] as String? ?? 'web');
    } catch (_) {
      target = MacroTarget.web;
    }
    return MacroScenario(
      id: json['id'] as String,
      accountId: json['accountId'] as String,
      name: json['name'] as String,
      steps: (json['steps'] as List<dynamic>? ?? [])
          .map((e) => MacroStep.fromJson(e as Map<String, dynamic>))
          .toList(),
      enabled: json['enabled'] as bool? ?? false,
      intervalMinutes: json['intervalMinutes'] as int? ?? 60,
      lastRunAt: json['lastRunAt'] != null
          ? DateTime.parse(json['lastRunAt'] as String)
          : null,
      target: target,
    );
  }
}
