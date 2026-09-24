#ifndef RUNNER_FLUTTER_DPI_REFRESH_H_
#define RUNNER_FLUTTER_DPI_REFRESH_H_

#include <windows.h>

#include <functional>

// Re-publishes Flutter's DPI and viewport after desktop/session transitions.
// All methods run on the window's platform thread.
class FlutterDpiRefresh {
 public:
  explicit FlutterDpiRefresh(std::function<void(UINT)> refresh_plugins);
  ~FlutterDpiRefresh();

  void Start(HWND window, HWND flutter_view);
  void Stop();
  // Observe before plugin dispatch, since plugins may consume these messages.
  // Returns true only for this object's private refresh/timer messages.
  bool HandleMessage(UINT message, WPARAM wparam);

 private:
  void Schedule();
  void Refresh();

  HWND window_ = nullptr;
  HWND flutter_view_ = nullptr;
  std::function<void(UINT)> refresh_plugins_;
  bool registered_ = false;
  bool posted_ = false;
  bool minimized_ = false;
  unsigned int remaining_checks_ = 0;
};

#endif  // RUNNER_FLUTTER_DPI_REFRESH_H_
