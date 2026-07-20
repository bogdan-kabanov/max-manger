import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import '../models/ai_chat_config.dart';
import '../models/automation_rule.dart';
import '../models/macro_scenario.dart';
import '../models/max_account.dart';
import 'automation_bridge.dart';
import 'fingerprint_bridge.dart';
import 'session_inject_bridge.dart';
import 'storage_service.dart';
import 'token_capture_bridge.dart';
import 'webview_environment_coordinator.dart';

class BrowserLogEntry {
  BrowserLogEntry({
    required this.time,
    required this.message,
    this.level = 'info',
  });

  final DateTime time;
  final String message;
  final String level;
}

class BrowserSessionManager extends ChangeNotifier {
  static const maxUrl = 'https://web.max.ru/';

  BrowserSessionManager() {
    WebviewEnvironmentCoordinator.instance.registerReleaseCallback(releaseWebview);
  }

  WebviewController? controller;
  MaxAccount? activeAccount;
  bool isLoading = false;
  String? error;
  String currentUrl = maxUrl;
  final List<BrowserLogEntry> logs = [];

  StreamSubscription<dynamic>? _webMessageSub;
  StreamSubscription<String>? _urlSub;
  Completer<Map<String, dynamic>?>? _pickCompleter;
  bool isPicking = false;

  void Function(String token, String? phone)? onAuthTokenCaptured;

