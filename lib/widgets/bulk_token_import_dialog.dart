import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/max_account.dart';
import '../providers/app_state.dart';
import '../services/desktop_file_picker.dart';
import '../services/max_auth_service.dart';
import '../services/token_file_parser.dart';

class BulkTokenImportDialog extends StatefulWidget {
  const BulkTokenImportDialog({super.key});

  static Future<bool?> show(BuildContext context) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const BulkTokenImportDialog(),
    );
  }

  @override
  State<BulkTokenImportDialog> createState() => _BulkTokenImportDialogState();
}

class _BulkTokenImportDialogState extends State<BulkTokenImportDialog> {
  final _proxyController = TextEditingController();
  final List<_ImportRow> _rows = [];
  bool _loading = false;
  bool _verify = false;
  String? _error;
  String? _status;

  @override
  void dispose() {
    _proxyController.dispose();
    super.dispose();
  }

  String? get _proxy {
    final value = _proxyController.text.trim();
    return value.isEmpty ? null : value;
  }

  Future<void> _pickFiles() async {
    setState(() {
      _error = null;
      _status = null;
    });

    List<String> paths;
    try {
      paths = await DesktopFilePicker.pickTextFiles();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Не удалось открыть диалог выбора: $e');
      return;
    }
    if (paths.isEmpty) return;

    final parsed = <_ImportRow>[];
    for (final path in paths) {
      final name = path.split(RegExp(r'[\\/]')).last;
      try {
        final content = await File(path).readAsString();
        parsed.add(_ImportRow(
          sourceName: name,
          snippet: TokenFileParser.parse(content),
        ));
      } catch (e) {
        parsed.add(_ImportRow(
          sourceName: name,
          snippet: ParsedAuthSnippet(error: _readErrorMessage(path, e)),
        ));
      }
    }

    setState(() {
      _rows
        ..clear()
        ..addAll(parsed);
    });
  }

  String _readErrorMessage(String path, Object error) {
    final text = error.toString();
    if (text.contains('errno = 123') || text.contains('?????')) {
      return 'Не удалось прочитать файл (битый путь). Переложите .txt в папку без кириллицы, например Desktop\\tokens\\, и выберите снова.';
    }
    if (text.contains('PathNotFoundException') || text.contains('Cannot open file')) {
      return 'Файл не найден: $path';
    }
    return 'Ошибка чтения: $error';
  }

  String _labelFor(_ImportRow row, int index) {
    final base = row.sourceName.replaceAll(RegExp(r'\.[^.]+$'), '').trim();
    if (base.isNotEmpty) return base;
    final viewerId = row.snippet.viewerId;
    if (viewerId != null) return 'id $viewerId';
    return 'Аккаунт ${index + 1}';
  }

  Future<void> _import() async {
    final okRows = _rows.where((r) => r.snippet.ok && r.selected).toList();
    if (okRows.isEmpty) {
      setState(() => _error = 'Нет валидных токенов для импорта');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _status = 'Импорт ${okRows.length} аккаунтов…';
    });

    final state = context.read<AppState>();
    final existing = state.accounts
        .map((a) => a.apiToken?.trim())
        .whereType<String>()
        .where((t) => t.isNotEmpty)
        .toSet();

    final toCreate = <
        ({
          String apiToken,
          String? label,
          int? viewerId,
          String? deviceId,
          AccountHealthStatus healthStatus,
        })>[];
    var skippedDup = 0;
    var failedVerify = 0;

    for (var i = 0; i < okRows.length; i++) {
      final row = okRows[i];
      final token = row.snippet.token!;
      if (existing.contains(token) || toCreate.any((e) => e.apiToken == token)) {
        skippedDup++;
        continue;
      }

      if (_verify) {
        setState(() => _status = 'Проверка ${i + 1}/${okRows.length}: ${row.sourceName}');
        final result = await MaxAuthService.verifyToken(token, proxy: _proxy);
        if (result.ok) {
          toCreate.add((
            apiToken: token,
            label: result.profileName ?? _labelFor(row, i),
            viewerId: row.snippet.viewerId ?? result.profileId,
            deviceId: row.snippet.deviceId,
            healthStatus: AccountHealthStatus.ok,
          ));
        } else if (MaxAuthService.isNetworkError(result.error)) {
          toCreate.add((
            apiToken: token,
            label: _labelFor(row, i),
            viewerId: row.snippet.viewerId,
            deviceId: row.snippet.deviceId,
            healthStatus: AccountHealthStatus.networkError,
          ));
        } else if (result.healthStatus == AccountHealthStatus.banned) {
          toCreate.add((
            apiToken: token,
            label: result.profileName ?? _labelFor(row, i),
            viewerId: row.snippet.viewerId ?? result.profileId,
            deviceId: row.snippet.deviceId,
            healthStatus: AccountHealthStatus.banned,
          ));
        } else {
          failedVerify++;
        }
      } else {
        toCreate.add((
          apiToken: token,
          label: _labelFor(row, i),
          viewerId: row.snippet.viewerId,
          deviceId: row.snippet.deviceId,
          healthStatus: AccountHealthStatus.unknown,
        ));
      }
    }

