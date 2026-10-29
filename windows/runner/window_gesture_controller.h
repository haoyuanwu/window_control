#ifndef RUNNER_WINDOW_GESTURE_CONTROLLER_H_
#define RUNNER_WINDOW_GESTURE_CONTROLLER_H_
#include <flutter/binary_messenger.h>
#include <memory>
#include <optional>
#include <windows.h>

// Owns the native channel and a dedicated input/message-loop thread.
class WindowGestureController {
 public:
  explicit WindowGestureController(flutter::BinaryMessenger* messenger, HWND owner = nullptr);
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wp, LPARAM lp);
  ~WindowGestureController();
 private:
#ifdef WINDOW_CONTROL_NATIVE_TEST
  friend class NativeGestureTest;
#endif
  class Impl;
  std::unique_ptr<Impl> impl_;
};
#endif
