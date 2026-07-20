import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/max_account.dart';
import '../providers/app_state.dart';
import '../services/emulator_service.dart';
import '../services/max_apk_download_service.dart';

class EmulatorPanelDialog extends StatefulWidget {
  const EmulatorPanelDialog({super.key, required this.account});

  final MaxAccount account;

  static Future<void> show(BuildContext context, MaxAccount account) {
    return showDialog<void>(
      context: context,
      builder: (context) => EmulatorPanelDialog(account: account),
    );
  }

  @override
  State<EmulatorPanelDialog> createState() => _EmulatorPanelDialogState();
}

class _EmulatorPanelDialogState extends State<EmulatorPanelDialog> {
  final _apkController = TextEditingController();
  final _service = EmulatorService.instance;
  final _apkDownloader = MaxApkDownloadService();

  EmulatorSdkInfo? _sdk;
  bool _loading = false;
  bool _loadingSdk = true;
  String? _operation;
  String? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSdk();
    _initApkPath();
  }

  Future<void> _initApkPath() async {
    if (await _apkDownloader.hasCachedApk()) {
      final path = await _apkDownloader.defaultApkPath();
      if (mounted) _apkController.text = path;
    }
  }

  Future<String?> _resolveApkPath({void Function(String)? onProgress}) async {
    final manual = _apkController.text.trim();
    if (manual.isNotEmpty && File(manual).existsSync()) return manual;

    if (await _apkDownloader.hasCachedApk()) {
      final path = await _apkDownloader.defaultApkPath();
      if (mounted) _apkController.text = path;
      return path;
    }

    final result = await _apkDownloader.download(onProgress: onProgress);
    if (result.ok && result.path != null) {
      if (mounted) _apkController.text = result.path!;
      return result.path;
    }
    return null;
  }

  Future<void> _loadSdk() async {
    setState(() {
      _loadingSdk = true;
      _error = null;
    });
    try {
      final sdk = await EmulatorService.instance
          .detectSdk(forceRefresh: true)
          .timeout(
            const Duration(seconds: 60),
            onTimeout: () => EmulatorSdkInfo(
              available: false,
              error: 'Таймаут при проверке Android SDK (60 с). Закройте Android Studio и попробуйте снова.',
            ),
          );
      if (!mounted) return;
      setState(() => _sdk = sdk);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sdk = EmulatorSdkInfo(available: false, error: e.toString());
      });
    } finally {
      if (mounted) setState(() => _loadingSdk = false);
    }
  }

  @override
  void dispose() {
    _apkController.dispose();
    super.dispose();
  }

  MaxAccount get _account {
    final state = context.read<AppState>();
    return state.accounts.firstWhere(
      (a) => a.id == widget.account.id,
      orElse: () => widget.account,
    );
  }

  Future<void> _run(
    Future<EmulatorOperationResult> Function() action, {
    required String operationLabel,
    bool saveAvd = false,
    Future<void> Function(EmulatorOperationResult result)? onSuccess,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    setState(() {
      _loading = true;
      _operation = operationLabel;
      _error = null;
      _status = null;
    });

    EmulatorOperationResult result;
    try {
      result = await action().timeout(
        timeout,
        onTimeout: () => EmulatorOperationResult(
          ok: false,
          message: 'Таймаут: $operationLabel (${timeout.inMinutes} мин). '
              'Закройте зависшие процессы emulator/avdmanager в диспетчере задач.',
        ),
      );
      if (onSuccess != null && result.ok) {
        await onSuccess(result);
      } else if (saveAvd && result.ok && result.avdName != null && mounted) {
        await context.read<AppState>().updateAccountEmulator(
              _account,
              _account.emulator.copyWith(
                avdName: result.avdName,
                createdAt: _account.emulator.createdAt ?? DateTime.now(),
              ),
            );
      }
    } catch (e) {
      result = EmulatorOperationResult(ok: false, message: '$operationLabel: $e');
    }

    if (!mounted) return;
    setState(() {
      _loading = false;
      _operation = null;
      if (result.ok) {
        _status = result.message;
      } else {
        _error = result.message;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final account = _account;
    final avdName = account.emulator.avdName ?? _service.defaultAvdName(account);

    return AlertDialog(
      title: Text('Эмулятор: ${account.label}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Каждый профиль MAX Desktop может иметь свой Android-эмулятор (AVD) '
                'с отдельными данными. Регистрируйте номер в MAX внутри эмулятора, '
                'затем войдите через QR в web.max.ru.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              _InfoRow(label: 'AVD', value: avdName),
              if (_sdk != null) ...[
                _InfoRow(
                  label: 'Android SDK',
                  value: _sdk!.available ? (_sdk!.sdkRoot ?? 'OK') : 'Не найден',
                ),
                if (_sdk!.systemImage != null)
                  _InfoRow(label: 'Образ', value: _sdk!.systemImage!.split(';').take(3).join(';')),
              ],
              if (_sdk?.available == false) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _sdk?.error ??
                        'Установите Android Studio → SDK Manager → '
                        'system-image x86_64 (Android 33+). Включите Virtualization в BIOS.',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _loading || _loadingSdk
                    ? null
                    : () => _run(
                          () async {
                            final result = await _apkDownloader.download(
                              onProgress: (msg) {
                                if (mounted) setState(() => _operation = msg);
                              },
                            );
                            if (result.ok && result.path != null) {
                              _apkController.text = result.path!;
                            }
                            return EmulatorOperationResult(
                              ok: result.ok,
                              message: result.message,
                            );
                          },
                          operationLabel: 'Скачивание MAX с RuStore…',
                          timeout: const Duration(minutes: 15),
                        ),
                icon: const Icon(Icons.download_outlined),
                label: const Text('Скачать APK MAX'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _apkController,
                decoration: const InputDecoration(
                  labelText: 'Путь к MAX APK',
                  hintText: 'Скачается автоматически с RuStore',
                ),
              ),
              if (_status != null) ...[
                const SizedBox(height: 10),
                Text(_status!, style: const TextStyle(fontSize: 12, color: Colors.greenAccent)),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error)),
              ],
              if (_loadingSdk) ...[
                const SizedBox(height: 12),
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 8),
                const Text('Проверка Android SDK…', textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
              ],
              if (_loading && _operation != null) ...[
                const SizedBox(height: 12),
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 8),
                Text(_operation!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
        if (_loading)
          TextButton(
            onPressed: () => setState(() {
              _loading = false;
              _operation = null;
              _error = 'Операция отменена в интерфейсе. Если процесс завис — закройте emulator.exe в диспетчере задач.';
            }),
            child: const Text('Отмена'),
          ),
        OutlinedButton(
          onPressed: _loading || _loadingSdk || _sdk?.available != true
              ? null
              : () => _run(
                    () => _service.createAvd(account),
                    operationLabel: 'Создание AVD…',
                    saveAvd: true,
                    timeout: const Duration(minutes: 4),
                  ),
          child: const Text('Создать AVD'),
        ),
        FilledButton.tonal(
          onPressed: _loading || _loadingSdk || _sdk?.available != true
              ? null
              : () {
                  final appState = context.read<AppState>();
                  final avd = avdName;
                  _run(
                    () => _service.launch(account),
                    operationLabel: 'Запуск эмулятора…',
                    onSuccess: (r) async {
                      await appState.updateAccountEmulator(
                        account,
                        account.emulator.copyWith(
                          avdName: r.avdName ?? avd,
                          lastLaunchedAt: DateTime.now(),
                        ),
                      );
                    },
                  );
                },
          child: const Text('Запустить'),
        ),
        FilledButton(
          onPressed: _loading || _loadingSdk || _sdk?.available != true
              ? null
              : () => _run(
                    () async {
                      final apk = await _resolveApkPath(
                        onProgress: (msg) {
                          if (mounted) setState(() => _operation = msg);
                        },
                      );
                      if (apk == null) {
                        return EmulatorOperationResult(
                          ok: false,
                          message: 'Не удалось скачать APK MAX. Нажмите «Скачать APK MAX».',
                        );
                      }
                      final install = await _service.installApk(account, apk);
                      if (!install.ok) return install;
                      return _service.openMaxApp(
                        account,
                        onProgress: (msg) {
                          if (mounted) setState(() => _operation = msg);
                        },
                      );
                    },
                    operationLabel: 'Запуск эмулятора и открытие MAX…',
                    timeout: const Duration(minutes: 10),
                  ),
          child: const Text('Открыть MAX'),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 90, child: Text(label, style: const TextStyle(fontSize: 11, color: Colors.white60))),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 11))),
        ],
      ),
    );
  }
}
