import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import '../models/max_account.dart';
import '../providers/app_state.dart';
import '../services/browser_session_manager.dart';
import 'emulator_inline_panel.dart';

class MaxBrowserPanel extends StatelessWidget {
  const MaxBrowserPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final browser = context.watch<BrowserSessionManager>();
    final appState = context.watch<AppState>();
    final account = appState.selectedAccount ?? browser.activeAccount;

    if (account == null) {
      return const Center(
        child: Text('Выберите или создайте аккаунт слева'),
      );
    }

    final showEmulator = appState.emulatorPanelVisible;
    final focusEmulator = appState.emulatorFocusMode && showEmulator;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BrowserToolbar(
          browser: browser,
          showEmulator: showEmulator,
          focusEmulator: focusEmulator,
        ),
        Expanded(
          child: focusEmulator
              ? EmulatorInlinePanel(account: account)
              : showEmulator
                  ? _ResizableWebEmulatorSplit(
                      browser: browser,
                      account: account,
                      webFraction: appState.emulatorWebFraction,
                      onFractionChanged: appState.setEmulatorWebFraction,
                    )
                  : _WebArea(browser: browser),
        ),
      ],
    );
  }
}

class _WebArea extends StatelessWidget {
  const _WebArea({required this.browser});

  final BrowserSessionManager browser;

  @override
  Widget build(BuildContext context) {
    if (browser.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (browser.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            browser.error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      );
    }
    if (browser.controller?.value.isInitialized == true) {
      return Webview(browser.controller!);
    }
    return const Center(child: Text('Браузер не инициализирован'));
  }
}

class _ResizableWebEmulatorSplit extends StatefulWidget {
  const _ResizableWebEmulatorSplit({
    required this.browser,
    required this.account,
    required this.webFraction,
    required this.onFractionChanged,
  });

  final BrowserSessionManager browser;
  final MaxAccount account;
  final double webFraction;
  final ValueChanged<double> onFractionChanged;

  @override
  State<_ResizableWebEmulatorSplit> createState() => _ResizableWebEmulatorSplitState();
}

class _ResizableWebEmulatorSplitState extends State<_ResizableWebEmulatorSplit> {
  static const _handleHeight = 10.0;

  void _onDragUpdate(DragUpdateDetails details, double totalHeight) {
    if (totalHeight <= _handleHeight) return;
    final usable = totalHeight - _handleHeight;
    final delta = details.delta.dy / usable;
    widget.onFractionChanged(widget.webFraction + delta);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = constraints.maxHeight;
        final webH = (total - _handleHeight) * widget.webFraction;

        return Column(
          children: [
            SizedBox(
              height: webH.clamp(80.0, total - _handleHeight - 120),
              child: _WebArea(browser: widget.browser),
            ),
            MouseRegion(
              cursor: SystemMouseCursors.resizeUpDown,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (d) => _onDragUpdate(d, total),
                child: Container(
                  height: _handleHeight,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    border: Border(
                      top: BorderSide(color: Theme.of(context).dividerColor),
                      bottom: BorderSide(color: Theme.of(context).dividerColor),
                    ),
                  ),
                  child: Container(
                    width: 48,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: EmulatorInlinePanel(account: widget.account),
            ),
          ],
        );
      },
    );
  }
}

class _BrowserToolbar extends StatelessWidget {
  const _BrowserToolbar({
    required this.browser,
    required this.showEmulator,
    required this.focusEmulator,
  });

  final BrowserSessionManager browser;
  final bool showEmulator;
  final bool focusEmulator;

  @override
  Widget build(BuildContext context) {
    final appState = context.read<AppState>();
    final account = browser.activeAccount ?? appState.selectedAccount;
    if (account == null) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: [
          Text(account.label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              browser.currentUrl,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (showEmulator)
            IconButton(
              tooltip: focusEmulator ? 'Показать веб' : 'Только эмулятор',
              onPressed: () => appState.setEmulatorFocusMode(!focusEmulator),
              icon: Icon(focusEmulator ? Icons.web : Icons.crop_portrait),
            ),
          IconButton(
            tooltip: showEmulator ? 'Скрыть эмулятор' : 'Показать эмулятор',
            onPressed: () => appState.setEmulatorPanelVisible(!showEmulator),
            icon: Icon(showEmulator ? Icons.phone_android : Icons.phone_android_outlined),
          ),
          IconButton(
            tooltip: 'Домой (web.max.ru)',
            onPressed: browser.goHome,
            icon: const Icon(Icons.home_outlined),
          ),
          IconButton(
            tooltip: 'Обновить',
            onPressed: browser.reload,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Проверить мост автоматизации',
            onPressed: browser.pingBridge,
            icon: const Icon(Icons.bolt_outlined),
          ),
        ],
      ),
    );
  }
}
