import 'dart:convert';
import 'dart:io';

/// Multi-file picker for Windows via PowerShell OpenFileDialog.
class DesktopFilePicker {
  /// Returns absolute paths of selected files, or empty if cancelled.
  static Future<List<String>> pickTextFiles({
    String title = 'Выберите файлы с токенами',
    List<String> extensions = const ['txt', 'log', 'js', 'json'],
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Выбор файлов поддерживается только на Windows');
    }

    final filterParts = extensions.map((e) => '*.$e').join(';');
    final filter = 'Токены ($filterParts)|$filterParts|Все файлы (*.*)|*.*';

    final script = '''
Add-Type -AssemblyName System.Windows.Forms
\$dialog = New-Object System.Windows.Forms.OpenFileDialog
\$dialog.Title = ${jsonEncode(title)}
\$dialog.Filter = ${jsonEncode(filter)}
\$dialog.Multiselect = \$true
\$dialog.CheckFileExists = \$true
if (\$dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  \$dialog.FileNames | ForEach-Object { \$_ }
}
''';

    final result = await Process.run(
      'powershell',
      ['-NoProfile', '-STA', '-Command', script],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

    if (result.exitCode != 0) {
      final err = (result.stderr as String?)?.trim();
      if (err != null && err.isNotEmpty) {
        throw StateError(err);
      }
      return const [];
    }

    final stdout = (result.stdout as String?)?.trim() ?? '';
    if (stdout.isEmpty) return const [];
    return stdout
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }
}
