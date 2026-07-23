#pragma once

#include <WebView2.h>
#include <WebView2EnvironmentOptions.h>
#include <wil/com.h>

#include <functional>
#include <optional>
#include <string>

#include "graphics_context.h"
#include "webview.h"
#include "webview_platform.h"
#include "windows.ui.composition.h"

struct WebviewCreationError {
  HRESULT hr;
  std::string message;

  explicit WebviewCreationError(HRESULT hr, std::string message)
      : hr(hr), message(message) {}

  static std::unique_ptr<WebviewCreationError> create(
      HRESULT hr, const std::string message) {
    return std::make_unique<WebviewCreationError>(hr, message);
  }
};

class WebviewHost {
 public:
  typedef std::function<void(std::unique_ptr<Webview>,
                             std::unique_ptr<WebviewCreationError>)>
      WebviewCreationCallback;
  typedef std::function<void(wil::com_ptr<ICoreWebView2CompositionController>,
                             std::unique_ptr<WebviewCreationError>)>
      CompositionControllerCreationCallback;
  typedef std::function<void(wil::com_ptr<ICoreWebView2PointerInfo>,
                             std::unique_ptr<WebviewCreationError>)>
      PointerInfoCreationCallback;

  static std::unique_ptr<WebviewHost> Create(
      WebviewPlatform* platform,
      std::optional<std::wstring> user_data_directory = std::nullopt,
      std::optional<std::wstring> browser_exe_path = std::nullopt,
      std::optional<std::string> arguments = std::nullopt);

  void CreateWebview(HWND hwnd, HWND flutter_view_hwnd, bool offscreen_only,
                     bool owns_window, WebviewCreationCallback callback);

  void CreateWebViewPointerInfo(PointerInfoCreationCallback cb);

  winrt::com_ptr<ABI::Windows::UI::Composition::ICompositor> compositor()
      const {
    return compositor_;
  }

  const std::wstring& proxy_username() const { return proxy_username_; }
  const std::wstring& proxy_password() const { return proxy_password_; }
  bool has_proxy_credentials() const {
    return !proxy_username_.empty() || !proxy_password_.empty();
  }

 private:
  winrt::com_ptr<ABI::Windows::UI::Composition::ICompositor> compositor_;
  wil::com_ptr<ICoreWebView2Environment3> webview_env_;
  std::wstring proxy_username_;
  std::wstring proxy_password_;

  WebviewHost(WebviewPlatform* platform,
              wil::com_ptr<ICoreWebView2Environment3> webview_env,
              std::wstring proxy_username, std::wstring proxy_password);
  void CreateWebViewCompositionController(
      HWND hwnd, CompositionControllerCreationCallback cb);
};
