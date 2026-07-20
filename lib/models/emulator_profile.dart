/// Android emulator binding for an account profile.
class EmulatorProfile {
  const EmulatorProfile({
    this.avdName,
    this.createdAt,
    this.lastLaunchedAt,
    this.deviceLocale = 'ru-RU',
    this.gpsLat,
    this.gpsLon,
  });

  final String? avdName;
  final DateTime? createdAt;
  final DateTime? lastLaunchedAt;
  final String deviceLocale;
  final double? gpsLat;
  final double? gpsLon;

  bool get isConfigured => avdName != null && avdName!.isNotEmpty;

  EmulatorProfile copyWith({
    String? avdName,
    DateTime? createdAt,
    DateTime? lastLaunchedAt,
    String? deviceLocale,
    double? gpsLat,
    double? gpsLon,
    bool clearAvd = false,
  }) {
    return EmulatorProfile(
      avdName: clearAvd ? null : (avdName ?? this.avdName),
      createdAt: createdAt ?? this.createdAt,
      lastLaunchedAt: lastLaunchedAt ?? this.lastLaunchedAt,
      deviceLocale: deviceLocale ?? this.deviceLocale,
      gpsLat: gpsLat ?? this.gpsLat,
      gpsLon: gpsLon ?? this.gpsLon,
    );
  }

  Map<String, dynamic> toJson() => {
        if (avdName != null) 'avdName': avdName,
        if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
        if (lastLaunchedAt != null) 'lastLaunchedAt': lastLaunchedAt!.toIso8601String(),
        'deviceLocale': deviceLocale,
        if (gpsLat != null) 'gpsLat': gpsLat,
        if (gpsLon != null) 'gpsLon': gpsLon,
      };

  factory EmulatorProfile.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const EmulatorProfile();
    return EmulatorProfile(
      avdName: json['avdName'] as String?,
      createdAt: json['createdAt'] != null ? DateTime.parse(json['createdAt'] as String) : null,
      lastLaunchedAt:
          json['lastLaunchedAt'] != null ? DateTime.parse(json['lastLaunchedAt'] as String) : null,
      deviceLocale: json['deviceLocale'] as String? ?? 'ru-RU',
      gpsLat: (json['gpsLat'] as num?)?.toDouble(),
      gpsLon: (json['gpsLon'] as num?)?.toDouble(),
    );
  }
}
