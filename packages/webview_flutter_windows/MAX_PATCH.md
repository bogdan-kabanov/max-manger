# MAX Desktop patch

`windows/webview_platform.cc`: do not abort platform init when
`CreateDispatcherQueueController` fails.

Secondary Flutter engines created by `desktop_multi_window` share the main UI
thread. A DispatcherQueue may already exist there, so a second WebView plugin
instance used to fail with `PlatformException(unsupported_platform, The platform
is not supported)`. Graphics Capture only needs a queue on the thread; owning a
new controller is optional.
