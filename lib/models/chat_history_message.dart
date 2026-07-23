/// Normalized chat/channel post from GET_HISTORY.
class ChatHistoryMessage {
  const ChatHistoryMessage({
    required this.id,
    required this.chatId,
    this.time,
    this.text = '',
    this.type = 'USER',
    this.sender,
    this.hasPhoto = false,
    this.hasMedia = false,
    this.attachCount = 0,
    this.isForward = false,
    this.preview = '',
    this.raw,
  });

  final String id;
  final String chatId;
  final int? time;
  final String text;
  final String type;
  final dynamic sender;
  final bool hasPhoto;
  final bool hasMedia;
  final int attachCount;
  final bool isForward;
  final String preview;

  /// Original payload for native forward (optional).
  final Map<String, dynamic>? raw;

  DateTime? get sentAt =>
      time == null || time! <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(time!);

  factory ChatHistoryMessage.fromJson(Map<String, dynamic> json) {
    return ChatHistoryMessage(
      id: (json['id'] ?? json['messageId'] ?? '').toString().trim(),
      chatId: (json['chatId'] ?? '').toString().trim(),
      time: (json['time'] as num?)?.toInt(),
      text: json['text']?.toString() ?? '',
      type: json['type']?.toString() ?? 'USER',
      sender: json['sender'],
      hasPhoto: json['hasPhoto'] == true,
      hasMedia: json['hasMedia'] == true,
      attachCount: (json['attachCount'] as num?)?.toInt() ?? 0,
      isForward: json['isForward'] == true,
      preview: json['preview']?.toString() ?? json['text']?.toString() ?? '',
      raw: json['raw'] is Map
          ? Map<String, dynamic>.from(json['raw'] as Map)
          : null,
    );
  }
}
