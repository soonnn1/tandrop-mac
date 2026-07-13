#include "flutter_window.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <climits>
#include <memory>
#include <optional>

#include <dwmapi.h>

#include "desktop_multi_window/desktop_multi_window_plugin.h"
#include "flutter/generated_plugin_registrant.h"

namespace {

struct SendCardWindowSearch {
  HWND view = nullptr;
  DWORD process_id = 0;
  HWND best = nullptr;
  LONG best_area = LONG_MAX;
};

BOOL CALLBACK FindSendCardTopLevelWindow(HWND window, LPARAM parameter) {
  auto* search = reinterpret_cast<SendCardWindowSearch*>(parameter);
  DWORD window_process_id = 0;
  ::GetWindowThreadProcessId(window, &window_process_id);
  if (window_process_id != search->process_id) {
    return TRUE;
  }

  if (window != search->view && !::IsChild(window, search->view)) {
    return TRUE;
  }

  RECT bounds{};
  if (!::GetWindowRect(window, &bounds)) {
    return TRUE;
  }

  const LONG width = bounds.right - bounds.left;
  const LONG height = bounds.bottom - bounds.top;
  const LONG area = width * height;
  if (width > 0 && height > 0 && area < search->best_area) {
    search->best = window;
    search->best_area = area;
  }

  return TRUE;
}

HWND FindTopLevelWindowForView(HWND view) {
  HWND fallback = ::GetAncestor(view, GA_ROOT);
  DWORD process_id = 0;
  ::GetWindowThreadProcessId(view, &process_id);

  SendCardWindowSearch search;
  search.view = view;
  search.process_id = process_id;
  search.best = fallback;
  if (fallback != nullptr) {
    RECT bounds{};
    if (::GetWindowRect(fallback, &bounds)) {
      search.best_area =
          (bounds.right - bounds.left) * (bounds.bottom - bounds.top);
    }
  }

  ::EnumWindows(FindSendCardTopLevelWindow,
                reinterpret_cast<LPARAM>(&search));
  return search.best;
}

bool ApplyRoundedRegion(HWND window, int logical_radius) {
  RECT bounds{};
  if (window == nullptr || !::GetWindowRect(window, &bounds)) {
    return false;
  }

  const UINT dpi = ::GetDpiForWindow(window);
  const int radius = ::MulDiv(logical_radius, dpi, 96);
  const int width = bounds.right - bounds.left;
  const int height = bounds.bottom - bounds.top;
  HRGN region = ::CreateRoundRectRgn(0, 0, width + 1, height + 1,
                                     radius * 2, radius * 2);
  if (region == nullptr) {
    return false;
  }

  if (!::SetWindowRgn(window, region, TRUE)) {
    ::DeleteObject(region);
    return false;
  }

  // SetWindowRgn 成功后由系统接管 region 的生命周期。
  return true;
}

// 仅服务于 Windows 独立发送卡片：对真实顶层 HWND 做圆角裁剪。
// Flutter 透明背景无法裁掉桌面多窗口插件创建的矩形原生窗口。
class TanDropSendCardWindowPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(
      flutter::PluginRegistrarWindows* registrar) {
    auto plugin = std::make_unique<TanDropSendCardWindowPlugin>(registrar);
    auto* plugin_pointer = plugin.get();
    plugin->channel_ =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), "tandrop/windows_send_card_native",
            &flutter::StandardMethodCodec::GetInstance());
    plugin->channel_->SetMethodCallHandler(
        [plugin_pointer](const auto& call, auto result) {
          plugin_pointer->HandleMethodCall(call, std::move(result));
        });
    registrar->AddPlugin(std::move(plugin));
  }

  explicit TanDropSendCardWindowPlugin(
      flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar) {}

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (call.method_name() != "setRoundedRegion") {
      result->NotImplemented();
      return;
    }

    int logical_radius = 34;
    if (const auto* arguments = call.arguments()) {
      if (const auto* value = std::get_if<int32_t>(arguments)) {
        logical_radius = *value;
      } else if (const auto* value64 = std::get_if<int64_t>(arguments)) {
        logical_radius = static_cast<int>(*value64);
      }
    }

    HWND view = registrar_->GetView()->GetNativeWindow();
    HWND window = FindTopLevelWindowForView(view);
    if (window == nullptr) {
      result->Error("WINDOW_UNAVAILABLE",
                    "Unable to locate the send card window.");
      return;
    }

    if (!ApplyRoundedRegion(window, logical_radius)) {
      result->Error("REGION_FAILED", "Unable to apply rounded window region.");
      return;
    }
    // desktop_multi_window 是“顶层窗口 + Flutter 子窗口”两层 HWND。
    // 只裁顶层时，Flutter 子窗口的矩形表面仍可能在四角露出来。
    ApplyRoundedRegion(view, logical_radius);

    // 关闭 DWM 额外的系统小圆角，避免它与 Flutter/SetWindowRgn
    // 的自定义圆角叠加后露出四角底色。
    constexpr DWORD kWindowCornerPreference = 33;
    constexpr int kDoNotRoundCornerPreference = 1;
    const int corner_preference = kDoNotRoundCornerPreference;
    ::DwmSetWindowAttribute(window, kWindowCornerPreference, &corner_preference,
                            sizeof(corner_preference));

    // 强制 Windows 刷新已经显示的顶层窗口，避免保留旧的矩形表面。
    ::SetWindowPos(window, nullptr, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                       SWP_FRAMECHANGED);
    ::RedrawWindow(window, nullptr, nullptr,
                   RDW_INVALIDATE | RDW_FRAME | RDW_ALLCHILDREN | RDW_UPDATENOW);

    result->Success();
  }

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

void RegisterTanDropWindowPlugin(flutter::FlutterEngine* engine) {
  FlutterDesktopPluginRegistrarRef registrar_ref =
      engine->GetRegistrarForPlugin("TanDropSendCardWindowPlugin");
  auto* registrar = flutter::PluginRegistrarManager::GetInstance()
                        ->GetRegistrar<flutter::PluginRegistrarWindows>(
                            registrar_ref);
  TanDropSendCardWindowPlugin::RegisterWithRegistrar(registrar);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterTanDropWindowPlugin(flutter_controller_->engine());
  DesktopMultiWindowSetWindowCreatedCallback([](void *controller) {
    auto *flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController *>(controller);
    RegisterPlugins(flutter_view_controller->engine());
    RegisterTanDropWindowPlugin(flutter_view_controller->engine());
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_CLOSE) {
    // 主窗口点击叉叉时先在 Win32 层同步隐藏，再让 Dart
    // 保存布局并决定驻留托盘或退出，避免异步通道导致关闭延迟。
    ::ShowWindow(hwnd, SW_HIDE);
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
