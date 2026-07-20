import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/macro_step.dart';
import '../models/max_account.dart';
import '../providers/app_state.dart';
import '../services/emulator_native_click_bridge.dart';
import '../services/emulator_native_window_service.dart';
import '../services/emulator_service.dart';
import '../services/max_apk_download_service.dart';
import 'emulator_screen_view.dart';

class EmulatorMirrorWidget extends StatefulWidget {
  const EmulatorMirrorWidget({super.key, required this.account});

  final MaxAccount account;

  @override
  State<EmulatorMirrorWidget> createState() => _EmulatorMirrorWidgetState();
}

class _EmulatorMirrorWidgetState extends State<EmulatorMirrorWidget> {
  final _emu = EmulatorService.instance;
  final _native = EmulatorNativeWindowService.instance;
  EmulatorNativeClickBridge? _nativeBridge;
  final _textController = TextEditingController();
  final _swipeMsController = TextEditingController(text: '300');

  Timer? _refreshTimer;
  Uint8List? _png;
  String? _error;
  String? _status;
  bool _busy = false;
  bool _capturing = false;
  bool _live = true;
  bool _controlsExpanded = false;
  int _deviceW = 1080;
  int _deviceH = 2400;
  String? _adb;
  String? _serial;
  int _swipeDurationMs = 300;
  ({int x, int y})? _pendingSwipeStart;
  ({int x, int y})? _lastTap;

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(milliseconds: 2000), (_) {
      if (_live && !_capturing && !_busy && mounted) _capture(silent: true);
    });
    _capture();
  }

  @override
  void didUpdateWidget(covariant EmulatorMirrorWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.id != widget.account.id) {
      _serial = null;
      _capture();
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _nativeBridge?.stop();
    _textController.dispose();
    _swipeMsController.dispose();
    super.dispose();
  }

  void _syncNativeBridge(AppState appState) {
    if (!appState.emulatorNativeClickMode || !appState.emulatorMirrorMode.canInteract) {
      _nativeBridge?.stop();
      _nativeBridge = null;
      return;
    }
    if (_serial == null) return;

    _nativeBridge ??= EmulatorNativeClickBridge(
      deviceWidth: _deviceW,
      deviceHeight: _deviceH,
      onPrimaryTap: (x, y) => _primaryTap(x, y),
      onPrimarySwipe: (x1, y1, x2, y2) => _primarySwipe(x1, y1, x2, y2),
      onSecondaryTap: (x, y) {
        if (!mounted) return;
        final box = context.findRenderObject() as RenderBox?;
        final pos = box?.localToGlobal(Offset(box.size.width / 2, box.size.height / 2)) ??
            const Offset(400, 400);
        _showSecondaryMenu(x, y, pos);
      },
    );
    if (!_nativeBridge!.isRunning) _nativeBridge!.start();
  }

  MaxAccount get _account {
    final state = context.read<AppState>();
    return state.accounts.firstWhere(
      (a) => a.id == widget.account.id,
      orElse: () => widget.account,
    );
  }

  Future<void> _capture({bool silent = false}) async {
    if (_capturing || _busy) return;
    setState(() => _capturing = true);
    if (!silent && mounted) setState(() => _status = 'Обновление…');

    try {
      final sdk = await _emu.detectSdk();
      if (!sdk.available || sdk.adbPath == null) {
        throw StateError('Android SDK не найден');
      }
      _adb = sdk.adbPath;
      _serial = await _emu.resolveSerial(
        _account,
        timeout: const Duration(seconds: 8),
      );
      if (!_account.emulator.isConfigured && mounted) {
        final avdName = _account.emulator.avdName ?? _emu.defaultAvdName(_account);
        await context.read<AppState>().updateAccountEmulator(
              _account,
              _account.emulator.copyWith(
                avdName: avdName,
                createdAt: _account.emulator.createdAt ?? DateTime.now(),
              ),
            );
      }
      final size = await _emu.getDisplaySize(_adb!, _serial!);
      final bytes = await _emu.captureScreenshot(_adb!, _serial!);
      if (bytes == null || bytes.isEmpty) {
        throw StateError('Не удалось получить экран');
      }
      if (!mounted) return;
      setState(() {
        _png = bytes;
        _deviceW = size.$1;
        _deviceH = size.$2;
        if (!silent) _error = null;
        _status = '$_serial · $_deviceW×$_deviceH';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Bad state: ', '');
        if (!silent) _status = null;
      });
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  void _setStatus(String msg) {
    if (mounted) setState(() => _status = msg);
  }

  Future<String?> _resolveApkPath() async {
    final downloader = MaxApkDownloadService();
    if (await downloader.hasCachedApk()) {
      return downloader.defaultApkPath();
    }
    final dl = await downloader.download(onProgress: _setStatus);
    if (!dl.ok) throw StateError(dl.message);
    return dl.path;
  }

  Future<void> _runOp(String label, Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _status = label;
      _error = null;
    });
    try {
      await action();
      if (mounted) setState(() => _error = null);
    } catch (e) {
      final msg = e.toString().replaceFirst('Bad state: ', '').replaceFirst('StateError: ', '');
      if (mounted) {
        setState(() => _error = msg);
        _snack(msg, isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _capture(silent: true);
      }
    }
  }

  Future<void> _launch() async {
    await _runOp('Запуск…', () async {
      final result = await _emu.launch(_account);
      if (!result.ok) throw StateError(result.message);
      if (mounted) {
        await context.read<AppState>().updateAccountEmulator(
              _account,
              _account.emulator.copyWith(
                avdName: result.avdName ?? _emu.defaultAvdName(_account),
                createdAt: _account.emulator.createdAt ?? DateTime.now(),
              ),
            );
      }
    });
  }

  Future<void> _openMax() async {
    await _runOp('Открытие MAX…', () async {
      final apk = await _resolveApkPath();
      if (apk == null) {
        throw StateError('Не удалось получить APK MAX');
      }

      final sdk = await _emu.detectSdk();
      if (!sdk.available || sdk.adbPath == null) {
        throw StateError(sdk.error ?? 'ADB недоступен');
      }

      final serial = _serial ??
          await _emu.resolveSerial(_account, onProgress: _setStatus, timeout: const Duration(seconds: 15));
      _serial = serial;
      _adb = sdk.adbPath;

      final installed = await _emu.isPackageInstalled(sdk.adbPath!, serial, EmulatorService.maxPackage);
      if (!installed) {
        final install = await _emu.installApk(
          _account,
          apk,
          knownSerial: serial,
          onProgress: _setStatus,
        );
        if (!install.ok) throw StateError(install.message);
      } else {
        _setStatus('MAX уже установлен, запуск…');
      }

      final result = await _emu.openMaxApp(
        _account,
        autoLaunch: false,
        knownSerial: serial,
        onProgress: _setStatus,
      );
      if (!result.ok) throw StateError(result.message);
      _setStatus('MAX открыт');
      if (mounted) _snack('MAX открыт в эмуляторе');
      _native.bringToFront();
    });
  }

  Future<void> _afterInteract() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (mounted) await _capture(silent: true);
  }

  Future<void> _primaryTap(int x, int y) async {
    final adb = _adb;
    final serial = _serial;
    if (adb == null || serial == null) return;
    if (!context.read<AppState>().emulatorMirrorMode.canInteract) return;

    setState(() => _lastTap = (x: x, y: y));
    await _emu.inputTap(adb, serial, x, y);
    await _afterInteract();
  }

  int get _swipeMs => int.tryParse(_swipeMsController.text) ?? _swipeDurationMs;

  Future<void> _primarySwipe(int x1, int y1, int x2, int y2) async {
    final adb = _adb;
    final serial = _serial;
    if (adb == null || serial == null) return;
    if (!context.read<AppState>().emulatorMirrorMode.canInteract) return;

    await _emu.inputSwipe(adb, serial, x1, y1, x2, y2, durationMs: _swipeMs);
    await _afterInteract();
  }

  Future<void> _showSecondaryMenu(int x, int y, Offset globalPos) async {
    final appState = context.read<AppState>();
    final hasScenario = appState.editingScenario?.isEmulator == true;
    final pending = _pendingSwipeStart;

    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(globalPos.dx, globalPos.dy, globalPos.dx + 1, globalPos.dy + 1),
      items: [
        if (hasScenario) ...[
          const PopupMenuItem(value: 'add_tap', child: Text('Добавить тап')),
          PopupMenuItem(
            value: 'swipe_start',
            child: Text(pending == null ? 'Начало свайпа' : 'Сбросить начало свайпа'),
          ),
          if (pending != null)
            const PopupMenuItem(value: 'swipe_end', child: Text('Конец свайпа (добавить)')),
          const PopupMenuItem(value: 'add_long', child: Text('Долгое нажатие')),
        ],
        const PopupMenuItem(value: 'do_swipe_start', child: Text('Свайп отсюда (живой)')),
        if (pending != null)
          const PopupMenuItem(value: 'do_swipe_end', child: Text('Свайп сюда (живой)')),
        const PopupMenuItem(value: 'do_long', child: Text('Долгое нажатие сейчас')),
      ],
    );

    if (!mounted || action == null) return;

    switch (action) {
      case 'add_tap':
        appState.addEmulatorTapStep(x, y);
        _snack('Добавлен тап ($x, $y)');
      case 'swipe_start':
        setState(() => _pendingSwipeStart = pending == null ? (x: x, y: y) : null);
        if (pending == null) _snack('Начало свайпа: ($x, $y)');
      case 'swipe_end':
        final from = _pendingSwipeStart;
        if (from == null) return;
        appState.addEmulatorSwipeStep(from.x, from.y, x, y, durationMs: _swipeMs);
        setState(() => _pendingSwipeStart = null);
        _snack('Добавлен свайп');
      case 'add_long':
        appState.addEmulatorLongPressStep(x, y);
        _snack('Добавлено долгое нажатие');
      case 'do_swipe_start':
        setState(() => _pendingSwipeStart = (x: x, y: y));
        _snack('Живой свайп: выберите конец (ПКМ → Свайп сюда)');
      case 'do_swipe_end':
        final from = _pendingSwipeStart;
        if (from == null) return;
        await _primarySwipe(from.x, from.y, x, y);
        setState(() => _pendingSwipeStart = null);
      case 'do_long':
        final adb = _adb;
        final serial = _serial;
        if (adb == null || serial == null) return;
        await _emu.inputLongPress(adb, serial, x, y);
        await _afterInteract();
    }
  }

  void _snack(String text, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        duration: Duration(seconds: isError ? 8 : 2),
        backgroundColor: isError ? Theme.of(context).colorScheme.errorContainer : null,
      ),
    );
  }

  List<EmulatorStepMarker> _markers(AppState state) {
    final draft = state.editingScenario;
    if (draft == null || !draft.isEmulator) return const [];

    return draft.steps.where((s) => s.x != null && s.y != null).map((s) {
      if (s.type == MacroStepType.emulatorSwipe) {
        return EmulatorStepMarker(
          x: s.x!,
          y: s.y!,
          x2: s.x2,
          y2: s.y2,
          color: Colors.orange,
        );
      }
      if (s.type == MacroStepType.emulatorLongPress) {
        return EmulatorStepMarker(x: s.x!, y: s.y!, color: Colors.purpleAccent);
      }
      return EmulatorStepMarker(x: s.x!, y: s.y!, color: Colors.orange);
    }).toList();
  }

  Future<void> _sendText() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    final adb = _adb;
    final serial = _serial;
    if (adb == null || serial == null) return;
    await _runOp('Отправка…', () async {
      await _emu.inputText(adb, serial, text);
      await _emu.inputKeyEvent(adb, serial, 66);
      _textController.clear();
    });
  }

  Future<void> _key(int code) async {
    final adb = _adb;
    final serial = _serial;
    if (adb == null || serial == null) return;
    await _emu.inputKeyEvent(adb, serial, code);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (mounted) await _capture(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final mode = appState.emulatorMirrorMode;
    final nativeMode = appState.emulatorNativeClickMode;
    _syncNativeBridge(appState);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_busy)
          const LinearProgressIndicator(minHeight: 3),
        if (_error != null)
          Material(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Закрыть',
                    onPressed: () => setState(() => _error = null),
                    icon: Icon(Icons.close, color: Theme.of(context).colorScheme.onErrorContainer, size: 18),
                  ),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _status ?? (_error ?? 'Эмулятор'),
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Запустить AVD',
                onPressed: _busy ? null : _launch,
                icon: const Icon(Icons.play_arrow, size: 20),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Открыть MAX',
                onPressed: _busy ? null : _openMax,
                icon: const Icon(Icons.apps, size: 20),
              ),
              FilledButton.tonal(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: const Size(0, 32),
                ),
                onPressed: _busy ? null : _openMax,
                child: const Text('MAX'),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: nativeMode ? 'Клики в окне телефона' : 'Клики в зеркале',
                onPressed: () => appState.setEmulatorNativeClickMode(!nativeMode),
                icon: Icon(
                  nativeMode ? Icons.smartphone : Icons.screenshot_monitor,
                  size: 20,
                  color: nativeMode ? Colors.lightGreenAccent : null,
                ),
              ),
              if (nativeMode)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Показать окно телефона',
                  onPressed: () {
                    if (!_native.bringToFront()) {
                      _snack('Окно Android Emulator не найдено — запустите эмулятор');
                    }
                  },
                  icon: const Icon(Icons.open_in_new, size: 20),
                ),
              SegmentedButton<EmulatorMirrorMode>(
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(
                    value: EmulatorMirrorMode.control,
                    label: Text('Упр.'),
                    icon: Icon(Icons.touch_app, size: 14),
                  ),
                  ButtonSegment(
                    value: EmulatorMirrorMode.view,
                    label: Text('Смотр.'),
                    icon: Icon(Icons.visibility, size: 14),
                  ),
                ],
                selected: {mode},
                onSelectionChanged: (v) {
                  if (v.isNotEmpty) appState.setEmulatorMirrorMode(v.first);
                },
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: _controlsExpanded ? 'Свернуть' : 'Ещё',
                onPressed: () => setState(() => _controlsExpanded = !_controlsExpanded),
                icon: Icon(_controlsExpanded ? Icons.expand_less : Icons.expand_more, size: 20),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: _live ? 'Пауза' : 'Живое обновление',
                onPressed: () => setState(() => _live = !_live),
                icon: Icon(_live ? Icons.pause : Icons.play_arrow_outlined, size: 20),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Обновить',
                onPressed: _busy ? null : () => _capture(),
                icon: const Icon(Icons.refresh, size: 20),
              ),
            ],
          ),
        ),
        if (nativeMode && mode.canInteract)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              'Кликайте в окне Android Emulator: ЛКМ — тап/свайп, ПКМ — в сценарий.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.lightGreenAccent),
            ),
          ),
        if (_controlsExpanded) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 88,
                  child: TextField(
                    controller: _swipeMsController,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Свайп мс',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    onSubmitted: (v) => _swipeDurationMs = int.tryParse(v) ?? 300,
                  ),
                ),
                OutlinedButton(onPressed: _serial == null ? null : () => _key(4), child: const Text('Назад')),
                OutlinedButton(onPressed: _serial == null ? null : () => _key(3), child: const Text('Home')),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: 'Быстрый текст в MAX…',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _sendText(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _serial == null || _busy ? null : _sendText,
                  child: const Text('Отправить'),
                ),
              ],
            ),
          ),
        ],
        if (!nativeMode && mode.canInteract)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              'ЛКМ — тап/свайп. ПКМ — добавить действие в сценарий.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.lightBlueAccent),
            ),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: nativeMode && mode.canInteract
                ? _buildNativeModeBody(context, appState, mode)
                : _buildMirrorBody(context, appState, mode),
          ),
        ),
      ],
    );
  }

  Widget _buildNativeModeBody(BuildContext context, AppState appState, EmulatorMirrorMode mode) {
    final hwndFound = _native.findEmulatorHwnd() != null;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 2,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  hwndFound ? Icons.smartphone : Icons.smartphone_outlined,
                  size: 56,
                  color: hwndFound ? Colors.lightGreenAccent : Colors.white38,
                ),
                const SizedBox(height: 12),
                Text(
                  hwndFound ? 'Окно телефона активно' : 'Запустите Android Emulator',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    'Управляйте MAX прямо в окне эмулятора SDK. Здесь — только подсказки и превью.',
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _busy ? null : _openMax,
                  icon: const Icon(Icons.apps),
                  label: const Text('Открыть MAX'),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _busy ? null : _launch,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Запустить эмулятор'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () {
                    if (_native.bringToFront()) return;
                    _snack('Окно не найдено');
                  },
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Показать окно телефона'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: _buildMirrorBody(context, appState, mode, compact: true),
        ),
      ],
    );
  }

  Widget _buildMirrorBody(
    BuildContext context,
    AppState appState,
    EmulatorMirrorMode mode, {
    bool compact = false,
  }) {
    if (_error != null && _png == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _launch, child: const Text('Запустить эмулятор')),
          ],
        ),
      );
    }
    if (_png == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return EmulatorScreenView(
      png: _png!,
      deviceW: _deviceW,
      deviceH: _deviceH,
      highlight: _lastTap,
      pendingSwipeStart: _pendingSwipeStart,
      markers: _markers(appState),
      interactEnabled: mode.canInteract && !appState.emulatorNativeClickMode,
      onPrimaryTap: _primaryTap,
      onPrimarySwipe: _primarySwipe,
      onSecondaryTap: _showSecondaryMenu,
    );
  }
}