  Future<void> openAccount(MaxAccount account) async {
    if (activeAccount?.id == account.id && controller?.value.isInitialized == true) {
      return;
    }

    isLoading = true;
    error = null;
    notifyListeners();

    try {
      await _closeInternal();

      final profilePath = StorageService.instance.profileDirFor(account.id).path;
      await Directory(profilePath).create(recursive: true);

      final isolation = account.isolation;
      await WebviewEnvironmentCoordinator.instance.ensureEnvironment(
        userDataPath: profilePath,
        additionalArguments: isolation.chromiumArguments(),
      );

      final webview = WebviewController();
      WebviewEnvironmentCoordinator.instance.notifyControllerCreated();
      try {
        await webview.initialize();
      } catch (e) {
        WebviewEnvironmentCoordinator.instance.notifyControllerDisposed();
        rethrow;
      }

      await webview.addScriptToExecuteOnDocumentCreated(
        FingerprintBridge.documentScript(isolation),
      );
      await webview.addScriptToExecuteOnDocumentCreated(
        AutomationBridge.documentCreatedScript(),
      );
      await webview.addScriptToExecuteOnDocumentCreated(
        TokenCaptureBridge.documentScript(),
      );
      if (account.hasApiSession) {
        await webview.addScriptToExecuteOnDocumentCreated(
          SessionInjectBridge.documentScript(
            token: account.apiToken!,
            deviceId: account.webDeviceId,
            viewerId: account.viewerId,
          ),
        );
      }

      _webMessageSub = webview.webMessage.listen(_onWebMessage);
      _urlSub = webview.url.listen((url) {
        currentUrl = url;
        notifyListeners();
      });

      await webview.loadUrl(maxUrl);

      controller = webview;
      activeAccount = account;
      await StorageService.instance.touchAccount(account.id);

      await Future<void>.delayed(const Duration(seconds: 2));
      await webview.executeScript(TokenCaptureBridge.documentScript());
      await webview.executeScript(AutomationBridge.ensureInstalledScript());

      await _syncAutomationRules();
      _log('Профиль изолирован: ${isolation.screenWidth}x${isolation.screenHeight}, '
          'UA Chrome/Edge, ${isolation.proxyServer == null ? "без прокси" : "прокси задан"}');
      _log('Открыт официальный MAX для «${account.label}»');
      if (account.hasApiSession) {
        _log('Сессия по токену подставлена в web.max.ru');
      }
    } on PlatformException catch (e) {
      error = e.message ?? 'Не удалось открыть браузер';
      _log(error!, level: 'error');
    } catch (e) {
      error = e.toString();
      _log(error!, level: 'error');
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> reload() async {
    final webview = controller;
    if (webview == null) return;
    await webview.loadUrl(currentUrl.isEmpty ? maxUrl : currentUrl);
  }

  Future<void> goHome() async {
    final webview = controller;
    if (webview == null) return;
    await webview.loadUrl(maxUrl);
  }

  /// Opens invite link in web MAX and auto-clicks rules/confirm dialogs.
  Future<bool> openJoinLinkAndConfirm(String url, {int attempts = 10}) async {
    final webview = controller;
    if (webview == null || !webview.value.isInitialized) return false;

    final trimmed = url.trim();
    if (!trimmed.contains('max.ru/join/')) return false;

    _log('Открываем ссылку вступления…');
    await webview.loadUrl(trimmed);

    for (var i = 0; i < attempts; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      try {
        await webview.executeScript(AutomationBridge.ensureInstalledScript());
        final raw = await webview.executeScript(AutomationBridge.confirmJoin(verbose: true));
        final ok = raw == true || raw?.toString().toLowerCase() == 'true';
        if (ok) {
          _log('✓ Подтверждение вступления нажато автоматически');
          return true;
        }
      } catch (_) {}
    }

    _log('Окно подтверждения не найдено — откройте ссылку вручную', level: 'warn');
    return false;
  }

  /// Reads `__oneme_auth` from the active WebView profile (QR login).
  Future<({String token, int? viewerId})?> readStoredAuthSession() async {
    final webview = controller;
    if (webview == null || !webview.value.isInitialized) return null;

    try {
      final raw = await webview.executeScript(r'''
        (function () {
          try {
            var s = localStorage.getItem('__oneme_auth');
            if (!s) return '';
            var a = JSON.parse(s);
            var token = a.token || (a.tokenAttrs && a.tokenAttrs.token) || '';
            if (!token || token.length < 50) return '';
            return JSON.stringify({ token: token, viewerId: a.viewerId || null });
          } catch (e) { return ''; }
        })()
      ''');
      final text = raw?.toString().trim() ?? '';
      if (text.isEmpty || !text.startsWith('{')) return null;

      final map = jsonDecode(text) as Map<String, dynamic>;
      final token = map['token']?.toString() ?? '';
      if (token.length < 50) return null;

      final viewerIdRaw = map['viewerId'];
      int? viewerId;
      if (viewerIdRaw is int) {
        viewerId = viewerIdRaw;
      } else if (viewerIdRaw is num) {
        viewerId = viewerIdRaw.toInt();
      } else if (viewerIdRaw != null) {
        viewerId = int.tryParse(viewerIdRaw.toString());
      }

      return (token: token, viewerId: viewerId);
    } catch (e) {
      _log('Не удалось прочитать токен из браузера: $e', level: 'warn');
      return null;
    }
  }

  Future<void> syncAutomation(List<AutomationRule> rules, {bool enabled = true}) async {
    final webview = controller;
    if (webview == null || !webview.value.isInitialized) return;
    final payload = enabled
        ? rules
            .where((r) => r.enabled)
            .map(
              (r) => {
                'type': r.type.name == 'autoReply' ? 'autoReply' : 'keywordReply',
                'enabled': r.enabled,
                'keywords': r.keywords,
                'replyText': r.replyText,
                'matchContains': r.matchContains,
              },
            )
            .toList()
        : <Map<String, dynamic>>[];
    await webview.executeScript(
      'window.__maxDesktop && window.__maxDesktop.setRules(${jsonEncode(payload)});',
    );
    await webview.executeScript(AutomationBridge.setEnabled(enabled));
    _log('Правила автоматизации обновлены (${payload.length})');
    notifyListeners();
  }

  Future<void> syncAiConfig(AiChatConfig config, {bool resetSeen = false}) async {
    _log(config.enabled
        ? '[ИИ] Настройки сохранены — WS подключается отдельно'
        : 'ИИ-бот выключен');
    notifyListeners();
  }

  Future<void> runScan({bool force = false}) async {
    _log('[ИИ] Используйте «Переподключить WS» — DOM-скан отключён');
    notifyListeners();
  }

  Future<bool> sendChatMessage(String text) async {
    final webview = controller;
    if (webview == null || !webview.value.isInitialized) {
      _log('[ИИ] Отправка: браузер не готов', level: 'error');
      return false;
    }
    final preview = text.length > 80 ? '${text.substring(0, 80)}…' : text;
    _log('[ИИ] Отправка в чат: «$preview»');
    final result = await webview.executeScript(AutomationBridge.sendMessage(text));
    final ok = result == true;
    if (!ok) {
      _log('[ИИ] Отправка не удалась (нет поля ввода или кнопки)', level: 'error');
    }
    return ok;
  }

  void logMessage(String message, {String level = 'info'}) => _log(message, level: level);

  Future<void> pingBridge() async {
    final webview = controller;
    if (webview == null) return;
    await webview.executeScript(AutomationBridge.ping());
  }

  Future<void> runScenario(MacroScenario scenario) async {
    final webview = controller;
    if (webview == null || !webview.value.isInitialized) {
      _log('Сценарий «${scenario.name}»: браузер не готов', level: 'error');
      return;
    }
    _log('Запуск сценария «${scenario.name}» (${scenario.steps.length} шагов)');
    await webview.executeScript(AutomationBridge.runMacro(scenario));
  }

  Future<Map<String, dynamic>?> pickElement() async {
    final webview = controller;
    if (webview == null || !webview.value.isInitialized) return null;
    if (_pickCompleter != null) return null;

    _pickCompleter = Completer<Map<String, dynamic>?>();
    isPicking = true;
    notifyListeners();
    await webview.executeScript(AutomationBridge.enablePicker());
    _log('Режим захвата: кликните элемент на странице MAX');

    try {
      return await _pickCompleter!.future.timeout(
        const Duration(seconds: 90),
        onTimeout: () {
          _log('Захват элемента отменён по таймауту', level: 'warn');
          return null;
        },
      );
    } finally {
      isPicking = false;
      _pickCompleter = null;
      await webview.executeScript(AutomationBridge.disablePicker());
      notifyListeners();
    }
  }

  Future<void> cancelPick() async {
    final webview = controller;
    _pickCompleter?.complete(null);
    _pickCompleter = null;
    isPicking = false;
    if (webview != null) {
      await webview.executeScript(AutomationBridge.disablePicker());
    }
    notifyListeners();
  }

  Future<void> close() async {
    await _closeInternal();
    activeAccount = null;
    notifyListeners();
  }

  Future<void> _syncAutomationRules() async {
    final account = activeAccount;
    if (account == null) return;
    final rules = StorageService.instance.rulesFor(account.id);
    await syncAutomation(rules);
  }

  Future<void> releaseWebview() async {
    if (controller == null) return;
    await _closeInternal();
    notifyListeners();
  }

  Future<void> _closeInternal() async {
    await _webMessageSub?.cancel();
    await _urlSub?.cancel();
    _webMessageSub = null;
    _urlSub = null;

    final webview = controller;
    controller = null;
    if (webview != null) {
      await webview.dispose();
      WebviewEnvironmentCoordinator.instance.notifyControllerDisposed();
    }
  }

  void _onWebMessage(dynamic message) {
    try {
      final decoded = message is String ? jsonDecode(message) : message;
      if (decoded is! Map) return;
      final type = decoded['type']?.toString() ?? 'unknown';
      final payload = decoded['payload'];

      switch (type) {
        case 'automation.ready':
          _log('Автоматизация готова на ${payload is Map ? payload['href'] : maxUrl}');
        case 'automation.reply':
          if (payload is Map) {
            _log('Автоответ: «${payload['text']}» → «${payload['reply']}»');
          }
        case 'automation.log':
          if (payload is Map) {
            _log(payload['message']?.toString() ?? 'log', level: payload['level']?.toString() ?? 'info');
          }
        case 'automation.pong':
          if (payload is Map) {
            _log('Страница: ${payload['title']}');
          }
        case 'macro.stepDone':
          if (payload is Map) {
            final ok = payload['ok'] == true;
            final type = payload['type']?.toString() ?? 'step';
            if (ok) {
              _log('Шаг $type выполнен');
            } else {
              _log('Шаг $type: ${payload['error']}', level: 'error');
            }
          }
        case 'macro.done':
          _log('Сценарий завершён');
        case 'macro.picked':
          if (payload is Map) {
            if (payload['ok'] == true) {
              _log('Захвачен: ${payload['selector']}');
            } else {
              _log('Захват не удался: ${payload['error']}', level: 'warn');
            }
            _pickCompleter?.complete(Map<String, dynamic>.from(payload));
            _pickCompleter = null;
            isPicking = false;
          }
        case 'macro.pickerEnabled':
          _log('Кликните элемент на странице MAX');
        case 'auth.tokenCaptured':
          if (payload is Map) {
            final token = payload['token']?.toString();
            if (token != null && token.isNotEmpty) {
              final phone = payload['phone']?.toString();
              unawaited(_persistCapturedToken(token, phone));
            }
          }
        default:
          if (!type.startsWith('automation.') && !type.startsWith('macro.')) {
            _log('Событие: $type');
          }
      }
      notifyListeners();
    } catch (e) {
      _log('Ошибка сообщения WebView: $e', level: 'error');
      notifyListeners();
    }
  }

  Future<void> _persistCapturedToken(String token, String? phone) async {
    final account = activeAccount;
    if (account == null || account.apiToken == token) return;

    final updated = account.copyWith(
      apiToken: token,
      phone: phone ?? account.phone,
      authMethod: MaxAuthMethod.token,
    );
    await StorageService.instance.updateAccount(updated);
    activeAccount = updated;
    _log('API-токен сохранён после входа на web.max.ru');
    onAuthTokenCaptured?.call(token, phone);
    notifyListeners();
  }

  void _log(String message, {String level = 'info'}) {
    logs.insert(
      0,
      BrowserLogEntry(time: DateTime.now(), message: message, level: level),
    );
    if (logs.length > 500) {
      logs.removeRange(500, logs.length);
    }
  }

  @override
  void dispose() {
    WebviewEnvironmentCoordinator.instance.unregisterReleaseCallback(releaseWebview);
    unawaited(_closeInternal());
    super.dispose();
  }
}
