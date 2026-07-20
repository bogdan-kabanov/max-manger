import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_theme.dart';
import 'models/window_arguments.dart';
import 'providers/app_state.dart';
import 'screens/automation_window_screen.dart';
import 'screens/emulator_window_screen.dart';
import 'screens/web_window_screen.dart';
import 'services/browser_session_manager.dart';
import 'services/storage_service.dart';

class SubWindowApp extends StatelessWidget {
  const SubWindowApp({super.key, required this.arguments});

  final WindowArguments arguments;

  @override
  Widget build(BuildContext context) {
    final browser = BrowserSessionManager();
    final accountId = arguments.accountId;

    return MultiProvider(
      providers: [
        ChangeNotifierProvider<BrowserSessionManager>.value(value: browser),
        ChangeNotifierProvider(
          create: (_) {
            final state = AppState(browser);
            browser.onAuthTokenCaptured = state.applyCapturedToken;
            return state;
          },
        ),
      ],
      child: Builder(
        builder: (context) {
          if (accountId == null) {
            return MaterialApp(
              theme: buildMaxDesktopTheme(),
              home: const Scaffold(body: Center(child: Text('Нет accountId'))),
            );
          }

          final label = StorageService.instance.accounts
              .where((a) => a.id == accountId)
              .map((a) => a.label)
              .firstOrNull;

          return MaterialApp(
            title: arguments.windowTitle(label ?? accountId),
            debugShowCheckedModeBanner: false,
            theme: buildMaxDesktopTheme(),
            home: switch (arguments.type) {
              WindowType.web => WebWindowScreen(accountId: accountId),
              WindowType.emulator => EmulatorWindowScreen(accountId: accountId),
              WindowType.automation => AutomationWindowScreen(accountId: accountId),
              WindowType.main => const Scaffold(body: Center(child: Text('Invalid sub-window'))),
            },
          );
        },
      ),
    );
  }
}
