import 'package:flutter/material.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import '../../services/account_map_preview_service.dart';
import '../../utils/phone_viewport.dart';

class PhoneScreenPreview extends StatelessWidget {
  const PhoneScreenPreview({
    super.key,
    required this.mode,
    required this.preview,
    required this.deviceW,
    required this.deviceH,
    this.liveController,
    this.isLive = false,
  });

  final AccountCardViewMode mode;
  final AccountScreenPreview preview;
  final int deviceW;
  final int deviceH;
  final WebviewController? liveController;
  final bool isLive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bezel = theme.colorScheme.outline.withValues(alpha: 0.55);
    final screen = PhoneViewport.displaySize(deviceW, deviceH);

    return Container(
      width: screen.width + 12,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: bezel, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 4,
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
              color: bezel,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: screen.width,
              height: screen.height,
              child: _ScreenContent(
                mode: mode,
                preview: preview,
                liveController: liveController,
                isLive: isLive,
                screenWidth: screen.width,
                screenHeight: screen.height,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '$deviceW×$deviceH',
            style: TextStyle(fontSize: 8, color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 2),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: bezel.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(99),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScreenContent extends StatelessWidget {
  const _ScreenContent({
    required this.mode,
    required this.preview,
    required this.liveController,
    required this.isLive,
    required this.screenWidth,
    required this.screenHeight,
  });

  final AccountCardViewMode mode;
  final AccountScreenPreview preview;
  final WebviewController? liveController;
  final bool isLive;
  final double screenWidth;
  final double screenHeight;

  @override
  Widget build(BuildContext context) {
    if (mode == AccountCardViewMode.web && isLive && liveController != null) {
      final controller = liveController!;
      if (!controller.value.isInitialized) {
        return const _LoadingPane(label: 'Запуск web…');
      }
      return Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: const Color(0xFF0A0A0A)),
          Webview(
            controller,
            width: screenWidth,
            height: screenHeight,
          ),
          const Positioned(
            left: 4,
            top: 4,
            child: _SourceBadge(label: 'web live', icon: Icons.language),
          ),
        ],
      );
    }

    if (preview.hasImage) {
      return Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Color(0xFF0A0A0A)),
          Center(
            child: Image.memory(
              preview.bytes!,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          ),
          Positioned(
            left: 4,
            top: 4,
            child: _SourceBadge(
              label: mode == AccountCardViewMode.emulator ? 'эмулятор' : 'web',
              icon: mode == AccountCardViewMode.emulator ? Icons.phone_android : Icons.language,
            ),
          ),
        ],
      );
    }

    if (preview.loading || (mode == AccountCardViewMode.web && isLive)) {
      return _LoadingPane(
        label: mode == AccountCardViewMode.web ? 'Загрузка web…' : 'Загрузка…',
      );
    }

    if (preview.error != null) {
      return _Placeholder(
        icon: mode == AccountCardViewMode.emulator ? Icons.phone_android : Icons.language,
        label: preview.error!,
        tone: Colors.orangeAccent,
      );
    }

    if (preview.webLoaded && mode == AccountCardViewMode.web) {
      return const _Placeholder(
        icon: Icons.check_circle_outline,
        label: 'Web загружен\nобновится в очереди',
        tone: Colors.greenAccent,
      );
    }

    if (preview.statusMessage != null) {
      return _Placeholder(
        icon: Icons.hourglass_bottom,
        label: preview.statusMessage!,
        tone: Theme.of(context).colorScheme.primary,
      );
    }

    return _Placeholder(
      icon: Icons.hourglass_empty,
      label: 'Ожидание…',
      tone: Theme.of(context).colorScheme.primary,
    );
  }
}

class _LoadingPane extends StatelessWidget {
  const _LoadingPane({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF10131A),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: 6),
            Text(label, style: const TextStyle(fontSize: 9, color: Colors.white54)),
          ],
        ),
      ),
    );
  }
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 10, color: Colors.white70),
            const SizedBox(width: 3),
            Text(label, style: const TextStyle(fontSize: 8, color: Colors.white70)),
          ],
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.icon,
    required this.label,
    required this.tone,
  });

  final IconData icon;
  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF10131A),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: tone, size: 24),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 9, color: tone.withValues(alpha: 0.9), height: 1.15),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
