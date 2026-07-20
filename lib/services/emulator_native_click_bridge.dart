import 'dart:async';
import 'dart:io';

import 'emulator_native_window_service.dart';

typedef NativeTapHandler = void Function(int x, int y);
typedef NativeSwipeHandler = void Function(int x1, int y1, int x2, int y2);
typedef NativeSecondaryHandler = void Function(int x, int y);

/// Polls mouse on the Android Emulator OS window and forwards taps/swipes.
class EmulatorNativeClickBridge {
  EmulatorNativeClickBridge({
    required this.onPrimaryTap,
    required this.onPrimarySwipe,
    required this.onSecondaryTap,
    required this.deviceWidth,
    required this.deviceHeight,
  });

  final NativeTapHandler onPrimaryTap;
  final NativeSwipeHandler onPrimarySwipe;
  final NativeSecondaryHandler onSecondaryTap;
  final int deviceWidth;
  final int deviceHeight;

  final _native = EmulatorNativeWindowService.instance;
  Timer? _timer;
  bool _wasLmb = false;
  bool _wasRmb = false;
  ({int x, int y})? _swipeStart;

  bool get isRunning => _timer != null;

  void start() {
    if (!Platform.isWindows) return;
    stop();
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) => _poll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _wasLmb = false;
    _wasRmb = false;
    _swipeStart = null;
  }

  void _poll() {
    if (!_native.isEmulatorForeground()) return;

    final lmb = _native.isLeftButtonDown();
    final rmb = _native.isRightButtonDown();

    if (lmb && !_wasLmb) {
      final pt = _native.cursorToDevice(deviceWidth, deviceHeight);
      if (pt != null) _swipeStart = pt;
    }

    if (!lmb && _wasLmb) {
      final pt = _native.cursorToDevice(deviceWidth, deviceHeight);
      final start = _swipeStart;
      _swipeStart = null;
      if (pt != null && start != null) {
        final dx = pt.x - start.x;
        final dy = pt.y - start.y;
        if (dx * dx + dy * dy < 400) {
          onPrimaryTap(start.x, start.y);
        } else {
          onPrimarySwipe(start.x, start.y, pt.x, pt.y);
        }
      }
    }

    if (rmb && !_wasRmb) {
      final pt = _native.cursorToDevice(deviceWidth, deviceHeight);
      if (pt != null) onSecondaryTap(pt.x, pt.y);
    }

    _wasLmb = lmb;
    _wasRmb = rmb;
  }
}
