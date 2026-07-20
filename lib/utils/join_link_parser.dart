/// Parses MAX group invite links from pasted text.
class JoinLinkParser {
  static final _linkRe = RegExp(
    r'https?://max\.ru/join/([A-Za-z0-9_-]+)',
    caseSensitive: false,
  );

  static final _hashRe = RegExp(r'^[A-Za-z0-9_-]+$');

  /// Unique join hashes in order of first appearance.
  static List<String> parseHashes(String text) {
    final seen = <String>{};
    final result = <String>[];

    for (final match in _linkRe.allMatches(text)) {
      final hash = match.group(1)!;
      if (seen.add(hash)) result.add(hash);
    }

    for (final line in text.split(RegExp(r'[\r\n]+'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.contains('max.ru')) continue;
      if (_hashRe.hasMatch(trimmed) && trimmed.length >= 16 && seen.add(trimmed)) {
        result.add(trimmed);
      }
    }

    return result;
  }

  static List<String> toUrls(Iterable<String> hashes) =>
      hashes.map((h) => 'https://max.ru/join/$h').toList();
}
