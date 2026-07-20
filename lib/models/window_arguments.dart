import 'dart:convert';

enum WindowType { main, web, emulator, automation }

class WindowArguments {
  const WindowArguments({
    required this.type,
    this.accountId,
  });

  final WindowType type;
  final String? accountId;

  bool get isMain => type == WindowType.main;

  factory WindowArguments.main() => const WindowArguments(type: WindowType.main);

  factory WindowArguments.fromString(String raw) {
    if (raw.isEmpty) return WindowArguments.main();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final typeName = json['type'] as String? ?? 'main';
    final type = WindowType.values.firstWhere(
      (t) => t.name == typeName,
      orElse: () => WindowType.main,
    );
    return WindowArguments(
      type: type,
      accountId: json['accountId'] as String?,
    );
  }

  String encode() => jsonEncode({
        'type': type.name,
        if (accountId != null) 'accountId': accountId,
      });

  String windowTitle(String accountLabel) => switch (type) {
        WindowType.web => 'MAX Web — $accountLabel',
        WindowType.emulator => 'MAX Эмулятор — $accountLabel',
        WindowType.automation => 'MAX Автоматизация — $accountLabel',
        WindowType.main => 'MAX Desktop',
      };
}
