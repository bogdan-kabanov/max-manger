/// Timing knobs for mother joins and Uzbek account messaging.
class RateSettings {
  const RateSettings({
    this.motherJoinDelayMs = 2500,
    this.uzbekMessageDelayMs = 5000,
    this.uzbekChatGapMs = 2000,
  });

  /// Pause between mother join / invite / forward steps.
  final int motherJoinDelayMs;

  /// Minimum pause between messages when sender is a UZ account.
  final int uzbekMessageDelayMs;

  /// Pause between target chats when sender is a UZ account.
  final int uzbekChatGapMs;

  static const defaults = RateSettings();

  RateSettings copyWith({
    int? motherJoinDelayMs,
    int? uzbekMessageDelayMs,
    int? uzbekChatGapMs,
  }) {
    return RateSettings(
      motherJoinDelayMs: motherJoinDelayMs ?? this.motherJoinDelayMs,
      uzbekMessageDelayMs: uzbekMessageDelayMs ?? this.uzbekMessageDelayMs,
      uzbekChatGapMs: uzbekChatGapMs ?? this.uzbekChatGapMs,
    );
  }

  Map<String, dynamic> toJson() => {
        'motherJoinDelayMs': motherJoinDelayMs,
        'uzbekMessageDelayMs': uzbekMessageDelayMs,
        'uzbekChatGapMs': uzbekChatGapMs,
      };

  factory RateSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) return defaults;
    return RateSettings(
      motherJoinDelayMs: _clampMs(json['motherJoinDelayMs'], defaults.motherJoinDelayMs),
      uzbekMessageDelayMs: _clampMs(json['uzbekMessageDelayMs'], defaults.uzbekMessageDelayMs),
      uzbekChatGapMs: _clampMs(json['uzbekChatGapMs'], defaults.uzbekChatGapMs),
    );
  }

  static int _clampMs(Object? raw, int fallback) {
    final value = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
    if (value == null) return fallback;
    return value.clamp(200, 120000);
  }
}
