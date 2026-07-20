import 'dart:convert';

import 'max_auth_service.dart';

/// Parsed session from a console snippet / text file
/// (localStorage.setItem + __oneme_auth JSON, plain An_ token, etc.).
class ParsedAuthSnippet {
  const ParsedAuthSnippet({
    this.token,
    this.viewerId,
    this.deviceId,
    this.error,
  });

  final String? token;
  final int? viewerId;
  final String? deviceId;
  final String? error;

  bool get ok => token != null && error == null;
}

class TokenFileImport {
  const TokenFileImport({
    required this.sourceName,
    required this.snippet,
  });

  final String sourceName;
  final ParsedAuthSnippet snippet;
}

class TokenFileParser {
  /// Extract token / viewerId / deviceId from a full JS paste or file body.
  static ParsedAuthSnippet parse(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      return const ParsedAuthSnippet(error: 'Файл пустой');
    }

    String? token;
    int? viewerId;
    String? deviceId;

    deviceId = _extractSetItemValue(text, '__oneme_device_id');

    final authRaw = _extractSetItemValue(text, '__oneme_auth');
    if (authRaw != null) {
      final authJson = _tryDecodeJsonObject(_unescapeJsString(authRaw));
      if (authJson != null) {
        token = _tokenFromAuthMap(authJson);
        viewerId = _viewerIdFromAuthMap(authJson) ?? viewerId;
      }
    }

    // Whole-file JSON or leading `{...}`
    if (token == null || viewerId == null) {
      final jsonBlob = _extractJsonObject(text);
      if (jsonBlob != null) {
        token ??= _tokenFromAuthMap(jsonBlob);
        viewerId ??= _viewerIdFromAuthMap(jsonBlob);
      }
    }

    token ??= MaxAuthService.normalizeTokenInput(text);
    viewerId ??= _extractViewerIdLoose(text);

    final formatError = MaxAuthService.validateTokenFormat(token);
    if (formatError != null) {
      return ParsedAuthSnippet(
        token: token.isEmpty ? null : token,
        viewerId: viewerId,
        deviceId: deviceId,
        error: formatError,
      );
    }

    return ParsedAuthSnippet(
      token: MaxAuthService.normalizeTokenInput(token),
      viewerId: viewerId,
      deviceId: deviceId,
    );
  }

  static List<TokenFileImport> parseFiles(Map<String, String> nameToContent) {
    final out = <TokenFileImport>[];
    for (final entry in nameToContent.entries) {
      out.add(TokenFileImport(
        sourceName: entry.key,
        snippet: parse(entry.value),
      ));
    }
    return out;
  }

  static String? _extractSetItemValue(String text, String key) {
    // localStorage.setItem('key', 'value') / setItem("key", "value")
    final pattern = RegExp(
      "localStorage\\.setItem\\s*\\(\\s*(['\"])${RegExp.escape(key)}\\1\\s*,\\s*(['\"])([\\s\\S]*?)\\2\\s*\\)",
      caseSensitive: false,
    );
    final match = pattern.firstMatch(text);
    return match?.group(3);
  }

  static String _unescapeJsString(String value) {
    return value
        .replaceAll(r'\"', '"')
        .replaceAll(r"\'", "'")
        .replaceAll(r'\\', '\\');
  }

  static Map<String, dynamic>? _tryDecodeJsonObject(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  static Map<String, dynamic>? _extractJsonObject(String text) {
    final trimmed = text.trim();
    if (trimmed.startsWith('{')) {
      return _tryDecodeJsonObject(trimmed);
    }
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      return _tryDecodeJsonObject(text.substring(start, end + 1));
    }
    return null;
  }

  static String? _tokenFromAuthMap(Map<String, dynamic> map) {
    final attrs = map['tokenAttrs'];
    final fromAttrs = attrs is Map ? attrs['token']?.toString() : null;
    if (fromAttrs != null && fromAttrs.trim().isNotEmpty) {
      return MaxAuthService.normalizeTokenInput(fromAttrs);
    }
    final direct = map['token']?.toString();
    if (direct != null && direct.trim().isNotEmpty) {
      return MaxAuthService.normalizeTokenInput(direct);
    }
    return null;
  }

  static int? _viewerIdFromAuthMap(Map<String, dynamic> map) {
    final raw = map['viewerId'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw != null) return int.tryParse(raw.toString());
    return null;
  }

  static int? _extractViewerIdLoose(String text) {
    final match = RegExp(r'"viewerId"\s*:\s*(\d+)').firstMatch(text);
    if (match != null) return int.tryParse(match.group(1)!);
    return null;
  }
}
