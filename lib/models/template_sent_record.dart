/// One successful template send into a chat (for status + delete).
class TemplateSentRecord {
  const TemplateSentRecord({
    required this.accountId,
    required this.chatId,
    required this.templateId,
    this.title = '',
    this.messageIds = const [],
    this.sentAt,
  });

  final String accountId;
  final String chatId;
  final String templateId;
  final String title;
  final List<String> messageIds;
  final DateTime? sentAt;

  String get key => '$accountId::$chatId::$templateId';

  TemplateSentRecord copyWith({
    String? title,
    List<String>? messageIds,
    DateTime? sentAt,
  }) {
    return TemplateSentRecord(
      accountId: accountId,
      chatId: chatId,
      templateId: templateId,
      title: title ?? this.title,
      messageIds: messageIds ?? this.messageIds,
      sentAt: sentAt ?? this.sentAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'chatId': chatId,
        'templateId': templateId,
        if (title.trim().isNotEmpty) 'title': title,
        if (messageIds.isNotEmpty) 'messageIds': messageIds,
        if (sentAt != null) 'sentAt': sentAt!.toIso8601String(),
      };

  factory TemplateSentRecord.fromJson(Map<String, dynamic> json) {
    return TemplateSentRecord(
      accountId: json['accountId']?.toString() ?? '',
      chatId: json['chatId']?.toString() ?? '',
      templateId: json['templateId']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      messageIds: (json['messageIds'] as List<dynamic>? ?? const [])
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      sentAt: json['sentAt'] != null
          ? DateTime.tryParse(json['sentAt'].toString())
          : null,
    );
  }
}
