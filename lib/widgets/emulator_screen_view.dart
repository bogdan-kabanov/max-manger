import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../utils/emulator_coords.dart';

class EmulatorStepMarker {
  const EmulatorStepMarker({
    required this.x,
    required this.y,
    this.x2,
    this.y2,
    this.color = Colors.orange,
  });

  final int x;
  final int y;
  final int? x2;
  final int? y2;
  final Color color;
}

class EmulatorScreenView extends StatefulWidget {
  const EmulatorScreenView({
    super.key,
    required this.png,
    required this.deviceW,
    required this.deviceH,
    required this.onPrimaryTap,
    required this.onPrimarySwipe,
    required this.onSecondaryTap,
    this.interactEnabled = true,
    this.highlight,
    this.pendingSwipeStart,
    this.markers = const [],
  });

  final Uint8List png;
  final int deviceW;
  final int deviceH;
  final void Function(int x, int y) onPrimaryTap;
  final void Function(int x1, int y1, int x2, int y2) onPrimarySwipe;
  final void Function(int x, int y, Offset globalPosition) onSecondaryTap;
  final bool interactEnabled;
  final ({int x, int y})? highlight;
  final ({int x, int y})? pendingSwipeStart;
  final List<EmulatorStepMarker> markers;

  @override
  State<EmulatorScreenView> createState() => _EmulatorScreenViewState();
}

class _EmulatorScreenViewState extends State<EmulatorScreenView> {
  Offset? _dragLocalStart;
  Offset? _dragLocalCurrent;
  int? _dragX1;
  int? _dragY1;

  ({int x, int y})? _map(Offset local, double boxW, double boxH) {
    return EmulatorCoords.mapTapToDevice(
      local: local,
      boxW: boxW,
      boxH: boxH,
      deviceW: widget.deviceW,
      deviceH: widget.deviceH,
    );
  }

  Offset? _deviceToLocal(int x, int y, double boxW, double boxH) {
    final layout = EmulatorCoords.layout(
      boxW: boxW,
      boxH: boxH,
      deviceW: widget.deviceW,
      deviceH: widget.deviceH,
    );
    if (layout.renderW <= 0 || layout.renderH <= 0) return null;
    return Offset(
      layout.offsetX + x / widget.deviceW * layout.renderW,
      layout.offsetY + y / widget.deviceH * layout.renderH,
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final boxW = constraints.maxWidth;
        final boxH = constraints.maxHeight;

        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: !widget.interactEnabled
              ? null
              : (e) {
                  final mapped = _map(e.localPosition, boxW, boxH);
                  if (mapped == null) return;

                  if (e.buttons == kSecondaryMouseButton) {
                    widget.onSecondaryTap(mapped.x, mapped.y, e.position);
                    return;
                  }

                  if (e.buttons == kPrimaryMouseButton) {
                    setState(() {
                      _dragLocalStart = e.localPosition;
                      _dragLocalCurrent = e.localPosition;
                      _dragX1 = mapped.x;
                      _dragY1 = mapped.y;
                    });
                  }
                },
          onPointerMove: !widget.interactEnabled
              ? null
              : (e) {
                  if (_dragLocalStart == null) return;
                  if ((e.buttons & kPrimaryMouseButton) == 0) return;
                  setState(() => _dragLocalCurrent = e.localPosition);
                },
          onPointerUp: !widget.interactEnabled
              ? null
              : (e) {
                  if (_dragLocalStart == null || _dragX1 == null || _dragY1 == null) return;
                  final mapped = _map(e.localPosition, boxW, boxH);
                  setState(() {
                    _dragLocalStart = null;
                    _dragLocalCurrent = null;
                  });
                  if (mapped == null) return;

                  final dx = mapped.x - _dragX1!;
                  final dy = mapped.y - _dragY1!;
                  if (dx * dx + dy * dy < 400) {
                    widget.onPrimaryTap(_dragX1!, _dragY1!);
                  } else {
                    widget.onPrimarySwipe(_dragX1!, _dragY1!, mapped.x, mapped.y);
                  }
                  _dragX1 = null;
                  _dragY1 = null;
                },
          onPointerCancel: (_) {
            setState(() {
              _dragLocalStart = null;
              _dragLocalCurrent = null;
              _dragX1 = null;
              _dragY1 = null;
            });
          },
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black,
                    border: Border.all(color: Theme.of(context).dividerColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    child: Image.memory(widget.png, fit: BoxFit.contain),
                  ),
                ),
              ),
              if (_dragLocalStart != null && _dragLocalCurrent != null)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _DragLinePainter(
                      start: _dragLocalStart!,
                      end: _dragLocalCurrent!,
                    ),
                  ),
                ),
              for (final m in widget.markers) ...[
                if (_deviceToLocal(m.x, m.y, boxW, boxH) case final start?)
                  Positioned(
                    left: start.dx - 6,
                    top: start.dy - 6,
                    child: _Dot(color: m.color),
                  ),
                if (m.x2 != null && m.y2 != null)
                  if (_deviceToLocal(m.x, m.y, boxW, boxH) case final start?)
                    if (_deviceToLocal(m.x2!, m.y2!, boxW, boxH) case final end?)
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _SwipeMarkerPainter(start: start, end: end, color: m.color),
                        ),
                      ),
              ],
              if (widget.pendingSwipeStart case final p?)
                if (_deviceToLocal(p.x, p.y, boxW, boxH) case final offset?)
                  Positioned(
                    left: offset.dx - 8,
                    top: offset.dy - 8,
                    child: const _Dot(color: Colors.greenAccent, size: 16),
                  ),
              if (widget.highlight case final h?)
                if (_deviceToLocal(h.x, h.y, boxW, boxH) case final offset?)
                  Positioned(
                    left: offset.dx - 10,
                    top: offset.dy - 10,
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.45),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.red, width: 2),
                      ),
                    ),
                  ),
            ],
          ),
        );
      },
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, this.size = 12});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
    );
  }
}

class _DragLinePainter extends CustomPainter {
  _DragLinePainter({required this.start, required this.end});

  final Offset start;
  final Offset end;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.cyanAccent.withValues(alpha: 0.85)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(start, end, paint);
    canvas.drawCircle(start, 6, paint..style = PaintingStyle.fill);
    canvas.drawCircle(end, 6, paint);
  }

  @override
  bool shouldRepaint(covariant _DragLinePainter old) =>
      old.start != start || old.end != end;
}

class _SwipeMarkerPainter extends CustomPainter {
  _SwipeMarkerPainter({required this.start, required this.end, required this.color});

  final Offset start;
  final Offset end;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.75)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(start, end, paint);
  }

  @override
  bool shouldRepaint(covariant _SwipeMarkerPainter old) =>
      old.start != start || old.end != end || old.color != color;
}
