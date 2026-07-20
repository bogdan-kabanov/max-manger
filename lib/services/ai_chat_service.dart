import 'dart:convert';
import 'dart:io';

import '../models/ai_chat_config.dart';

class AiChatService {
  static Future<String> complete({
    required AiChatConfig config,
    required String userMessage,
    String? chatTitle,
    void Function(String message, {String level})? onLog,
  }) async {
    final apiKey = config.apiKey.trim();
    if (apiKey.isEmpty) {
      throw AiChatException('Укажите API-ключ');
    }

    final base = config.apiBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/chat/completions');
    final model = config.model.trim().isEmpty ? 'sonnet-4.6' : config.model.trim();

    onLog?.call('API → POST $uri, модель $model');

    final systemParts = <String>[config.systemPrompt.trim()];
    if (chatTitle != null && chatTitle.isNotEmpty) {
      systemParts.add('Сейчас открыт чат: «$chatTitle».');
    }

    final body = {
      'model': model,
      'messages': [
        {'role': 'system', 'content': systemParts.join('\n')},
        {'role': 'user', 'content': userMessage},
      ],
      'temperature': config.temperature,
      'max_tokens': config.maxTokens,
    };

    final client = HttpClient();
    try {
      final request = await client.postUrl(uri);
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      request.add(utf8.encode(jsonEncode(body)));

      onLog?.call('API → ожидание ответа…');
      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      onLog?.call('API ← HTTP ${response.statusCode}, ${responseBody.length} байт');

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AiChatException(_parseApiError(responseBody, response.statusCode));
      }

      final decoded = jsonDecode(responseBody) as Map<String, dynamic>;
      final choices = decoded['choices'] as List<dynamic>?;
      final message = choices?.isNotEmpty == true
          ? (choices!.first as Map<String, dynamic>)['message'] as Map<String, dynamic>?
          : null;
      final content = message?['content']?.toString().trim();
      if (content == null || content.isEmpty) {
        throw AiChatException('Пустой ответ от ИИ');
      }
      onLog?.call('API ← ответ: ${content.length} символов');
      return content;
    } on AiChatException {
      rethrow;
    } on SocketException {
      throw AiChatException('Нет сети или API недоступен');
    } catch (e) {
      throw AiChatException(e.toString());
    } finally {
      client.close(force: true);
    }
  }

  static String _parseApiError(String body, int status) {
    try {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final error = decoded['error'];
      if (error is Map) {
        return error['message']?.toString() ?? 'HTTP $status';
      }
      if (error is String) return error;
    } catch (_) {}
    return body.isNotEmpty ? body : 'HTTP $status';
  }
}

class AiChatException implements Exception {
  AiChatException(this.message);
  final String message;

  @override
  String toString() => message;
}
