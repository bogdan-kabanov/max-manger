import 'package:flutter_test/flutter_test.dart';
import 'package:max_desktop/utils/message_link_markup.dart';

void main() {
  test('plain text stays unchanged', () {
    final parsed = parseMessageWithLinks('просто текст');
    expect(parsed.text, 'просто текст');
    expect(parsed.elements, isEmpty);
  });

  test('single labeled link', () {
    final parsed = parseMessageWithLinks(
      'Жми [Вступить](https://max.ru/join/abc)',
    );
    expect(parsed.text, 'Жми Вступить');
    expect(parsed.elements, hasLength(1));
    expect(parsed.elements.single['type'], 'LINK');
    expect(parsed.elements.single['from'], 4);
    expect(parsed.elements.single['length'], 'Вступить'.length);
    expect(parsed.elements.single['attributes'], {
      'url': 'https://max.ru/join/abc',
    });
  });

  test('multiple links keep offsets', () {
    final parsed = parseMessageWithLinks(
      '[A](https://a.ru) и [B](https://b.ru)',
    );
    expect(parsed.text, 'A и B');
    expect(parsed.elements, hasLength(2));
    expect(parsed.elements[0]['from'], 0);
    expect(parsed.elements[0]['length'], 1);
    expect(parsed.elements[1]['from'], 4);
    expect(parsed.elements[1]['length'], 1);
  });
}
