import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import '../../models/max_account.dart';
import '../../services/account_map_preview_service.dart';
import '../../services/browser_session_manager.dart';
import '../../services/fingerprint_bridge.dart';
import '../../services/session_inject_bridge.dart';
import '../../services/storage_service.dart';
import '../../services/token_capture_bridge.dart';
import '../../services/webview_environment_coordinator.dart';

/// Loads one shared WebView2 instance for the account currently in the map rotation.
/// The [Webview] widget is rendered inside the active card, not offscreen.
class MapWebCaptureHost extends StatefulWidget {
  const MapWebCaptureHost({super.key});

  @override
  State<MapWebCaptureHost> createState() => _MapWebCaptureHostState();
}

class _MapWebCaptureHostState extends State<MapWebCaptureHost> {
  WebviewController? _controller;
  String? _loadedAccountId;
  bool _loading = false;
  StreamSubscription<LoadingState>? _loadingSub;
  StreamSubscription<WebErrorStatus>? _errorSub;
  late final Future<void> Function() _releaseCallback;

  @override
  void initState() {
    super.initState();
    _releaseCallback = _releaseForCoordinator;
    WebviewEnvironmentCoordinator.instance.registerReleaseCallback(_releaseCallback);
  }

  Future<void> _releaseForCoordinator() async {
    await _disposeController();
  }

  @override
  void dispose() {
    WebviewEnvironmentCoordinator.instance.unregisterReleaseCallback(_releaseCallback);
    unawaited(_disposeController());
    super.dispose();
  }

  Future<void> _disposeController() async {
    await _loadingSub?.cancel();
    await _errorSub?.cancel();
    _loadingSub = null;
    _errorSub = null;
    final controller = _controller;
    _controller = null;
    _loadedAccountId = null;
    if (controller != null) {
      await controller.dispose();
      WebviewEnvironmentCoordinator.instance.notifyControllerDisposed();
    }
    if (mounted) {
      context.read<AccountMapPreviewService>().setWebController(null);
    }
  }

  Future<void> _loadAccount(MaxAccount account) async {
    if (_loading) return;
    if (_loadedAccountId == account.id && _controller?.value.isInitialized == true) {
      context.read<AccountMapPreviewService>().reportWebLoaded(account.id);
      return;
    }

    _loading = true;
    final previews = context.read<AccountMapPreviewService>();

    try {
      await _disposeController();

      final profilePath = StorageService.instance.profileDirFor(account.id).path;
      await WebviewEnvironmentCoordinator.instance.ensureEnvironment(
        userDataPath: profilePath,
        additionalArguments: account.isolation.chromiumArguments(),
      );

      final webview = WebviewController();
      WebviewEnvironmentCoordinator.instance.notifyControllerCreated();
      try {
        await webview.initialize();
      } catch (e) {
        WebviewEnvironmentCoordinator.instance.notifyControllerDisposed();
        rethrow;
      }
      await webview.addScriptToExecuteOnDocumentCreated(
        FingerprintBridge.documentScript(account.isolation),
      );
      if (account.hasApiSession) {
        await webview.addScriptToExecuteOnDocumentCreated(
          SessionInjectBridge.documentScript(
            token: account.apiToken!,
            deviceId: account.webDeviceId,
            viewerId: account.viewerId,
          ),
        );
      }
      await webview.addScriptToExecuteOnDocumentCreated(TokenCaptureBridge.documentScript());

      if (!mounted) {
        await webview.dispose();
        WebviewEnvironmentCoordinator.instance.notifyControllerDisposed();
        return;
      }

      _controller = webview;
      _loadedAccountId = account.id;
      previews.setWebController(webview);

      _loadingSub = webview.loadingState.listen((state) {
        if (!mounted || _loadedAccountId != account.id) return;
        if (state == LoadingState.navigationCompleted) {
          context.read<AccountMapPreviewService>().reportWebLoaded(account.id);
        }
      });
      _errorSub = webview.onLoadError.listen((_) {
        if (!mounted || _loadedAccountId != account.id) return;
        context.read<AccountMapPreviewService>().reportWebFailed(
              account.id,
              'Ошибка загрузки web.max.ru',
            );
      });

      await webview.loadUrl(BrowserSessionManager.maxUrl);
    } catch (e) {
      if (_controller != null) {
        await _controller!.dispose();
        WebviewEnvironmentCoordinator.instance.notifyControllerDisposed();
      }
      _controller = null;
      _loadedAccountId = null;
      previews.setWebController(null);
      previews.reportWebFailed(
        account.id,
        e.toString().replaceFirst('PlatformException: ', '').replaceFirst('Exception: ', ''),
      );
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final previews = context.watch<AccountMapPreviewService>();
    final targetId = previews.webLiveAccountId;

    if (targetId == null) {
      if (_controller != null && !_loading) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _disposeController());
      }
    } else if (targetId != _loadedAccountId && !_loading) {
      final account = previews.accountById(targetId);
      if (account != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _loadAccount(account));
      }
    }

    return const SizedBox.shrink();
  }
}
