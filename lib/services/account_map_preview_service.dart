import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import '../models/max_account.dart';
import '../utils/phone_viewport.dart';
import 'emulator_service.dart';

enum AccountCardViewMode { web, emulator }

class AccountScreenPreview {
  const AccountScreenPreview({
    this.bytes,
    this.error,
    this.statusMessage,
    this.updatedAt,
    this.loading = false,
    this.deviceWidth,
    this.deviceHeight,
    this.webLoaded = false,
  });

  final Uint8List? bytes;
  final String? error;
  final String? statusMessage;
  final DateTime? updatedAt;
  final bool loading;
  final int? deviceWidth;
  final int? deviceHeight;
  final bool webLoaded;

  bool get hasImage => bytes != null && bytes!.isNotEmpty;

  AccountScreenPreview copyWith({
    Uint8List? bytes,
    String? error,
    String? statusMessage,
    DateTime? updatedAt,
    bool? loading,
    int? deviceWidth,
    int? deviceHeight,
    bool? webLoaded,
    bool clearBytes = false,
    bool clearError = false,
    bool clearStatus = false,
  }) {
    return AccountScreenPreview(
      bytes: clearBytes ? null : (bytes ?? this.bytes),
      error: clearError ? null : (error ?? this.error),
      statusMessage: clearStatus ? null : (statusMessage ?? this.statusMessage),
      updatedAt: updatedAt ?? this.updatedAt,
      loading: loading ?? this.loading,
      deviceWidth: deviceWidth ?? this.deviceWidth,
      deviceHeight: deviceHeight ?? this.deviceHeight,
      webLoaded: webLoaded ?? this.webLoaded,
    );
  }
}

class AccountNodePreviews {
  const AccountNodePreviews({
    this.web = const AccountScreenPreview(),
    this.emulator = const AccountScreenPreview(),
  });

  final AccountScreenPreview web;
  final AccountScreenPreview emulator;

  AccountNodePreviews copyWith({
    AccountScreenPreview? web,
    AccountScreenPreview? emulator,
  }) {
    return AccountNodePreviews(
      web: web ?? this.web,
      emulator: emulator ?? this.emulator,
    );
  }
}

/// Loads web (live rotation) + emulator thumbnails for every account on the map.
class AccountMapPreviewService extends ChangeNotifier {
  AccountMapPreviewService();

  final EmulatorService _emu = EmulatorService.instance;
  final Map<String, AccountNodePreviews> _previews = {};
  final Map<String, AccountCardViewMode> _viewModes = {};

  List<MaxAccount> _accounts = const [];
  Timer? _emuTimer;
  int _emuCursor = 0;
  bool _running = false;
  bool _paused = false;
  int _webLoopGeneration = 0;

  String? webLiveAccountId;
  WebviewController? webController;
  bool webLiveReady = false;
  String? webLiveError;

  Completer<void>? _webReadyCompleter;

  bool get isPaused => _paused;

  AccountNodePreviews previewsFor(String accountId) =>
      _previews[accountId] ?? const AccountNodePreviews();

  AccountCardViewMode viewModeFor(String accountId) =>
      _viewModes[accountId] ?? AccountCardViewMode.web;

  MaxAccount? accountById(String id) {
    for (final account in _accounts) {
      if (account.id == id) return account;
    }
    return null;
  }

  bool isWebLive(String accountId) =>
      !_paused && _running && webLiveAccountId == accountId;

  void setViewMode(String accountId, AccountCardViewMode mode) {
    if (_viewModes[accountId] == mode) return;
    _viewModes[accountId] = mode;
    notifyListeners();
  }

  void setWebController(WebviewController? controller) {
    if (identical(webController, controller)) return;
    webController = controller;
    notifyListeners();
  }

  void reportWebLoaded(String accountId) {
    if (webLiveAccountId != accountId) return;
    webLiveReady = true;
    webLiveError = null;
    final current = _previews[accountId] ?? const AccountNodePreviews();
    _previews[accountId] = current.copyWith(
      web: AccountScreenPreview(
        loading: false,
        webLoaded: true,
        deviceWidth: PhoneViewport.webDeviceW,
        deviceHeight: PhoneViewport.webDeviceH,
        updatedAt: DateTime.now(),
      ),
    );
    if (!(_webReadyCompleter?.isCompleted ?? true)) {
      _webReadyCompleter!.complete();
    }
    notifyListeners();
  }

  void reportWebFailed(String accountId, String message) {
    if (webLiveAccountId != accountId) return;
    webLiveReady = false;
    webLiveError = message;
    _setWebPreview(
      accountId,
      AccountScreenPreview(
        error: message,
        loading: false,
        deviceWidth: PhoneViewport.webDeviceW,
        deviceHeight: PhoneViewport.webDeviceH,
      ),
    );
    if (!(_webReadyCompleter?.isCompleted ?? true)) {
      _webReadyCompleter!.complete();
    }
    notifyListeners();
  }

  void syncAccounts(List<MaxAccount> accounts) {
    _accounts = accounts;
    final ids = accounts.map((a) => a.id).toSet();
    _previews.removeWhere((id, _) => !ids.contains(id));
    _viewModes.removeWhere((id, _) => !ids.contains(id));
    for (final account in accounts) {
      _previews.putIfAbsent(
        account.id,
        () => const AccountNodePreviews(
          web: AccountScreenPreview(
            loading: false,
            statusMessage: 'В очереди',
            deviceWidth: PhoneViewport.webDeviceW,
            deviceHeight: PhoneViewport.webDeviceH,
          ),
          emulator: AccountScreenPreview(loading: true),
        ),
      );
    }
    notifyListeners();
  }

