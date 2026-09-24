#include "../flutter_dpi_refresh.h"

#include <wtsapi32.h>

#include <cstdlib>
#include <iostream>
#include <vector>

namespace {
constexpr wchar_t kWindowClass[] = L"RTKManagerDpiRefreshTest";

void Check(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    std::exit(1);
  }
}

void PumpMessages(DWORD duration_ms = 0) {
  const ULONGLONG until = GetTickCount64() + duration_ms;
  do {
    MSG message;
    while (PeekMessage(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessage(&message);
    }
    if (GetTickCount64() >= until) {
      break;
    }
    Sleep(10);
  } while (true);
}

struct Fixture {
  HWND owner = nullptr;
  HWND child = nullptr;
  UINT cached_dpi = 0;
  UINT published_dpi = 0;
  UINT plugin_dpi = 0;
  LONG published_width = 0;
  LONG published_height = 0;
  int refresh_count = 0;
  std::vector<char> order;
  FlutterDpiRefresh refresh{[this](UINT dpi) {
    plugin_dpi = dpi;
    order.push_back('P');
  }};

  Fixture() {
    owner = CreateWindowEx(0, kWindowClass, L"DPI test (hidden)",
                           WS_OVERLAPPEDWINDOW, 0, 0, 800, 600, nullptr, nullptr,
                           GetModuleHandle(nullptr), this);
    Check(owner != nullptr, "create hidden host");
    child = CreateWindowEx(0, kWindowClass, L"Flutter view stand-in", WS_CHILD,
                           0, 0, 100, 100, owner, nullptr,
                           GetModuleHandle(nullptr), this);
    Check(child != nullptr, "create hidden child");
    order.clear();
    refresh.Start(owner, child);
  }

  ~Fixture() {
    refresh.Stop();
    DestroyWindow(owner);
    PumpMessages();
  }

  void ExpectCurrentMetrics() const {
    RECT bounds{};
    GetClientRect(owner, &bounds);
    Check(published_dpi == GetDpiForWindow(child), "publish current child DPI");
    Check(plugin_dpi == GetDpiForWindow(owner), "refresh plugin DPI");
    Check(published_width == bounds.right && published_height == bounds.bottom,
          "publish current host client size");
    Check(order.size() >= 3 && order[0] == 'D' && order[1] == 'P',
          "refresh cached DPI before plugins/viewport");
  }

  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                     LPARAM lparam) {
    auto* fixture = reinterpret_cast<Fixture*>(
        GetWindowLongPtr(hwnd, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
      fixture = static_cast<Fixture*>(
          reinterpret_cast<CREATESTRUCT*>(lparam)->lpCreateParams);
      SetWindowLongPtr(hwnd, GWLP_USERDATA,
                       reinterpret_cast<LONG_PTR>(fixture));
    }
    if (fixture) {
      if (GetWindowLongPtr(hwnd, GWL_STYLE) & WS_CHILD) {
        // Same two-stage metrics handling as Flutter 3.41's native view.
        if (message == WM_DPICHANGED_BEFOREPARENT) {
          fixture->cached_dpi = GetDpiForWindow(hwnd);
          fixture->order.push_back('D');
          ++fixture->refresh_count;
          return 0;
        }
        if (message == WM_SIZE) {
          fixture->published_dpi = fixture->cached_dpi;
          fixture->published_width = LOWORD(lparam);
          fixture->published_height = HIWORD(lparam);
          fixture->order.push_back('S');
          return 0;
        }
      } else if (fixture->refresh.HandleMessage(message, wparam)) {
        return 0;
      }
    }
    return DefWindowProc(hwnd, message, wparam, lparam);
  }
};

void TestMetricsAndSessionRecovery() {
  Fixture f;
  Check(f.refresh_count == 0, "startup refresh is deferred");
  PumpMessages();
  f.ExpectCurrentMetrics();

  const WPARAM sessions[] = {WTS_REMOTE_DISCONNECT, WTS_CONSOLE_CONNECT,
                             WTS_REMOTE_CONNECT, WTS_SESSION_UNLOCK,
                             WTS_SESSION_DESKTOP_READY};
  for (WPARAM session : sessions) {
    RECT before{}, after{};
    GetWindowRect(f.owner, &before);
    // The viewport stays the same size, while Flutter retains a stale scale.
    f.cached_dpi = f.published_dpi = 17;
    f.order.clear();
    SendMessage(f.owner, WM_WTSSESSION_CHANGE, session, 0);
    Check(f.published_dpi == 17, "session refresh waits for display messages");
    PumpMessages();
    f.ExpectCurrentMetrics();
    GetWindowRect(f.owner, &after);
    Check(EqualRect(&before, &after), "session refresh preserves outer bounds");
  }

  f.order.clear();
  Check(!f.refresh.HandleMessage(WM_DPICHANGED, MAKELONG(192, 192)),
        "normal DPI change still reaches plugins and parent");
  SetWindowPos(f.owner, nullptr, 0, 0, 900, 700, SWP_NOMOVE | SWP_NOACTIVATE);
  PumpMessages();
  f.ExpectCurrentMetrics();

  const UINT events[] = {WM_DISPLAYCHANGE, WM_SETTINGCHANGE, WM_ACTIVATEAPP};
  for (UINT event : events) {
    f.order.clear();
    f.cached_dpi = 17;
    Check(!f.refresh.HandleMessage(event, 1), "broadcast is not consumed");
    PumpMessages();
    f.ExpectCurrentMetrics();
  }
  Check(!f.refresh.HandleMessage(WM_TIMER, 123), "unrelated timers pass through");

  const int before_restore = f.refresh_count;
  f.refresh.HandleMessage(WM_SIZE, SIZE_MINIMIZED);
  f.refresh.HandleMessage(WM_SIZE, SIZE_RESTORED);
  PumpMessages();
  Check(f.refresh_count > before_restore, "restoring schedules a refresh");
}

void TestBoundedRecoveryAndCleanup() {
  Fixture f;
  for (int i = 0; i < 20; ++i) {
    f.refresh.HandleMessage(WM_DISPLAYCHANGE, 0);
  }
  PumpMessages();
  Check(f.refresh_count == 1, "coalesce queued display changes");
  f.cached_dpi = 17;
  PumpMessages(300);
  Check(f.published_dpi == GetDpiForWindow(f.child),
        "retry repairs metrics that settle after first notification");
  PumpMessages(2200);
  const int settled = f.refresh_count;
  PumpMessages(600);
  Check(f.refresh_count == settled, "stop polling after recovery window");

  f.refresh.HandleMessage(WM_DISPLAYCHANGE, 0);
  f.refresh.Stop();
  PumpMessages(300);
  Check(f.refresh_count == settled, "cancel queued work/timer on teardown");
}
}  // namespace

int main() {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  WNDCLASS window_class{};
  window_class.hInstance = GetModuleHandle(nullptr);
  window_class.lpfnWndProc = Fixture::WindowProc;
  window_class.lpszClassName = kWindowClass;
  Check(RegisterClass(&window_class) != 0, "register test window class");
  const HWND foreground = GetForegroundWindow();

  // Exercise 96-DPI and native per-monitor windows without changing the user's
  // display settings, disconnecting RDP, or showing/activating any test window.
  const DPI_AWARENESS_CONTEXT contexts[] = {
      DPI_AWARENESS_CONTEXT_UNAWARE, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};
  for (auto context : contexts) {
    const auto previous = SetThreadDpiAwarenessContext(context);
    TestMetricsAndSessionRecovery();
    SetThreadDpiAwarenessContext(previous);
  }
  TestBoundedRecoveryAndCleanup();
  Check(GetForegroundWindow() == foreground, "do not steal focus");
  UnregisterClass(kWindowClass, GetModuleHandle(nullptr));
  std::cout << "PASS: DPI/session recovery, viewport ordering, bounded retries, "
               "restore and cleanup\n";
  return 0;
}
