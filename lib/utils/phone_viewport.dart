import 'dart:ui';

/// Phone screen sizing for map cards (mobile aspect, not desktop browser size).
class PhoneViewport {
  PhoneViewport._();

  /// Typical mobile viewport for web.max.ru preview.
  static const int webDeviceW = 390;
  static const int webDeviceH = 844;

  static const double maxDisplayHeight = 320;
  static const double maxDisplayWidth = 184;

  static Size displaySize(int deviceW, int deviceH) {
    if (deviceW <= 0 || deviceH <= 0) {
      return const Size(maxDisplayWidth, maxDisplayHeight);
    }
    final aspect = deviceW / deviceH;
    var h = maxDisplayHeight;
    var w = h * aspect;
    if (w > maxDisplayWidth) {
      w = maxDisplayWidth;
      h = w / aspect;
    }
    return Size(w, h);
  }

  static Size webDisplaySize() => displaySize(webDeviceW, webDeviceH);

  static Size emulatorDisplaySize(int? deviceW, int? deviceH) {
    return displaySize(deviceW ?? 1080, deviceH ?? 2400);
  }
}
