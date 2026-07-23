import 'dart:convert';
import 'dart:io';

/// Multi-file picker for Windows via PowerShell OpenFileDialog.
///
/// Paths are written to a UTF-8 temp file so Cyrillic folder names survive
/// the PowerShell → Dart pipe (OEM code page otherwise turns them into `?`).
class DesktopFilePicker {
  /// Returns absolute paths of selected files, or empty if cancelled.
  static Future<List<String>> pickTextFiles({
    String title = 'Выберите файлы с токенами',
    List<String> extensions = const ['txt', 'log', 'js', 'json'],
  }) {
    return pickFiles(
      title: title,
      filterLabel: 'Токены',
      extensions: extensions,
      multiselect: true,
    );
  }

  /// Single image file for channel avatar / cover.
  static Future<String?> pickImage({
    String title = 'Выберите фото канала',
  }) async {
    final files = await pickFiles(
      title: title,
      filterLabel: 'Изображения',
      extensions: const ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'],
      multiselect: false,
    );
    return files.isEmpty ? null : files.first;
  }

  static Future<List<String>> pickFiles({
    required String title,
    required String filterLabel,
    required List<String> extensions,
    bool multiselect = true,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Выбор файлов поддерживается только на Windows');
    }

    final filterParts = extensions.map((e) => '*.$e').join(';');
    final filter = '$filterLabel ($filterParts)|$filterParts|Все файлы (*.*)|*.*';
    final listFile = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'max-desktop-pick-${DateTime.now().microsecondsSinceEpoch}.txt',
    );

    final script = '''
Add-Type -AssemblyName System.Windows.Forms
\$dialog = New-Object System.Windows.Forms.OpenFileDialog
\$dialog.Title = ${jsonEncode(title)}
\$dialog.Filter = ${jsonEncode(filter)}
\$dialog.Multiselect = ${multiselect ? '\$true' : '\$false'}
\$dialog.CheckFileExists = \$true
if (\$dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
  exit 0
}
\$utf8 = New-Object System.Text.UTF8Encoding \$false
[System.IO.File]::WriteAllLines(${jsonEncode(listFile.path)}, \$dialog.FileNames, \$utf8)
''';

    try {
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

      if (!await listFile.exists()) return const [];

      final lines = await listFile.readAsLines(encoding: utf8);
      return lines.map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    } finally {
      try {
        if (await listFile.exists()) await listFile.delete();
      } catch (_) {}
    }
  }
}
