import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';
import 'package:window_manager/window_manager.dart';

import '../extensions/window_controller_ext.dart';
import '../providers/app_state.dart';
import '../services/browser_session_manager.dart';
import '../widgets/web_clicker_panel.dart';

class WebWindowScreen extends StatefulWidget {
  const WebWindowScreen({super.key, required this.accountId});

  final String accountId;

  @override
  State<WebWindowScreen> createState() => _WebWindowScreenState();
}

class _WebWindowScreenState extends State<WebWindowScreen> {
  bool _showClicker = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await context.read<AppState>().selectAccountById(widget.accountId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final browser = context.watch<BrowserSessionManager>();
    final account = state.selectedAccount;

    if (account == null) {
      return const Scaffold(body: Center(child: Text('Аккаунт не найден')));
    }

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
        title: Text('MAX — ${account.label}', style: const TextStyle(fontSize: 15)),
        actions: [
          if (browser.isPicking)
            TextButton(
              onPressed: browser.cancelPick,
              child: const Text('Отмена захвата'),
            ),
          IconButton(
            tooltip: _showClicker ? 'Скрыть кликер' : 'Показать кликер',
            onPressed: () {
              if (_showClicker && browser.isPicking) browser.cancelPick();
              setState(() => _showClicker = !_showClicker);
            },
            icon: Icon(_showClicker ? Icons.chevron_right : Icons.ads_click),
          ),
          IconButton(tooltip: 'Домой', onPressed: browser.goHome, icon: const Icon(Icons.home_outlined, size: 20)),
          IconButton(tooltip: 'Обновить', onPressed: browser.reload, icon: const Icon(Icons.refresh, size: 20)),
          IconButton(
            tooltip: 'Закрыть',
            onPressed: () async {
              final controller = await WindowController.fromCurrentEngine();
              await controller.close();
            },
            icon: const Icon(Icons.close, size: 20),
          ),
        ],
      ),
      body: Row(
        children: [
          Expanded(
            child: browser.isLoading
                ? const Center(child: CircularProgressIndicator())
                : browser.error != null
                    ? Center(
                        child: Text(
                          browser.error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.red),
                        ),
                      )
                    : browser.controller?.value.isInitialized == true
                        ? Webview(browser.controller!)
                        : const Center(child: Text('Браузер не инициализирован')),
          ),
          if (_showClicker)
            const SizedBox(width: 300, child: WebClickerPanel()),
        ],
      ),
    );
  }
}

Future<void> setupWebWindow(String accountLabel) async {
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: const Size(1440, 920),
      minimumSize: const Size(900, 600),
      center: true,
      title: 'MAX Web — $accountLabel',
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
}
