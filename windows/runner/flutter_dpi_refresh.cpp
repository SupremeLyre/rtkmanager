#include "flutter_dpi_refresh.h"

#include <wtsapi32.h>

#include <utility>

namespace {
constexpr UINT kRefreshMessage = WM_APP + 0x3A0;
constexpr UINT kRefreshIntervalMs = 250;
constexpr unsigned int kRefreshChecks = 8;
}  // namespace

FlutterDpiRefresh::FlutterDpiRefresh(std::function<void(UINT)> refresh_plugins)
    : refresh_plugins_(std::move(refresh_plugins)) {}

FlutterDpiRefresh::~FlutterDpiRefresh() {
  Stop();
}

void FlutterDpiRefresh::Start(HWND window, HWND flutter_view) {
  Stop();
  window_ = window;
  flutter_view_ = flutter_view;
  registered_ =
      WTSRegisterSessionNotification(window_, NOTIFY_FOR_THIS_SESSION) != FALSE;
  minimized_ = IsIconic(window_) != FALSE;
  Schedule();
}

void FlutterDpiRefresh::Stop() {
  if (window_) {
    KillTimer(window_, reinterpret_cast<UINT_PTR>(this));
    if (registered_) {
      WTSUnRegisterSessionNotification(window_);
    }
  }
  window_ = nullptr;
  flutter_view_ = nullptr;
  registered_ = false;
  posted_ = false;
  remaining_checks_ = 0;
}

bool FlutterDpiRefresh::HandleMessage(UINT message, WPARAM wparam) {
  if (!window_) {
    return false;
  }
  switch (message) {
    case kRefreshMessage:
      posted_ = false;
      Refresh();
      return true;
    case WM_TIMER:
      if (wparam != reinterpret_cast<UINT_PTR>(this)) {
        return false;
      }
      if (remaining_checks_ > 0) {
        Refresh();
        if (--remaining_checks_ == 0) {
          KillTimer(window_, reinterpret_cast<UINT_PTR>(this));
        }
      }
      return true;
    case WM_DPICHANGED:
    case WM_DISPLAYCHANGE:
    case WM_SETTINGCHANGE:
      Schedule();
      break;
    case WM_WTSSESSION_CHANGE:
      if (wparam == WTS_CONSOLE_CONNECT || wparam == WTS_REMOTE_CONNECT ||
          wparam == WTS_REMOTE_DISCONNECT || wparam == WTS_SESSION_UNLOCK ||
          wparam == WTS_SESSION_DESKTOP_READY) {
        Schedule();
      }
      break;
    case WM_ACTIVATEAPP:
      if (wparam) {
        Schedule();
      }
      break;
    case WM_SIZE:
      if (minimized_ && wparam != SIZE_MINIMIZED) {
        Schedule();
      }
      minimized_ = wparam == SIZE_MINIMIZED;
      break;
  }
  return false;
}

void FlutterDpiRefresh::Schedule() {
  // Defer until the parent/plugins have applied WM_DPICHANGED's suggested rect.
  // RDP display metrics can settle later than the session notification. Recheck
  // for two seconds, then stop; there is no permanent polling timer.
  if (!posted_) {
    posted_ = PostMessage(window_, kRefreshMessage, 0, 0) != FALSE;
  }
  remaining_checks_ = kRefreshChecks;
  SetTimer(window_, reinterpret_cast<UINT_PTR>(this), kRefreshIntervalMs, nullptr);
}

void FlutterDpiRefresh::Refresh() {
  RECT client{};
  if (!IsWindow(flutter_view_) || IsIconic(window_) ||
      !GetClientRect(window_, &client) || client.right <= 0 || client.bottom <= 0) {
    return;
  }

  // Flutter 3.41 caches GetDpiForWindow on BEFOREPARENT, but only publishes
  // pixel_ratio to Dart on WM_SIZE. Both are required even if the physical
  // client size did not change (for example when returning to a maximized app).
  SendMessage(flutter_view_, WM_DPICHANGED_BEFOREPARENT, 0, 0);
  refresh_plugins_(GetDpiForWindow(window_));
  MoveWindow(flutter_view_, 0, 0, client.right, client.bottom, FALSE);
  SendMessage(flutter_view_, WM_SIZE, SIZE_RESTORED,
              MAKELPARAM(client.right, client.bottom));
  InvalidateRect(flutter_view_, nullptr, FALSE);
}
