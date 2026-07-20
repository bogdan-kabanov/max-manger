import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

typedef WebviewReleaseCallback = Future<void> Function();

/// Serializes WebView2 environment setup across the main browser and map previews.
///
/// WebView2 allows [WebviewController.initializeEnvironment] only while no
/// controller is alive. This coordinator releases every registered webview
/// before (re)configuring the shared environment.
class WebviewEnvironmentCoordinator {
  WebviewEnvironmentCoordinator._();

  static final WebviewEnvironmentCoordinator instance =
      WebviewEnvironmentCoordinator._();

  final List<WebviewReleaseCallback> _releaseCallbacks = [];
  int _aliveControllers = 0;
  String? _environmentPath;
  String? _environmentArgs;
  Future<void>? _pending;

  void registerReleaseCallback(WebviewReleaseCallback callback) {
    if (!_releaseCallbacks.contains(callback)) {
      _releaseCallbacks.add(callback);
    }
  }

  void unregisterReleaseCallback(WebviewReleaseCallback callback) {
    _releaseCallbacks.remove(callback);
  }

  void notifyControllerCreated() {
    _aliveControllers++;
  }

  void notifyControllerDisposed() {
    if (_aliveControllers > 0) {
      _aliveControllers--;
    }
  }

  Future<void> ensureEnvironment({
    required String userDataPath,
    String? additionalArguments,
  }) async {
    if (_pending != null) {
      await _pending;
    }

    final args = additionalArguments ?? '';
    final needsEnvChange =
        _environmentPath != userDataPath || _environmentArgs != args;

    if (!needsEnvChange && _aliveControllers == 0 && _environmentPath != null) {
      return;
    }

    final completer = Completer<void>();
    _pending = completer.future;

    try {
      if (_aliveControllers > 0 || needsEnvChange) {
        await _releaseAllControllers();
      }

      if (!needsEnvChange) {
        return;
      }

      await Directory(userDataPath).create(recursive: true);

      try {
        await WebviewController.initializeEnvironment(
          userDataPath: userDataPath,
          additionalArguments: additionalArguments,
        );
      } on PlatformException catch (e) {
        if (e.code != 'environment_already_initialized') {
          rethrow;
        }
        await _releaseAllControllers();
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await WebviewController.initializeEnvironment(
          userDataPath: userDataPath,
          additionalArguments: additionalArguments,
        );
      }

      _environmentPath = userDataPath;
      _environmentArgs = args;
    } finally {
      completer.complete();
      _pending = null;
    }
  }

  Future<void> _releaseAllControllers() async {
    for (final release in List<WebviewReleaseCallback>.from(_releaseCallbacks)) {
      await release();
    }

    for (var attempt = 0; attempt < 30 && _aliveControllers > 0; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
