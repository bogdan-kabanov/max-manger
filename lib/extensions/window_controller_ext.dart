import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

extension WindowControllerExt on WindowController {
  Future<void> initWindowManagerHandlers() async {
    await setWindowMethodHandler((call) async {
      switch (call.method) {
        case 'window_center':
          return windowManager.center();
        case 'window_close':
          return windowManager.close();
        case 'window_show':
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
