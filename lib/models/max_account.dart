import 'package:uuid/uuid.dart';

import 'account_isolation.dart';
import 'emulator_profile.dart';

enum MaxAuthMethod { qr, sms, token }

/// Live check against MAX API (login-by-token).
enum AccountHealthStatus {
  /// Not checked yet (or no token to check).
  unknown,

  /// Token accepted — account is reachable.
  ok,

  /// MAX rejected login with ban / block / suspend signals.
  banned,

  /// Token rejected or session invalid (not clearly a ban).
  authFailed,

  /// DNS / proxy / network — status unknown.
  networkError,
}

extension AccountHealthStatusX on AccountHealthStatus {
  String get shortLabel => switch (this) {
        AccountHealthStatus.unknown => 'не проверен',
        AccountHealthStatus.ok => 'активен',
        AccountHealthStatus.banned => 'бан',
        AccountHealthStatus.authFailed => 'токен мёртв',
        AccountHealthStatus.networkError => 'сеть',
      };

  String get longLabel => switch (this) {
        AccountHealthStatus.unknown => 'Статус не проверялся',
        AccountHealthStatus.ok => 'Аккаунт доступен',
        AccountHealthStatus.banned => 'Аккаунт заблокирован (бан)',
        AccountHealthStatus.authFailed => 'Токен не принят MAX',
        AccountHealthStatus.networkError => 'Не удалось проверить (сеть/прокси)',
      };

  bool get isProblem =>
      this == AccountHealthStatus.banned || this == AccountHealthStatus.authFailed;
}

class MaxAccount {
  MaxAccount({
    required this.id,
    required this.label,
    required this.createdAt,
    required this.isolation,
    this.lastOpenedAt,
    this.notes,
    this.phone,
    this.firstName,
    this.lastName,
    this.description,
    this.apiToken,
    this.viewerId,
    this.authMethod = MaxAuthMethod.qr,
    this.emulator = const EmulatorProfile(),
    this.healthStatus = AccountHealthStatus.unknown,
    this.lastError,
    this.lastCheckedAt,
  });

  final String id;
  final String label;
  final DateTime createdAt;
  final AccountIsolation isolation;
  final DateTime? lastOpenedAt;
  final String? notes;
  final String? phone;
  final String? firstName;
  final String? lastName;
  final String? description;
  final String? apiToken;
  final int? viewerId;
  final MaxAuthMethod authMethod;
  final EmulatorProfile emulator;
  final AccountHealthStatus healthStatus;
  final String? lastError;
  final DateTime? lastCheckedAt;

  bool get hasApiSession => apiToken != null && apiToken!.isNotEmpty;
  bool get hasEmulator => emulator.isConfigured;
  bool get isBanned => healthStatus == AccountHealthStatus.banned;
  bool get isHealthy => healthStatus == AccountHealthStatus.ok;

  /// Display «Имя Фамилия» when profile fields are known.
  String get profileDisplayName {
    final parts = [
      if (firstName?.trim().isNotEmpty == true) firstName!.trim(),
      if (lastName?.trim().isNotEmpty == true) lastName!.trim(),
    ];
    if (parts.isNotEmpty) return parts.join(' ');
    return label;
  }

  /// Uzbek accounts: +998 phone, or «узб»/«uzb» in label/notes.
  bool get isUzbek {
    final digits = (phone ?? '').replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith('998') && digits.length >= 12) return true;
    final text = '${label.toLowerCase()} ${(notes ?? '').toLowerCase()}';
    return text.contains('узб') || text.contains('uzb') || text.contains('uzbek');
  }

  String get webDeviceId =>
      isolation.deviceId ?? const Uuid().v5(Uuid.NAMESPACE_URL, 'max-desktop-device:$id');

  MaxAccount copyWith({
    String? label,
    AccountIsolation? isolation,
    DateTime? lastOpenedAt,
    String? notes,
    String? phone,
    String? firstName,
    String? lastName,
    String? description,
    String? apiToken,
    int? viewerId,
    MaxAuthMethod? authMethod,
    EmulatorProfile? emulator,
    AccountHealthStatus? healthStatus,
    String? lastError,
    bool clearLastError = false,
    DateTime? lastCheckedAt,
  }) {
    return MaxAccount(
      id: id,
      label: label ?? this.label,
      createdAt: createdAt,
      isolation: isolation ?? this.isolation,
      lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
      notes: notes ?? this.notes,
      phone: phone ?? this.phone,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      description: description ?? this.description,
      apiToken: apiToken ?? this.apiToken,
      viewerId: viewerId ?? this.viewerId,
      authMethod: authMethod ?? this.authMethod,
      emulator: emulator ?? this.emulator,
      healthStatus: healthStatus ?? this.healthStatus,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
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
        if (firstName != null) 'firstName': firstName,
        if (lastName != null) 'lastName': lastName,
        if (description != null) 'description': description,
        if (apiToken != null) 'apiToken': apiToken,
        if (viewerId != null) 'viewerId': viewerId,
        'authMethod': authMethod.name,
        if (emulator.isConfigured || emulator.lastLaunchedAt != null) 'emulator': emulator.toJson(),
        'healthStatus': healthStatus.name,
        if (lastError != null) 'lastError': lastError,
        if (lastCheckedAt != null) 'lastCheckedAt': lastCheckedAt!.toIso8601String(),
      };

  factory MaxAccount.fromJson(Map<String, dynamic> json) {
    final authRaw = json['authMethod'] as String?;
    final healthRaw = json['healthStatus'] as String?;
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
      firstName: json['firstName'] as String?,
      lastName: json['lastName'] as String?,
      description: json['description'] as String?,
      apiToken: json['apiToken'] as String?,
      viewerId: (json['viewerId'] as num?)?.toInt(),
      authMethod: authRaw == 'sms'
          ? MaxAuthMethod.sms
          : authRaw == 'token'
              ? MaxAuthMethod.token
              : MaxAuthMethod.qr,
      emulator: EmulatorProfile.fromJson(json['emulator'] as Map<String, dynamic>?),
      healthStatus: _parseHealth(healthRaw),
      lastError: json['lastError'] as String?,
      lastCheckedAt: json['lastCheckedAt'] != null
          ? DateTime.tryParse(json['lastCheckedAt'] as String)
          : null,
    );
  }

  static AccountHealthStatus _parseHealth(String? raw) {
    if (raw == null) return AccountHealthStatus.unknown;
    for (final value in AccountHealthStatus.values) {
      if (value.name == raw) return value;
    }
    return AccountHealthStatus.unknown;
  }
}
