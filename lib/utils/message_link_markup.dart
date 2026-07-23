/// Разметка ссылок в тексте сообщений MAX: `[подпись](https://…)`.
///
/// В чат уходит только подпись; URL передаётся в `elements` как `LINK`.
class ParsedMessageText {
  const ParsedMessageText({
    required this.text,
    required this.elements,
  });

  final String text;
  final List<Map<String, dynamic>> elements;
}

final _linkMarkup = RegExp(
  r'\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)',
);

ParsedMessageText parseMessageWithLinks(String raw) {
  if (raw.isEmpty || !raw.contains('](')) {
    return ParsedMessageText(text: raw, elements: const []);
  }

  final buffer = StringBuffer();
  final elements = <Map<String, dynamic>>[];
  var last = 0;

  for (final match in _linkMarkup.allMatches(raw)) {
    buffer.write(raw.substring(last, match.start));
    final label = match.group(1)!;
    final url = match.group(2)!;
    final from = buffer.length;
    buffer.write(label);
    elements.add({
      'type': 'LINK',
      'from': from,
      'length': label.length,
      'attributes': {'url': url},
    });
    last = match.end;
  }
  buffer.write(raw.substring(last));

  return ParsedMessageText(text: buffer.toString(), elements: elements);
}