    if (!mounted) return;

    if (toCreate.isEmpty) {
      setState(() {
        _loading = false;
        _status = null;
        _error = skippedDup > 0
            ? 'Все токены уже есть в списке (дубликаты: $skippedDup)'
            : failedVerify > 0
                ? 'Ни один токен не прошёл проверку ($failedVerify)'
                : 'Нечего импортировать';
      });
      return;
    }

    setState(() => _status = 'Создание ${toCreate.length} аккаунтов…');
    final created = await state.addAccountsFromTokenImports(
      items: toCreate,
      proxyServer: _proxy,
    );

    if (!mounted) return;
    setState(() => _loading = false);

    final parts = <String>['Добавлено: ${created.length}'];
    if (skippedDup > 0) parts.add('дубликаты: $skippedDup');
    if (failedVerify > 0) parts.add('отклонено: $failedVerify');

    Navigator.pop(context, true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(parts.join(' · '))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final okCount = _rows.where((r) => r.snippet.ok && r.selected).length;
    final failCount = _rows.where((r) => !r.snippet.ok).length;

    return AlertDialog(
      title: const Text('Импорт токенов из файлов'),
      content: SizedBox(
        width: 560,
        height: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Выберите несколько .txt файлов. Внутри — скрипт вида '
              'localStorage.setItem(\'__oneme_auth\', \'{"token":"An_…","viewerId":…}\'). '
              'Парсер заберёт токен и viewerId и создаст аккаунты.',
              style: TextStyle(fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: _loading ? null : _pickFiles,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Выбрать файлы'),
                ),
                const SizedBox(width: 12),
                if (_rows.isNotEmpty)
                  Text(
                    '${_rows.length} файл(ов) · ок: $okCount · ошибок: $failCount',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _proxyController,
              enabled: !_loading,
              decoration: const InputDecoration(
                labelText: 'Прокси для всех (необязательно)',
                hintText: 'socks5://user:pass@host:port',
              ),
            ),
            const SizedBox(height: 4),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _verify,
              onChanged: _loading
                  ? null
                  : (v) => setState(() => _verify = v ?? false),
              title: const Text('Проверять токены через API', style: TextStyle(fontSize: 13)),
              subtitle: const Text(
                'Медленнее. Без галочки — сразу создать аккаунты.',
                style: TextStyle(fontSize: 11),
              ),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            const SizedBox(height: 6),
            Expanded(
              child: _rows.isEmpty
                  ? Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Theme.of(context).dividerColor),
                      ),
                      child: const Text(
                        'Файлы ещё не выбраны',
                        style: TextStyle(color: Colors.white54),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _rows.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final row = _rows[index];
                        final ok = row.snippet.ok;
                        return CheckboxListTile(
                          value: ok && row.selected,
                          onChanged: !ok || _loading
                              ? null
                              : (v) => setState(() => row.selected = v ?? false),
                          dense: true,
                          secondary: Icon(
                            ok ? Icons.check_circle_outline : Icons.error_outline,
                            color: ok
                                ? Colors.greenAccent.shade200
                                : Theme.of(context).colorScheme.error,
                            size: 20,
                          ),
                          title: Text(row.sourceName, style: const TextStyle(fontSize: 13)),
                          subtitle: Text(
                            ok
                                ? '${MaxAuthService.tokenPreview(row.snippet.token!)}'
                                    '${row.snippet.viewerId != null ? ' · id ${row.snippet.viewerId}' : ''}'
                                : (row.snippet.error ?? 'Ошибка'),
                            style: TextStyle(
                              fontSize: 11,
                              fontFamily: ok ? 'Consolas' : null,
                              color: ok ? Colors.white70 : Theme.of(context).colorScheme.error,
                            ),
                          ),
                        );
                      },
                    ),
            ),
            if (_status != null) ...[
              const SizedBox(height: 8),
              Text(_status!, style: Theme.of(context).textTheme.bodySmall),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
              ),
            ],
            if (_loading) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _loading || okCount == 0 ? null : _import,
          child: Text(okCount > 0 ? 'Создать ($okCount)' : 'Создать'),
        ),
      ],
    );
  }
}

class _ImportRow {
  _ImportRow({
    required this.sourceName,
    required this.snippet,
  }) : selected = snippet.ok;

  final String sourceName;
  final ParsedAuthSnippet snippet;
  bool selected;
}
