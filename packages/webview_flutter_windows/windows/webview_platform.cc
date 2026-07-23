#include "webview_platform.h"

#include <DispatcherQueue.h>
#include <shlobj.h>
#include <windows.graphics.capture.h>

#include <filesystem>
#include <iostream>

WebviewPlatform::WebviewPlatform()
    : rohelper_(std::make_unique<rx::RoHelper>(RO_INIT_SINGLETHREADED)) {
  if (rohelper_->WinRtAvailable()) {
    DispatcherQueueOptions options{sizeof(DispatcherQueueOptions),
                                   DQTYPE_THREAD_CURRENT, DQTAT_COM_STA};

    // CreateDispatcherQueueController may only run once per thread. Secondary
    // Flutter engines from desktop_multi_window share the main UI thread, so
    // the second WebView plugin instance fails here even though a queue
    // already exists and Graphics Capture can use it.
    const HRESULT dq_hr = rohelper_->CreateDispatcherQueueController(
        options, dispatcher_queue_controller_.put());
    if (FAILED(dq_hr)) {
      std::cerr << "Creating DispatcherQueueController failed (0x" << std::hex
                << dq_hr
                << "); continuing with the existing thread DispatcherQueue."
                << std::endl;
    }

    if (!IsGraphicsCaptureSessionSupported()) {
      std::cerr << "Windows::Graphics::Capture::GraphicsCaptureSession is not "
                   "supported."
                << std::endl;
      return;
    }

    graphics_context_ = std::make_unique<GraphicsContext>(rohelper_.get());
    valid_ = graphics_context_->IsValid();
  }
}

bool WebviewPlatform::IsGraphicsCaptureSessionSupported() {
  HSTRING className;
  HSTRING_HEADER classNameHeader;

  if (FAILED(rohelper_->GetStringReference(
          RuntimeClass_Windows_Graphics_Capture_GraphicsCaptureSession,
          &className, &classNameHeader))) {
    return false;
  }

  winrt::com_ptr<
      ABI::Windows::Graphics::Capture::IGraphicsCaptureSessionStatics>
      capture_session_statics;
  if (FAILED(rohelper_->GetActivationFactory(
          className,
          __uuidof(
              ABI::Windows::Graphics::Capture::IGraphicsCaptureSessionStatics),
          capture_session_statics.put_void()))) {
    return false;
  }

  boolean is_supported = false;
  if (FAILED(capture_session_statics->IsSupported(&is_supported))) {
    return false;
  }

  return !!is_supported;
}

std::optional<std::wstring> WebviewPlatform::GetDefaultDataDirectory() {
  PWSTR path_tmp;
  if (!SUCCEEDED(
          SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &path_tmp))) {
    return std::nullopt;
  }
  auto path = std::filesystem::path(path_tmp);
  CoTaskMemFree(path_tmp);

  wchar_t filename[MAX_PATH];
  GetModuleFileName(nullptr, filename, MAX_PATH);
  path /= "flutter_webview_windows";
  path /= std::filesystem::path(filename).stem();

  return path.wstring();
}
