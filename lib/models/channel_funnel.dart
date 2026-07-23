import 'package:uuid/uuid.dart';

/// One stage inside a channel funnel (воронка) — checklist / run order.
enum FunnelStepKind {
  createChannel,
  configure,
  publish,
  delay,
  custom,
}

class FunnelStep {
  const FunnelStep({
    required this.id,
    required this.title,
    this.kind = FunnelStepKind.custom,
    this.note,
    this.delayMs = 0,
  });

  final String id;
  final String title;
  final FunnelStepKind kind;
  final String? note;
  final int delayMs;

  FunnelStep copyWith({
    String? title,
    FunnelStepKind? kind,
    String? note,
    int? delayMs,
    bool clearNote = false,
  }) {
    return FunnelStep(
      id: id,
      title: title ?? this.title,
      kind: kind ?? this.kind,
      note: clearNote ? null : (note ?? this.note),
      delayMs: delayMs ?? this.delayMs,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'kind': kind.name,
        if (note != null && note!.trim().isNotEmpty) 'note': note,
        'delayMs': delayMs,
      };

  factory FunnelStep.fromJson(Map<String, dynamic> json) {
    final kindName = json['kind'] as String?;
    return FunnelStep(
      id: (json['id'] as String?) ?? const Uuid().v4(),
      title: (json['title'] as String?)?.trim().isNotEmpty == true
          ? (json['title'] as String).trim()
          : 'Этап',
      kind: FunnelStepKind.values.firstWhere(
        (k) => k.name == kindName,
        orElse: () => FunnelStepKind.custom,
      ),
      note: (json['note'] as String?)?.trim().isNotEmpty == true
          ? (json['note'] as String).trim()
          : null,
      delayMs: (json['delayMs'] as num?)?.toInt() ?? 0,
    );
  }

  static FunnelStep create({
    String? title,
    FunnelStepKind kind = FunnelStepKind.custom,
    String? note,
    int delayMs = 0,
  }) {
    return FunnelStep(
      id: const Uuid().v4(),
      title: title ?? 'Этап',
      kind: kind,
      note: note,
      delayMs: delayMs,
    );
  }
}

/// Post published into the created channel when the funnel runs.
class FunnelPublication {
  const FunnelPublication({
    required this.id,
    required this.text,
    this.delayAfterMs = 3000,
    this.mediaPath,
  });

  final String id;
  final String text;
  final int delayAfterMs;
  final String? mediaPath;

  FunnelPublication copyWith({
    String? text,
    int? delayAfterMs,
    String? mediaPath,
    bool clearMedia = false,
  }) {
    return FunnelPublication(
      id: id,
      text: text ?? this.text,
      delayAfterMs: delayAfterMs ?? this.delayAfterMs,
      mediaPath: clearMedia ? null : (mediaPath ?? this.mediaPath),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'delayAfterMs': delayAfterMs,
        if (mediaPath != null && mediaPath!.trim().isNotEmpty) 'mediaPath': mediaPath,
      };

  factory FunnelPublication.fromJson(Map<String, dynamic> json) {
    return FunnelPublication(
      id: (json['id'] as String?) ?? const Uuid().v4(),
      text: json['text'] as String? ?? '',
      delayAfterMs: (json['delayAfterMs'] as num?)?.toInt() ?? 3000,
      mediaPath: (json['mediaPath'] as String?)?.trim().isNotEmpty == true
          ? (json['mediaPath'] as String).trim()
          : null,
    );
  }

  static FunnelPublication create({String? text, int delayAfterMs = 3000, String? mediaPath}) {
    return FunnelPublication(
      id: const Uuid().v4(),
      text: text ?? '',
      delayAfterMs: delayAfterMs,
      mediaPath: mediaPath,
    );
  }
}

/// Named funnel: channel template + publications + stages for assigned accounts.
class ChannelFunnel {
  const ChannelFunnel({
    required this.id,
    required this.name,
    this.description,
    this.channelTitle = 'Канал {account}',
    this.channelDescription,
    this.channelPhotoPath,
    this.publications = const [],
    this.steps = const [],
    this.privateChannel = false,
    this.commentsEnabled = true,
    this.accountGapMs = 5000,
    this.publishAfterCreate = true,
  });

