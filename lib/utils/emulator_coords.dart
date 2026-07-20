import 'dart:ui';

class EmulatorCoords {
  const EmulatorCoords._();

  static ({double renderW, double renderH, double offsetX, double offsetY}) layout({
    required double boxW,
    required double boxH,
    required int deviceW,
    required int deviceH,
  }) {
    final imageAspect = deviceW / deviceH;
    final boxAspect = boxW / boxH;
    if (imageAspect > boxAspect) {
      final renderW = boxW;
      final renderH = boxW / imageAspect;
      return (renderW: renderW, renderH: renderH, offsetX: 0, offsetY: (boxH - renderH) / 2);
    }
    final renderH = boxH;
    final renderW = boxH * imageAspect;
    return (renderW: renderW, renderH: renderH, offsetX: (boxW - renderW) / 2, offsetY: 0);
  }

  static ({int x, int y})? mapTapToDevice({
    required Offset local,
    required double boxW,
    required double boxH,
    required int deviceW,
    required int deviceH,
  }) {
    final l = layout(boxW: boxW, boxH: boxH, deviceW: deviceW, deviceH: deviceH);
    if (l.renderW <= 0 || l.renderH <= 0) return null;

    final rx = (local.dx - l.offsetX).clamp(0.0, l.renderW);
    final ry = (local.dy - l.offsetY).clamp(0.0, l.renderH);
    return (
      x: (rx / l.renderW * deviceW).round(),
      y: (ry / l.renderH * deviceH).round(),
    );
  }
}
