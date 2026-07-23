import 'dart:io';

/// Locates bundled Node.js / CLI next to the Windows exe (or project root in dev).
class NodeRuntime {
  NodeRuntime._();

  static String get _exeDir => File(Platform.resolvedExecutable).parent.path;

  static String get _cwd => Directory.current.path;

  static String _cliUnder(String root) =>
      '$root${Platform.pathSeparator}tools${Platform.pathSeparator}max_auth${Platform.pathSeparator}cli.mjs';

  static List<String> get _nodeCandidates => [
        '$_exeDir${Platform.pathSeparator}tools${Platform.pathSeparator}node${Platform.pathSeparator}node.exe',
        '$_cwd${Platform.pathSeparator}tools${Platform.pathSeparator}node${Platform.pathSeparator}node.exe',
      ];

  /// Walks up from [start] looking for `tools/max_auth/cli.mjs` (Flutter debug cwd is runner/Debug).
  static String? _findCliWalkingUp(String start) {
    var dir = Directory(start);
    for (var i = 0; i < 10; i++) {
      final candidate = File(_cliUnder(dir.path));
      if (candidate.existsSync()) return candidate.path;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  static Future<String?> findCliPath() async {
    for (final root in [_cwd, _exeDir]) {
      final direct = File(_cliUnder(root));
      if (direct.existsSync()) return direct.path;
    }
    return _findCliWalkingUp(_cwd) ?? _findCliWalkingUp(_exeDir);
  }

  /// Absolute path to `node` / `node.exe`, or `null` if none works.
  static Future<String?> findNodeExecutable() async {
    for (final candidate in _nodeCandidates) {
      if (File(candidate).existsSync() && await _works(candidate)) {
        return candidate;
      }
    }
    // Absolute install paths help when PATH is stripped under Flutter/Windows.
    for (final candidate in const [
      r'C:\Program Files\nodejs\node.exe',
      r'C:\Program Files (x86)\nodejs\node.exe',
    ]) {
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