  final String id;
  final String name;
  final String? description;

  /// Template for the created channel title.
  /// Placeholders: `{account}`, `{n}`, `{cluster}`, `{date}`.
  final String channelTitle;

  /// Template for the created channel about/description text.
  final String? channelDescription;

  /// Absolute path to local image used as channel photo / first media post.
  final String? channelPhotoPath;

  final List<FunnelPublication> publications;
  final List<FunnelStep> steps;

  /// Prefer private invite link (when API supports it).
  final bool privateChannel;

  /// Intent: allow comments in channel (applied when API supports it).
  final bool commentsEnabled;

  /// Pause between accounts during a funnel run.
  final int accountGapMs;

  /// After creating a channel, publish [publications] into it.
  final bool publishAfterCreate;

  int get stepCount => steps.length;
  int get publicationCount => publications.length;

  bool get hasChannelPhoto =>
      channelPhotoPath != null && channelPhotoPath!.trim().isNotEmpty;

  ChannelFunnel copyWith({
    String? name,
    String? description,
    String? channelTitle,
    String? channelDescription,
    String? channelPhotoPath,
    List<FunnelPublication>? publications,
    List<FunnelStep>? steps,
    bool? privateChannel,
    bool? commentsEnabled,
    int? accountGapMs,
    bool? publishAfterCreate,
    bool clearDescription = false,
    bool clearChannelDescription = false,
    bool clearChannelPhoto = false,
  }) {
    return ChannelFunnel(
      id: id,
      name: name ?? this.name,
      description: clearDescription ? null : (description ?? this.description),
      channelTitle: channelTitle ?? this.channelTitle,
      channelDescription: clearChannelDescription
          ? null
          : (channelDescription ?? this.channelDescription),
      channelPhotoPath:
          clearChannelPhoto ? null : (channelPhotoPath ?? this.channelPhotoPath),
      publications: publications ?? this.publications,
      steps: steps ?? this.steps,
      privateChannel: privateChannel ?? this.privateChannel,
      commentsEnabled: commentsEnabled ?? this.commentsEnabled,
      accountGapMs: accountGapMs ?? this.accountGapMs,
      publishAfterCreate: publishAfterCreate ?? this.publishAfterCreate,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (description != null && description!.trim().isNotEmpty)
          'description': description,
        'channelTitle': channelTitle,
        if (channelDescription != null && channelDescription!.trim().isNotEmpty)
          'channelDescription': channelDescription,
        if (channelPhotoPath != null && channelPhotoPath!.trim().isNotEmpty)
          'channelPhotoPath': channelPhotoPath,
        'publications': publications.map((p) => p.toJson()).toList(),
        'steps': steps.map((s) => s.toJson()).toList(),
        'privateChannel': privateChannel,
        'commentsEnabled': commentsEnabled,
        'accountGapMs': accountGapMs,
        'publishAfterCreate': publishAfterCreate,
      };

  factory ChannelFunnel.fromJson(Map<String, dynamic> json) {
    return ChannelFunnel(
      id: (json['id'] as String?) ?? const Uuid().v4(),
      name: (json['name'] as String?)?.trim().isNotEmpty == true
          ? (json['name'] as String).trim()
          : 'Воронка',
      description: (json['description'] as String?)?.trim().isNotEmpty == true
          ? (json['description'] as String).trim()
          : null,
      channelTitle: (json['channelTitle'] as String?)?.trim().isNotEmpty == true
          ? (json['channelTitle'] as String).trim()
          : 'Канал {account}',
      channelDescription:
          (json['channelDescription'] as String?)?.trim().isNotEmpty == true
              ? (json['channelDescription'] as String).trim()
              : null,
      channelPhotoPath:
          (json['channelPhotoPath'] as String?)?.trim().isNotEmpty == true
              ? (json['channelPhotoPath'] as String).trim()
              : null,
      publications: (json['publications'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(FunnelPublication.fromJson)
          .toList(),
      steps: (json['steps'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(FunnelStep.fromJson)
          .toList(),
      privateChannel: json['privateChannel'] as bool? ?? false,
      commentsEnabled: json['commentsEnabled'] as bool? ?? true,
      accountGapMs: (json['accountGapMs'] as num?)?.toInt() ?? 5000,
      publishAfterCreate: json['publishAfterCreate'] as bool? ?? true,
    );
  }

  static ChannelFunnel create({
    String? name,
    String? description,
    String? channelTitle,
    String? channelDescription,
    String? channelPhotoPath,
    List<FunnelPublication>? publications,
    List<FunnelStep>? steps,
  }) {
    return ChannelFunnel(
      id: const Uuid().v4(),
      name: name ?? 'Воронка',
      description: description,
      channelTitle: channelTitle ?? 'Канал {account}',
      channelDescription: channelDescription,
      channelPhotoPath: channelPhotoPath,
      publications: publications ??
          [
            FunnelPublication.create(text: 'Добро пожаловать в канал!'),
          ],
      steps: steps ??
          [
            FunnelStep.create(title: 'Создание канала', kind: FunnelStepKind.createChannel),
            FunnelStep.create(title: 'Настройка', kind: FunnelStepKind.configure),
            FunnelStep.create(title: 'Публикации', kind: FunnelStepKind.publish),
          ],
    );
  }
}

/// Per-account policy: may create channels and which funnels it uses.
class AccountChannelPolicy {
  const AccountChannelPolicy({
    required this.accountId,
    this.canCreateChannels = false,
    this.funnelIds = const {},
    this.lastCreatedChatId,
    this.lastCreatedTitle,
    this.lastCreatedInviteUrl,
  });

  final String accountId;
  final bool canCreateChannels;
  final Set<String> funnelIds;
  final String? lastCreatedChatId;
  final String? lastCreatedTitle;

  /// Invite URL of the last funnel-created channel (`https://max.ru/join/…`).
  final String? lastCreatedInviteUrl;

  AccountChannelPolicy copyWith({
    bool? canCreateChannels,
    Set<String>? funnelIds,
    String? lastCreatedChatId,
    String? lastCreatedTitle,
    String? lastCreatedInviteUrl,
    bool clearLastCreated = false,
  }) {
    return AccountChannelPolicy(
      accountId: accountId,
      canCreateChannels: canCreateChannels ?? this.canCreateChannels,
      funnelIds: funnelIds ?? this.funnelIds,
      lastCreatedChatId:
          clearLastCreated ? null : (lastCreatedChatId ?? this.lastCreatedChatId),
      lastCreatedTitle:
          clearLastCreated ? null : (lastCreatedTitle ?? this.lastCreatedTitle),
      lastCreatedInviteUrl: clearLastCreated
          ? null
          : (lastCreatedInviteUrl ?? this.lastCreatedInviteUrl),
    );
  }

  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'canCreateChannels': canCreateChannels,
        'funnelIds': funnelIds.toList(),
        if (lastCreatedChatId != null) 'lastCreatedChatId': lastCreatedChatId,
        if (lastCreatedTitle != null) 'lastCreatedTitle': lastCreatedTitle,
        if (lastCreatedInviteUrl != null && lastCreatedInviteUrl!.trim().isNotEmpty)
          'lastCreatedInviteUrl': lastCreatedInviteUrl,
      };

  factory AccountChannelPolicy.fromJson(Map<String, dynamic> json) {
    return AccountChannelPolicy(
      accountId: json['accountId'] as String? ?? '',
      canCreateChannels: json['canCreateChannels'] as bool? ?? false,
      funnelIds: (json['funnelIds'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toSet(),
      lastCreatedChatId: json['lastCreatedChatId'] as String?,
      lastCreatedTitle: json['lastCreatedTitle'] as String?,
      lastCreatedInviteUrl:
          (json['lastCreatedInviteUrl'] as String?)?.trim().isNotEmpty == true
              ? (json['lastCreatedInviteUrl'] as String).trim()
              : null,
    );
  }
}
