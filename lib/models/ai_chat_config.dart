class AiChatConfig {
  AiChatConfig({
    required this.accountId,
    this.enabled = false,
    this.systemPrompt = 'Ты дружелюбный помощник. Отвечай кратко и по делу на русском языке.',
    this.targetChats = const [],
    this.apiBaseUrl = 'https://api.typfc.com/v1',
    this.apiKey = '',
    this.model = 'sonnet-4.6',
    this.temperature = 0.7,
    this.maxTokens = 500,
    this.replyOnlyToIncoming = true,
  });

  final String accountId;
  final bool enabled;
  final String systemPrompt;
  final List<String> targetChats;
  final String apiBaseUrl;
  final String apiKey;
  final String model;
  final double temperature;
  final int maxTokens;
  final bool replyOnlyToIncoming;

  bool get isConfigured => apiKey.trim().isNotEmpty && apiBaseUrl.trim().isNotEmpty;

  AiChatConfig copyWith({
    bool? enabled,
    String? systemPrompt,
    List<String>? targetChats,
    String? apiBaseUrl,
    String? apiKey,
    String? model,
    double? temperature,
    int? maxTokens,
    bool? replyOnlyToIncoming,
  }) {
    return AiChatConfig(
      accountId: accountId,
      enabled: enabled ?? this.enabled,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      targetChats: targetChats ?? this.targetChats,
      apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      temperature: temperature ?? this.temperature,
      maxTokens: maxTokens ?? this.maxTokens,
      replyOnlyToIncoming: replyOnlyToIncoming ?? this.replyOnlyToIncoming,
    );
  }

  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'enabled': enabled,
        'systemPrompt': systemPrompt,
        'targetChats': targetChats,
        'apiBaseUrl': apiBaseUrl,
        'apiKey': apiKey,
        'model': model,
        'temperature': temperature,
        'maxTokens': maxTokens,
        'replyOnlyToIncoming': replyOnlyToIncoming,
      };

  factory AiChatConfig.fromJson(Map<String, dynamic> json) {
    return AiChatConfig(
      accountId: json['accountId'] as String,
      enabled: json['enabled'] as bool? ?? false,
      systemPrompt: json['systemPrompt'] as String? ??
          'Ты дружелюбный помощник. Отвечай кратко и по делу на русском языке.',
      targetChats: (json['targetChats'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList(),
      apiBaseUrl: json['apiBaseUrl'] as String? ?? 'https://api.typfc.com/v1',
      apiKey: json['apiKey'] as String? ?? '',
      model: json['model'] as String? ?? 'sonnet-4.6',
      temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
      maxTokens: (json['maxTokens'] as num?)?.toInt() ?? 500,
      replyOnlyToIncoming: json['replyOnlyToIncoming'] as bool? ?? true,
    );
  }

  factory AiChatConfig.defaults(String accountId) => AiChatConfig(accountId: accountId);
}
