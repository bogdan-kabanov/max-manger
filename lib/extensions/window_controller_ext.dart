import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../services/storage_service.dart';

/// Keeps a secondary window alive when the user hits the title-bar X.
///
/// Destroying a [desktop_multi_window] child with WebView2 / window_manager
/// often posts a process-wide quit on Windows. Hiding reuses the engine on
/// the next [WindowLauncher] open instead.
class SubWindowCloseGuard with WindowListener {
  SubWindowCloseGuard._();

  static SubWindowCloseGuard? _instance;

  static Future<void> install() async {
    final guard = _instance ??= SubWindowCloseGuard._();
    windowManager.addListener(guard);
    await windowManager.setPreventClose(true);
  }

  @override
  void onWindowClose() {
    windowManager.hide();
  }
}

extension WindowControllerExt on WindowController {
  Future<void> initWindowManagerHandlers({bool closeAsHide = false}) async {
    await setWindowMethodHandler((call) async {
      switch (call.method) {
        case 'window_center':
          return windowManager.center();
        case 'window_close':
          if (closeAsHide) {
            return windowManager.hide();
          }
          return windowManager.close();
        case 'window_show':
          // Hidden engines keep a stale StorageService snapshot; refresh
          // before any touchAccount / updateAccount can rewrite data.json.
          try {
            await StorageService.instance.reloadFromDisk();
          } catch (_) {}
          return windowManager.show();
        default:
          throw MissingPluginException('Not implemented: ${call.method}');
      }
    });
  }

  Future<void> center() => invokeMethod('window_center');

  Future<void> close() => invokeMethod('window_close');

  Future<void> focusShow() => invokeMethod('window_show');
}
