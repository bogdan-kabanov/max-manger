import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_theme.dart';
import 'providers/app_state.dart';
import 'screens/hub_screen.dart';
import 'services/browser_session_manager.dart';

class MaxDesktopApp extends StatelessWidget {
  const MaxDesktopApp({super.key, required this.browser});

  final BrowserSessionManager browser;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<BrowserSessionManager>.value(value: browser),
        ChangeNotifierProvider(
          create: (_) {
            final state = AppState(browser);
            browser.onAuthTokenCaptured = state.applyCapturedToken;
            state.bootstrap();
            return state;
          },
        ),
      ],
      child: MaterialApp(
        title: 'MAX Desktop',
        debugShowCheckedModeBanner: false,
        theme: buildMaxDesktopTheme(),
        home: const HubScreen(),
      ),
    );
  }
}
