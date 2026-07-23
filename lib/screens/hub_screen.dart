import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../services/app_update_service.dart';
import '../widgets/app_nav_shell.dart';
import '../widgets/hub_center_panel.dart';

/// Главное рабочее пространство: web + встроенный эмулятор + автоматизация.
class HubScreen extends StatefulWidget {
  const HubScreen({super.key});

  @override
  State<HubScreen> createState() => _HubScreenState();
}

class _HubScreenState extends State<HubScreen> {
  bool _checkingUpdate = false;
  AppUpdateInfo? _availableUpdate;
  String? _updateStatus;
  String _localVersionLabel = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadLocalVersion();
      await _checkUpdates(silent: true);
    });
  }

  Future<void> _loadLocalVersion() async {
    try {
      final current = await AppUpdateService.currentVersion();
      if (!mounted) return;
      setState(() => _localVersionLabel = '${current.version}+${current.build}');
    } catch (_) {}
  }

  Future<void> _checkUpdates({bool silent = false}) async {
    if (_checkingUpdate) return;
    setState(() {
      _checkingUpdate = true;
      if (!silent) _updateStatus = 'Проверка обновлений…';
    });
    try {
      final update = await AppUpdateService.checkForUpdate();
      if (!mounted) return;
      setState(() {
        _availableUpdate = update;
        _updateStatus = update == null
            ? (silent ? null : 'У вас актуальная версия')
            : 'Доступна ${update.version}+${update.build}';
      });
      if (update != null) {
        // Always offer install — silent launch and manual «Проверить обновления».
        await _promptUpdate(update);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _availableUpdate = null;
        if (!silent) _updateStatus = 'Не удалось проверить: $e';
      });
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  Future<void> _promptUpdate(AppUpdateInfo update) async {
    final current = await AppUpdateService.currentVersion();
    if (!mounted) return;

    final go = await showDialog<bool>(
      context: context,
      barrierDismissible: !update.mandatory,
      builder: (context) => AlertDialog(
        title: const Text('Доступно обновление'),
        content: Text(
          'Установлено: ${current.version} (build ${current.build})\n'
          'Новая версия: ${update.version} (build ${update.build})\n\n'
          '${update.notes?.trim().isNotEmpty == true ? update.notes! : 'Установить сейчас?'}',
        ),
        actions: [
          if (!update.mandatory)
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Позже'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Обновить'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await _installUpdate(update);
  }

  Future<void> _installUpdate(AppUpdateInfo update) async {
    final progress = ValueNotifier<double>(0);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Загрузка обновления'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (context, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: value <= 0 ? null : value),
              const SizedBox(height: 12),
              Text(value <= 0 ? 'Скачивание…' : '${(value * 100).round()}%'),
            ],
          ),
        ),
      ),
    );

    try {
      await AppUpdateService.downloadAndInstall(
        update,
        onProgress: (p) => progress.value = p,
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось обновить: $e')),
      );
    } finally {
      progress.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final update = _availableUpdate;
    final showMap = context.watch<AppState>().navPage.showsAccountMap;
    return Scaffold(
      body: Column(
        children: [
          if (update != null)
            Material(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.system_update, color: Theme.of(context).colorScheme.onPrimaryContainer),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Доступно обновление ${update.version} — ${_localVersionLabel.isEmpty ? '…' : _localVersionLabel} → ${update.version}+${update.build}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onPrimaryContainer,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _checkingUpdate ? null : () => _installUpdate(update),
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('Обновить'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _checkingUpdate ? null : () => setState(() => _availableUpdate = null),
                      child: const Text('Скрыть'),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: Row(
              children: [
                // Same slot in the tree when map toggles — avoids tearing down
                // Provider dependents (red screen: `_dependents.isEmpty`).
                Flexible(
                  flex: showMap ? 0 : 1,
                  fit: showMap ? FlexFit.loose : FlexFit.tight,
                  child: AppNavShell(
                    expandContent: !showMap,
                    onCheckUpdates: () => _checkUpdates(silent: false),
                    onInstallUpdate: update == null ? null : () => _promptUpdate(update),
                    checkingUpdates: _checkingUpdate,
                    updateAvailable: update != null,
                    localVersionLabel: _localVersionLabel,
                    updateStatus: _updateStatus,
                  ),
                ),
                // Map only on home («Профили»); all work tools are left-rail pages.
                if (showMap) const Expanded(child: HubCenterPanel()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
