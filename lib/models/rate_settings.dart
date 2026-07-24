/// Timing knobs for mother joins and Uzbek account messaging.
class RateSettings {
  const RateSettings({
    this.motherJoinDelayMs = 2500,
    this.inviteAfterJoinDelayMs = 0,
    this.uzbekMessageDelayMs = 5000,
    this.uzbekChatGapMs = 2000,
  });

  /// Pause between mother join / invite / forward steps (between groups).
  final int motherJoinDelayMs;

  /// After mother joins a group, wait this long before inviting daughters.
  /// `0` = invite immediately in the same session.
  final int inviteAfterJoinDelayMs;

  /// Minimum pause between messages when sender is a UZ account.
  final int uzbekMessageDelayMs;

  /// Pause between target chats when sender is a UZ account.
  final int uzbekChatGapMs;

  static const defaults = RateSettings();

  RateSettings copyWith({
    int? motherJoinDelayMs,
    int? inviteAfterJoinDelayMs,
    int? uzbekMessageDelayMs,
    int? uzbekChatGapMs,
  }) {
    return RateSettings(
      motherJoinDelayMs: motherJoinDelayMs ?? this.motherJoinDelayMs,
      inviteAfterJoinDelayMs: inviteAfterJoinDelayMs ?? this.inviteAfterJoinDelayMs,
      uzbekMessageDelayMs: uzbekMessageDelayMs ?? this.uzbekMessageDelayMs,
      uzbekChatGapMs: uzbekChatGapMs ?? this.uzbekChatGapMs,
    );
  }

  Map<String, dynamic> toJson() => {
        'motherJoinDelayMs': motherJoinDelayMs,
        'inviteAfterJoinDelayMs': inviteAfterJoinDelayMs,
        'uzbekMessageDelayMs': uzbekMessageDelayMs,
        'uzbekChatGapMs': uzbekChatGapMs,
      };

  factory RateSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) return defaults;
    return RateSettings(
      motherJoinDelayMs: _clampMs(json['motherJoinDelayMs'], defaults.motherJoinDelayMs),
      inviteAfterJoinDelayMs: _clampMsAllowZero(
        json['inviteAfterJoinDelayMs'],
        defaults.inviteAfterJoinDelayMs,
      ),
      uzbekMessageDelayMs: _clampMs(json['uzbekMessageDelayMs'], defaults.uzbekMessageDelayMs),
      uzbekChatGapMs: _clampMs(json['uzbekChatGapMs'], defaults.uzbekChatGapMs),
    );
  }

  static int _clampMs(Object? raw, int fallback) {
    final value = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
    if (value == null) return fallback;
    return value.clamp(200, 120000);
  }

  static int _clampMsAllowZero(Object? raw, int fallback) {
    final value = raw is int ? raw : int.tryParse(raw?.toString() ?? '');
    if (value == null) return fallback;
    return value.clamp(0, 600000);
  }
}