  void setPaused(bool paused) {
    if (_paused == paused) return;
    _paused = paused;
    if (paused) {
      _webLoopGeneration++;
      webLiveAccountId = null;
      webLiveReady = false;
      webController = null;
      _webReadyCompleter?.complete();
    } else if (_running) {
      unawaited(_startWebLiveLoop());
    }
    notifyListeners();
  }

  void start() {
    if (_running) return;
    _running = true;
    _paused = false;

    for (final account in _accounts) {
      _previews[account.id] = AccountNodePreviews(
        web: (_previews[account.id]?.web ?? const AccountScreenPreview()).copyWith(
          loading: false,
          statusMessage: 'В очереди',
          clearError: true,
          deviceWidth: PhoneViewport.webDeviceW,
          deviceHeight: PhoneViewport.webDeviceH,
        ),
        emulator: (_previews[account.id]?.emulator ?? const AccountScreenPreview()).copyWith(
          loading: true,
          clearError: true,
        ),
      );
    }
    notifyListeners();

    _emuTimer?.cancel();
    _emuTimer = Timer.periodic(const Duration(milliseconds: 2000), (_) => _captureNextEmulator());
    unawaited(_captureNextEmulator());
    unawaited(_startWebLiveLoop());
  }

  void stop() {
    _running = false;
    _webLoopGeneration++;
    _emuTimer?.cancel();
    _emuTimer = null;
    webLiveAccountId = null;
    webLiveReady = false;
    webController = null;
    _webReadyCompleter?.complete();
  }

  Future<void> refreshAll() async {
    _webLoopGeneration++;
    for (final account in _accounts) {
      _previews[account.id] = AccountNodePreviews(
        web: const AccountScreenPreview(
          loading: false,
          statusMessage: 'В очереди',
          deviceWidth: PhoneViewport.webDeviceW,
          deviceHeight: PhoneViewport.webDeviceH,
        ),
        emulator: const AccountScreenPreview(loading: true),
      );
    }
    webLiveAccountId = null;
    webLiveReady = false;
    notifyListeners();
    if (_running && !_paused) {
      unawaited(_captureNextEmulator());
      unawaited(_startWebLiveLoop());
    }
  }

  Future<void> _captureNextEmulator() async {
    if (!_running || _paused || _accounts.isEmpty) return;

    final account = _accounts[_emuCursor % _accounts.length];
    _emuCursor++;

    final prev = _previews[account.id] ?? const AccountNodePreviews();
    _previews[account.id] = prev.copyWith(
      emulator: prev.emulator.copyWith(loading: true, clearError: true),
    );
    notifyListeners();

    try {
      final sdk = await _emu.detectSdk();
      if (!sdk.available || sdk.adbPath == null) {
        throw StateError('Android SDK не найден');
      }
      final serial = await _emu.resolveSerial(account, timeout: const Duration(seconds: 5));
      final size = await _emu.getDisplaySize(sdk.adbPath!, serial);
      final bytes = await _emu.captureScreenshot(sdk.adbPath!, serial);
      if (bytes == null || bytes.isEmpty) {
        throw StateError('Эмулятор не запущен');
      }
      final current = _previews[account.id] ?? const AccountNodePreviews();
      _previews[account.id] = current.copyWith(
        emulator: AccountScreenPreview(
          bytes: bytes,
          updatedAt: DateTime.now(),
          loading: false,
          deviceWidth: size.$1,
          deviceHeight: size.$2,
        ),
      );
    } catch (e) {
      final msg = e.toString().replaceFirst('Bad state: ', '').replaceFirst('StateError: ', '');
      final current = _previews[account.id] ?? const AccountNodePreviews();
      final keepImage = current.emulator.hasImage;
      _previews[account.id] = current.copyWith(
        emulator: keepImage
            ? current.emulator.copyWith(loading: false)
            : AccountScreenPreview(error: msg, loading: false),
      );
    }
    notifyListeners();
  }

  Future<void> _startWebLiveLoop() async {
    if (!_running || _paused) return;

    final generation = ++_webLoopGeneration;

    while (_running && !_paused && generation == _webLoopGeneration) {
      for (final account in List<MaxAccount>.from(_accounts)) {
        if (!_running || _paused || generation != _webLoopGeneration) return;

        webLiveAccountId = account.id;
        webLiveReady = false;
        webLiveError = null;
        _webReadyCompleter = Completer<void>();

        _setWebPreview(
          account.id,
          const AccountScreenPreview(
            loading: true,
            deviceWidth: PhoneViewport.webDeviceW,
            deviceHeight: PhoneViewport.webDeviceH,
          ),
        );
        notifyListeners();

        try {
          await _webReadyCompleter!.future.timeout(const Duration(seconds: 60));
        } on TimeoutException {
          reportWebFailed(account.id, 'Таймаут загрузки web');
        }

        if (webLiveReady && webLiveError == null) {
          await Future<void>.delayed(const Duration(seconds: 15));
        }

        if (generation != _webLoopGeneration || !_running || _paused) return;

        if (webLiveAccountId == account.id) {
          final current = _previews[account.id] ?? const AccountNodePreviews();
          if (current.web.loading) {
            _setWebPreview(
              account.id,
              current.web.copyWith(
                loading: false,
                statusMessage: current.web.webLoaded ? null : 'В очереди',
              ),
            );
          }
          webLiveAccountId = null;
          webLiveReady = false;
          notifyListeners();
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      }

      if (!_running || _paused || generation != _webLoopGeneration) return;
      await Future<void>.delayed(const Duration(seconds: 4));
    }
  }

  void _setWebPreview(String accountId, AccountScreenPreview web) {
    final current = _previews[accountId] ?? const AccountNodePreviews();
    _previews[accountId] = current.copyWith(web: web);
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
