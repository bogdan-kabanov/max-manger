import 'package:uuid/uuid.dart';

import 'account_isolation.dart';
import 'emulator_profile.dart';

enum MaxAuthMethod { qr, sms, token }

class MaxAccount {
  MaxAccount({
    required this.id,
    required this.label,
    required this.createdAt,
    required this.isolation,
    this.lastOpenedAt,
    this.notes,
    this.phone,
    this.apiToken,
    this.viewerId,
    this.authMethod = MaxAuthMethod.qr,
    this.emulator = const EmulatorProfile(),
  });

  final String id;
  final String label;
  final DateTime createdAt;
  final AccountIsolation isolation;
  final DateTime? lastOpenedAt;
  final String? notes;
  final String? phone;
  final String? apiToken;
  final int? viewerId;
  final MaxAuthMethod authMethod;
  final EmulatorProfile emulator;

  bool get hasApiSession => apiToken != null && apiToken!.isNotEmpty;
  bool get hasEmulator => emulator.isConfigured;

  String get webDeviceId =>
      isolation.deviceId ?? const Uuid().v5(Uuid.NAMESPACE_URL, 'max-desktop-device:$id');

  MaxAccount copyWith({
    String? label,
    AccountIsolation? isolation,
    DateTime? lastOpenedAt,
    String? notes,
    String? phone,
    String? apiToken,
    int? viewerId,
    MaxAuthMethod? authMethod,
    EmulatorProfile? emulator,
  }) {
    return MaxAccount(
      id: id,
      label: label ?? this.label,
      createdAt: createdAt,
      isolation: isolation ?? this.isolation,
      lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
      notes: notes ?? this.notes,
      phone: phone ?? this.phone,
      apiToken: apiToken ?? this.apiToken,
      viewerId: viewerId ?? this.viewerId,
      authMethod: authMethod ?? this.authMethod,
      emulator: emulator ?? this.emulator,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'createdAt': createdAt.toIso8601String(),
        'isolation': isolation.toJson(),
        'lastOpenedAt': lastOpenedAt?.toIso8601String(),
        'notes': notes,
        if (phone != null) 'phone': phone,
        if (apiToken != null) 'apiToken': apiToken,
        if (viewerId != null) 'viewerId': viewerId,
        'authMethod': authMethod.name,
        if (emulator.isConfigured || emulator.lastLaunchedAt != null) 'emulator': emulator.toJson(),
      };

  factory MaxAccount.fromJson(Map<String, dynamic> json) {
    final authRaw = json['authMethod'] as String?;
    return MaxAccount(
      id: json['id'] as String,
      label: json['label'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      isolation: json['isolation'] != null
          ? AccountIsolation.fromJson(json['isolation'] as Map<String, dynamic>)
          : ProfileFingerprint.generate(json['id'] as String),
      lastOpenedAt: json['lastOpenedAt'] != null
          ? DateTime.parse(json['lastOpenedAt'] as String)
          : null,
      notes: json['notes'] as String?,
      phone: json['phone'] as String?,
      apiToken: json['apiToken'] as String?,
      viewerId: (json['viewerId'] as num?)?.toInt(),
      authMethod: authRaw == 'sms'
          ? MaxAuthMethod.sms
          : authRaw == 'token'
              ? MaxAuthMethod.token
              : MaxAuthMethod.qr,
      emulator: EmulatorProfile.fromJson(json['emulator'] as Map<String, dynamic>?),
    );
  }
}
