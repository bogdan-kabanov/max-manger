import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/macro_step.dart';
import '../models/max_account.dart';
import '../providers/app_state.dart';
import '../services/emulator_service.dart';

class EmulatorCoordPickerDialog extends StatefulWidget {
  const EmulatorCoordPickerDialog({super.key, required this.account});

  final MaxAccount account;

  static Future<MacroStep?> show(BuildContext context, {required MaxAccount account}) {
    return showDialog<MacroStep>(
      context: context,
      barrierDismissible: false,
      builder: (_) => EmulatorCoordPickerDialog(account: account),
    );
  }

  @override
  State<EmulatorCoordPickerDialog> createState() => _EmulatorCoordPickerDialogState();
}

class _EmulatorCoordPickerDialogState extends State<EmulatorCoordPickerDialog> {
  final _emu = EmulatorService.instance;

  Uint8List? _png;
  String? _error;
  bool _loading = true;
  int _deviceW = 1080;
  int _deviceH = 2400;
  int? _pickedX;
  int? _pickedY;
  String? _adb;
  String? _serial;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _pickedX = null;
      _pickedY = null;
    });

    try {
      final sdk = await _emu.detectSdk();
      if (!sdk.available || sdk.adbPath == null) {
        throw StateError('Android SDK не найден');
      }
      _adb = sdk.adbPath;
      _serial = await _emu.resolveSerial(widget.account);
      if (!widget.account.emulator.isConfigured && mounted) {
        final avdName = widget.account.emulator.avdName ?? _emu.defaultAvdName(widget.account);
        await context.read<AppState>().updateAccountEmulator(
              widget.account,
              widget.account.emulator.copyWith(
                avdName: avdName,
                createdAt: widget.account.emulator.createdAt ?? DateTime.now(),
              ),
            );
      }
      final size = await _emu.getDisplaySize(_adb!, _serial!);
      _deviceW = size.$1;
      _deviceH = size.$2;
      final bytes = await _emu.captureScreenshot(_adb!, _serial!);
      if (bytes == null || bytes.isEmpty) {
        throw StateError('Не удалось получить скриншот эмулятора');
      }
      if (!mounted) return;
      setState(() {
        _png = bytes;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _onTapImage(Offset local, double boxW, double boxH) {
    final imageAspect = _deviceW / _deviceH;
    final boxAspect = boxW / boxH;
    late final double renderW;
    late final double renderH;
    late final double offsetX;
    late final double offsetY;

    if (imageAspect > boxAspect) {
      renderW = boxW;
      renderH = boxW / imageAspect;
      offsetX = 0;
      offsetY = (boxH - renderH) / 2;
    } else {
      renderH = boxH;
      renderW = boxH * imageAspect;
      offsetX = (boxW - renderW) / 2;
      offsetY = 0;
    }

    final rx = (local.dx - offsetX).clamp(0.0, renderW);
    final ry = (local.dy - offsetY).clamp(0.0, renderH);
    if (renderW <= 0 || renderH <= 0) return;

    setState(() {
      _pickedX = (rx / renderW * _deviceW).round();
      _pickedY = (ry / renderH * _deviceH).round();
    });
  }

  MacroStep? _buildStep() {
    final x = _pickedX;
    final y = _pickedY;
    if (x == null || y == null) return null;
    return MacroStep(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      type: MacroStepType.emulatorTap,
      x: x,
      y: y,
      label: 'Тап ($x, $y)',
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Захват тапа в эмуляторе'),
      content: SizedBox(
        width: 420,
        child: _loading
            ? const SizedBox(
                height: 200,
                child: Center(child: CircularProgressIndicator()),
              )
            : _error != null
                ? Text(_error!, style: const TextStyle(color: Colors.red))
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Нажмите на экран эмулятора. Разрешение: $_deviceW×$_deviceH',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          const boxH = 480.0;
                          final boxW = constraints.maxWidth;
                          return GestureDetector(
                            onTapDown: (d) => _onTapImage(d.localPosition, boxW, boxH),
                            child: Stack(
                              children: [
                                SizedBox(
                                  width: boxW,
                                  height: boxH,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      border: Border.all(color: Colors.grey.shade600),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(7),
                                      child: Image.memory(_png!, fit: BoxFit.contain),
                                    ),
                                  ),
                                ),
                                if (_pickedX != null && _pickedY != null)
                                  Positioned(
                                    left: 8,
                                    bottom: 8,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: Colors.black87,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        child: Text(
                                          'X: $_pickedX, Y: $_pickedY',
                                          style: const TextStyle(color: Colors.white, fontSize: 12),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        TextButton(onPressed: _loading ? null : _load, child: const Text('Обновить')),
        FilledButton(
          onPressed: _buildStep() == null ? null : () => Navigator.pop(context, _buildStep()),
          child: const Text('Добавить тап'),
        ),
      ],
    );
  }
}
