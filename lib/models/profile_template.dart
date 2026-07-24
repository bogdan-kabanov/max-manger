import 'package:uuid/uuid.dart';

/// Reusable MAX profile look: first/last name, about text, and avatar photo.
class ProfileTemplate {
  const ProfileTemplate({
    required this.id,
    required this.name,
    this.firstName,
    this.lastName,
    this.description,
    this.photoPath,
  });

  final String id;

  /// Internal label in the templates list.
  final String name;

  /// MAX profile first name.
  final String? firstName;

  /// MAX profile last name.
  final String? lastName;

  /// Profile about / description text.
  final String? description;

  /// Absolute path to a local image used as profile photo.
  final String? photoPath;

  bool get hasPhoto => photoPath != null && photoPath!.trim().isNotEmpty;

  bool get hasContent =>
      (firstName?.trim().isNotEmpty == true) ||
      (lastName?.trim().isNotEmpty == true) ||
      (description?.trim().isNotEmpty == true) ||
      hasPhoto;

  /// Back-compat alias used by older call sites.
  String? get displayName => firstName;

  ProfileTemplate copyWith({
    String? name,
    String? firstName,
    String? lastName,
    String? description,
    String? photoPath,
    bool clearFirstName = false,
    bool clearLastName = false,
    bool clearDescription = false,
    bool clearPhoto = false,
  }) {
    return ProfileTemplate(
      id: id,
      name: name ?? this.name,
      firstName: clearFirstName ? null : (firstName ?? this.firstName),
      lastName: clearLastName ? null : (lastName ?? this.lastName),
      description: clearDescription ? null : (description ?? this.description),
      photoPath: clearPhoto ? null : (photoPath ?? this.photoPath),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (firstName != null && firstName!.trim().isNotEmpty)
          'firstName': firstName!.trim(),
        if (lastName != null && lastName!.trim().isNotEmpty)
          'lastName': lastName!.trim(),
        if (description != null && description!.trim().isNotEmpty)
          'description': description!.trim(),
        if (photoPath != null && photoPath!.trim().isNotEmpty)
          'photoPath': photoPath!.trim(),
      };

  factory ProfileTemplate.fromJson(Map<String, dynamic> json) {
    // Migrate older templates that stored a single `displayName`.
    final legacyName = (json['displayName'] as String?)?.trim();
    final first = (json['firstName'] as String?)?.trim();
    return ProfileTemplate(
      id: (json['id'] as String?) ?? const Uuid().v4(),
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? (json['name'] as String).trim()
          : 'Шаблон профиля',
      firstName: (first != null && first.isNotEmpty)
          ? first
          : (legacyName != null && legacyName.isNotEmpty ? legacyName : null),
      lastName: (json['lastName'] as String?)?.trim().isNotEmpty == true
          ? (json['lastName'] as String).trim()
          : null,
      description: (json['description'] as String?)?.trim().isNotEmpty == true
          ? (json['description'] as String).trim()
          : null,
      photoPath: (json['photoPath'] as String?)?.trim().isNotEmpty == true
          ? (json['photoPath'] as String).trim()
          : null,
    );
  }

  static ProfileTemplate create({String? name}) {
    return ProfileTemplate(
      id: const Uuid().v4(),
      name: name ?? 'Шаблон профиля',
    );
  }
}
