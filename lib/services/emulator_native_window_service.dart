import 'dart:ffi';
import 'dart:io';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../utils/emulator_coords.dart';

/// Locates the Android Emulator OS window and maps mouse coords to device pixels.
class EmulatorNativeWindowService {
  EmulatorNativeWindowService._();

  static final EmulatorNativeWindowService instance = EmulatorNativeWindowService._();

  static final List<HWND> _matches = [];

  bool get isSupported => Platform.isWindows;

  static int _collectHwnd(Pointer hwnd, int _) {
    final h = HWND(hwnd);
    if (!IsWindowVisible(h)) return 1;

    final length = GetWindowTextLength(h).value;
    if (length <= 0) return 1;

    final buffer = calloc<WCHAR>(length + 1);
    GetWindowText(h, PWSTR(buffer.cast()), length + 1);
    final title = PWSTR(buffer.cast()).toDartString();
    calloc.free(buffer);

    if (title.contains('Android Emulator')) {
      _matches.add(h);
    }
    return 1;
  }

  HWND? findEmulatorHwnd() {
    if (!isSupported) return null;
    _matches.clear();
    final cb = Pointer.fromFunction<WNDENUMPROC>(_collectHwnd, 1);
    EnumWindows(cb, LPARAM(0));
    return _matches.isEmpty ? null : _matches.last;
  }

  bool bringToFront() {
    final hwnd = findEmulatorHwnd();
    if (hwnd == null) return false;
    if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
    SetForegroundWindow(hwnd);
    return true;
  }

  ({int clientW, int clientH})? clientSize() {
    final hwnd = findEmulatorHwnd();
    if (hwnd == null) return null;

    final rect = calloc<RECT>();
    GetClientRect(hwnd, rect);
    final size = (
      clientW: rect.ref.right - rect.ref.left,
      clientH: rect.ref.bottom - rect.ref.top,
    );
    calloc.free(rect);
    return size;
  }

  ({int x, int y})? cursorToDevice(int deviceW, int deviceH) {
    final hwnd = findEmulatorHwnd();
    if (hwnd == null) return null;

    final pt = calloc<POINT>();
    GetCursorPos(pt);
    ScreenToClient(hwnd, pt);

    final client = calloc<RECT>();
    GetClientRect(hwnd, client);
    final cw = (client.ref.right - client.ref.left).toDouble();
    final ch = (client.ref.bottom - client.ref.top).toDouble();
    calloc.free(client);

    if (cw <= 0 || ch <= 0) {
      calloc.free(pt);
      return null;
    }

    final lx = pt.ref.x.toDouble();
    final ly = pt.ref.y.toDouble();
    calloc.free(pt);

    if (lx < 0 || ly < 0 || lx > cw || ly > ch) return null;

    return EmulatorCoords.mapTapToDevice(
      local: Offset(lx, ly),
      boxW: cw,
      boxH: ch,
      deviceW: deviceW,
      deviceH: deviceH,
    );
  }

  bool isEmulatorForeground() {
    final hwnd = findEmulatorHwnd();
    return hwnd != null && GetForegroundWindow() == hwnd;
  }

  bool isLeftButtonDown() => (GetAsyncKeyState(VK_LBUTTON) & 0x8000) != 0;

  bool isRightButtonDown() => (GetAsyncKeyState(VK_RBUTTON) & 0x8000) != 0;
}
