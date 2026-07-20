import 'package:flutter_test/flutter_test.dart';
import 'package:max_desktop/services/token_file_parser.dart';

void main() {
  test('parses localStorage.setItem console snippet', () {
    const raw = "sessionStorage.clear();localStorage.clear();"
        "localStorage.setItem('__oneme_device_id', 'acdd653b-005a-4442-99f7-7c2f0ab6cf36');"
        "localStorage.setItem('__oneme_auth', '{\"token\": \"An_Sx6HQ9HDigozp_BElWHJ7lTDEdlLgbnCnP7ogavFKPp8j__mlATfE8-6GSclSfHiQy4X9inONyufpY-1qZORy7CmNmTQjwlqtbVnnfFZTnTCWxuO1hTIMvFWee8qcy0ip1tcIM8HUrDdFrdd05Tq-YA0vAO6KUbbcimm7OuP8PUrjIVm7Y-ZIzk-yuyO0U-3YcIL-owEMRkSLfNkIrBIRTxLPpHTQ2nPnAUrZQKIkUHiXPgVh95kS3-7uEbzeaYnQmbtg3eMGosZIYMHyAQxb0yYyGumaoNRGIv0an_8IY5SVn_Vyq8b9uNjdiQAZ1KkrcrsaLWx6FU4hoy746W2oMiHi5RFCgrpOvGpjfdT3k-YgskWyRxkcHZKgK3_iZViXxQFs1k7hn-W0grPfIOYq3qnqYvwm6XiFwmfj6qcnlTr0dhVDD6T0FULapXwWQYCcmEmU21fAHZB3vYF33535vBWz9O0oK5sPMzpN_IlUGWaRAy9Uoy8394KoDoVdto98mdIn69_h1dU1_SicBn3Yt4GI4Y5EyksCY51E3Ey5MHQwxzAfzYXuFYgbmNdhIHFCdzPnRIXRwE_FudzdgNSlaLfKum9ALLM86cJFzqJ71X9UMTaR3pWj5JJVRQLiVNj6y5xJ8CXOY2PDBQaNo0DwNyIIn4_M1hg5C256FmuOmvBUskwNsYSUmrnOKzBlA69Tsk0\", \"viewerId\": 272219664}');"
        'window.location.reload();';

    final parsed = TokenFileParser.parse(raw);
    expect(parsed.ok, isTrue);
    expect(parsed.token, startsWith('An_'));
    expect(parsed.token!.length, greaterThan(200));
    expect(parsed.viewerId, 272219664);
    expect(parsed.deviceId, 'acdd653b-005a-4442-99f7-7c2f0ab6cf36');
  });

  test('parses plain token', () {
    final token = 'An_${'A' * 300}';
    final parsed = TokenFileParser.parse(token);
    expect(parsed.ok, isTrue);
    expect(parsed.token, token);
  });
}
