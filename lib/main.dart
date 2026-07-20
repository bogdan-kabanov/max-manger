import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'extensions/window_controller_ext.dart';
import 'models/window_arguments.dart';
import 'screens/automation_window_screen.dart';
import 'screens/emulator_window_screen.dart';
import 'screens/web_window_screen.dart';
import 'services/storage_service.dart';
import 'services/browser_session_manager.dart';
import 'sub_window_app.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  final windowController = await WindowController.fromCurrentEngine();
  await windowController.initWindowManagerHandlers();

  final windowArgs = WindowArguments.fromString(windowController.arguments);

  if (!windowArgs.isMain) {
    await StorageService.instance.init();
    final accountLabel = _accountLabel(windowArgs.accountId);
    switch (windowArgs.type) {
      case WindowType.web:
        await setupWebWindow(accountLabel);
      case WindowType.emulator:
        await setupEmulatorWindow(accountLabel);
      case WindowType.automation:
        await setupAutomationWindow(accountLabel);
      case WindowType.main:
        break;
    }
    runApp(SubWindowApp(arguments: windowArgs));
    return;
  }

  final runtimeVersion = await WebviewController.getWebViewVersion();
  if (runtimeVersion == null) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Требуется Microsoft Edge WebView2 Runtime',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                const Text('Установите WebView2 и перезапустите приложение.'),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => launchUrl(
                    Uri.parse('https://developer.microsoft.com/microsoft-edge/webview2/'),
                  ),
                  child: const Text('Скачать WebView2'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return;
  }

  await StorageService.instance.init();
  final browser = BrowserSessionManager();
  runApp(MaxDesktopApp(browser: browser));
}

String _accountLabel(String? accountId) {
  if (accountId == null) return '';
  for (final account in StorageService.instance.accounts) {
    if (account.id == accountId) return account.label;
  }
  return accountId;
}
