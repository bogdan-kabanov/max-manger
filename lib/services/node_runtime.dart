import 'dart:io';

/// Locates bundled Node.js / CLI next to the Windows exe (or project root in dev).
class NodeRuntime {
  NodeRuntime._();

  static String get _exeDir => File(Platform.resolvedExecutable).parent.path;

  static String get _cwd => Directory.current.path;

  static List<String> get _cliCandidates => [
        '$_cwd${Platform.pathSeparator}tools${Platform.pathSeparator}max_auth${Platform.pathSeparator}cli.mjs',
        '$_exeDir${Platform.pathSeparator}tools${Platform.pathSeparator}max_auth${Platform.pathSeparator}cli.mjs',
      ];

  static List<String> get _nodeCandidates => [
        '$_exeDir${Platform.pathSeparator}tools${Platform.pathSeparator}node${Platform.pathSeparator}node.exe',
        '$_cwd${Platform.pathSeparator}tools${Platform.pathSeparator}node${Platform.pathSeparator}node.exe',
      ];

  static Future<String?> findCliPath() async {
    for (final candidate in _cliCandidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  /// Absolute path to `node` / `node.exe`, or `null` if none works.
  static Future<String?> findNodeExecutable() async {
    for (final candidate in _nodeCandidates) {
      if (File(candidate).existsSync() && await _works(candidate)) {
        return candidate;
      }
    }
    if (await _works('node')) return 'node';
    return null;
  }

  static Future<bool> isAvailable() async {
    if (await findNodeExecutable() == null) return false;
    final cli = await findCliPath();
    if (cli == null) return false;
    final modules = Directory(
      '${File(cli).parent.path}${Platform.pathSeparator}node_modules',
    );
    return modules.existsSync();
  }

  static Future<bool> _works(String executable) async {
    try {
      final result = await Process.run(executable, ['--version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
