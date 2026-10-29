#include "window_gesture_controller.h"
#include <windows.h>
#include <shellapi.h>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <map>
#include <set>
#include <cwctype>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <cmath>
#include <atomic>
#include <sstream>
#include <deque>
#include <future>
#include <condition_variable>
#include <chrono>
#include <mutex>
#include <string>
#include <thread>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
constexpr UINT kBegin = WM_APP + 71;
constexpr UINT kMove = WM_APP + 72;
constexpr UINT kEnd = WM_APP + 73;
constexpr UINT kCancel = WM_APP + 74;
constexpr UINT kRelease = WM_APP + 75;
constexpr UINT kRefreshHooks = WM_APP + 76;
constexpr UINT kConfigureMemory = WM_APP + 77;
constexpr UINT kFinishRemember = WM_APP + 78;
constexpr UINT kTray = WM_APP + 79;
constexpr ULONG_PTR kTestInputMarker = 0x57435445;
bool AcceptMouseInput(const MSLLHOOKSTRUCT& event) {
  if (event.flags & LLMHF_LOWER_IL_INJECTED) return false;
#ifdef WINDOW_CONTROL_NATIVE_TEST
  return !(event.flags & LLMHF_INJECTED) || event.dwExtraInfo == kTestInputMarker;
#else
  // Remote desktop and accessibility drivers can produce same-integrity injected
  // events. This application never synthesizes input, so no feedback loop exists.
  return true;
#endif
}
bool AcceptKeyboardInput(const KBDLLHOOKSTRUCT& event) {
  if (event.flags & LLKHF_LOWER_IL_INJECTED) return false;
#ifdef WINDOW_CONTROL_NATIVE_TEST
  return !(event.flags & LLKHF_INJECTED) || event.dwExtraInfo == kTestInputMarker;
#else
  return true;
#endif
}
constexpr int kCtrl = 1, kAlt = 2, kShift = 4, kMeta = 8;
struct Settings {
  bool enabled = false;
  int resize = kCtrl | kAlt;
  int move = kCtrl | kShift;
  bool edgeResize = true;
  bool rememberWindows = false;
  bool launchAtLogin = false;
  bool autoEnable = false;
  bool closeToTray = true;
  std::vector<std::wstring> excludedApps;

};
const Value* Find(const Map& map, const char* key) {
  auto it = map.find(Value(key));
  return it == map.end() ? nullptr : &it->second;
}
bool ReadMask(const Value* value, int& result) {
  if (!value || !std::holds_alternative<flutter::EncodableList>(*value)) return false;
  result = 0;
  for (const auto& item : std::get<flutter::EncodableList>(*value)) {
    const auto* key = std::get_if<std::string>(&item);
    if (!key) return false;
    int bit = *key == "ctrl" ? kCtrl : *key == "alt" ? kAlt :
              *key == "shift" ? kShift : *key == "meta" ? kMeta : 0;
    if (!bit || (result & bit)) return false;
    result |= bit;
  }
  return result != 0;
}
int Modifiers() {
  int result = 0;
  if (GetAsyncKeyState(VK_CONTROL) & 0x8000) result |= kCtrl;
  if (GetAsyncKeyState(VK_MENU) & 0x8000) result |= kAlt;
  if (GetAsyncKeyState(VK_SHIFT) & 0x8000) result |= kShift;
  if ((GetAsyncKeyState(VK_LWIN) | GetAsyncKeyState(VK_RWIN)) & 0x8000) result |= kMeta;
  return result;
}
bool Allowed(HWND window) {
  if (!window || !IsWindow(window) || !IsWindowVisible(window) ||
      !IsWindowEnabled(window) || IsIconic(window) || window == GetShellWindow() ||
      window == GetDesktopWindow()) return false;
  DWORD pid = 0;
  GetWindowThreadProcessId(window, &pid);
  if (!pid || pid == GetCurrentProcessId()) return false;
  LONG_PTR style = GetWindowLongPtr(window, GWL_STYLE);
  LONG_PTR exstyle = GetWindowLongPtr(window, GWL_EXSTYLE);
  if (!(style & WS_THICKFRAME) || (style & WS_CHILD) ||
      (exstyle & (WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE))) return false;
  wchar_t name[128]{};
  GetClassName(window, name, 128);
  if (wcscmp(name, L"Progman") == 0 || wcscmp(name, L"WorkerW") == 0 ||
      wcscmp(name, L"Shell_TrayWnd") == 0 || wcscmp(name, L"Shell_SecondaryTrayWnd") == 0 ||
      wcscmp(name, L"Windows.UI.Core.CoreWindow") == 0) return false;
  return true;
}
std::wstring Lower(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(), [](wchar_t c) { return static_cast<wchar_t>(towlower(c)); });
  return value;
}
std::wstring Wide(const std::string& text) {
  int count = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
  std::wstring result(count, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), result.data(), count);
  return result;
}
std::string Utf8(const std::wstring& text) {
  int count = WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  std::string result(count, '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), result.data(), count, nullptr, nullptr);
  return result;
}
std::wstring AppName(HWND window) {
  DWORD pid = 0;
  GetWindowThreadProcessId(window, &pid);
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) return {};
  wchar_t path[32768]{};
  DWORD count = 32768;
  bool ok = QueryFullProcessImageName(process, 0, path, &count) != FALSE;
  CloseHandle(process);
  return ok ? Lower(std::filesystem::path(path).filename().wstring()) : L"";
}
std::wstring MemoryKey(HWND window) {
  wchar_t name[256]{};
  GetClassName(window, name, 256);
  const auto app = AppName(window);
  return app.empty() ? L"" : app + L"|" + name;
}
bool Excluded(HWND window, const Settings& settings) {
  const auto app = AppName(window);
  return std::find(settings.excludedApps.begin(), settings.excludedApps.end(), app) != settings.excludedApps.end();
}
RECT ClampToWorkArea(RECT frame) {
  MONITORINFO info{sizeof(MONITORINFO)};
  if (!GetMonitorInfo(MonitorFromRect(&frame, MONITOR_DEFAULTTONEAREST), &info)) return frame;
  const RECT work = info.rcWork;
  LONG width = std::clamp(frame.right - frame.left, 1L, work.right - work.left);
  LONG height = std::clamp(frame.bottom - frame.top, 1L, work.bottom - work.top);
  LONG x = std::clamp(frame.left, work.left, work.right - width);
  LONG y = std::clamp(frame.top, work.top, work.bottom - height);
  return {x, y, x + width, y + height};
}
std::wstring StartupPath() {
  wchar_t path[32768]{};
  DWORD count = GetEnvironmentVariable(L"WINDOW_CONTROL_LAUNCHER_PATH", path, 32768);
  if (!count || count >= 32768) GetModuleFileName(nullptr, path, 32768);
  return path;
}
#ifdef WINDOW_CONTROL_NATIVE_TEST
int startup_write_count = 0;
#endif
bool SetStartup(bool enabled) {
#ifdef WINDOW_CONTROL_NATIVE_TEST
  ++startup_write_count;
  return true;  // Tests never change the developer account's startup state.
#else
  HKEY key = nullptr;
  if (RegCreateKeyEx(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Run",
      0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) return false;
  LONG result;
  if (enabled) {
    std::wstring command = L"\"" + StartupPath() + L"\"";
    result = RegSetValueEx(key, L"WindowControl", 0, REG_SZ,
        reinterpret_cast<const BYTE*>(command.c_str()), static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else {
    result = RegDeleteValue(key, L"WindowControl");
    if (result == ERROR_FILE_NOT_FOUND) result = ERROR_SUCCESS;
  }
  RegCloseKey(key);
  return result == ERROR_SUCCESS;
#endif
}
bool ReadStartup() {
  DWORD bytes = 0;
  return RegGetValue(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Run",
      L"WindowControl", RRF_RT_REG_SZ, nullptr, nullptr, &bytes) == ERROR_SUCCESS;
}
struct InputEvent {
  UINT kind;
  HWND target;
  POINT point;
  Settings settings;
  uint64_t revision = 0;
  bool moving = false;
  bool ratio = false;
};
struct SavedWindow {
  HWND window = nullptr;
  DWORD pid = 0;
  WINDOWPLACEMENT placement{sizeof(WINDOWPLACEMENT)};
  RECT frame{};
};
// Synchronous geometry runs on a separate worker, never on the hook thread.
// A single pending resize per gesture replaces stale cursor samples. Restore
// commands are barriers so cancellation cannot be overtaken by an old resize.
class GeometryQueue {
 public:
  struct Request {
    SavedWindow saved;
    RECT frame{};
    uint64_t gesture = 0;
    bool restore = false;
    bool left = false;
    bool top = false;
    std::shared_ptr<std::promise<DWORD>> completion = nullptr;
  };
  GeometryQueue() : state_(std::make_shared<State>()) {
    auto state = state_;
    std::thread([state] {
      SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
      std::unique_lock<std::mutex> lock(state->mutex);
      while (true) {
        state->wake.wait(lock, [&] { return state->stop || !state->pending.empty(); });
        if (state->pending.empty() && state->stop) break;
        // Give rapid input a bounded 8ms coalescing interval.
        if (!state->pending.front().restore && !state->stop)
          state->wake.wait_for(lock, std::chrono::milliseconds(8), [&] { return state->stop; });
        const Request request = state->pending.front();
        state->pending.pop_front();
        state->busy = true;
        lock.unlock();
        const DWORD error = Execute(request);
        if (request.completion) request.completion->set_value(error);
        lock.lock();
        state->last_error = error;
        ++state->applied;
        state->busy = false;
        state->wake.notify_all();
      }
    }).detach();
  }
  ~GeometryQueue() {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->stop = true;
    state_->wake.notify_all();
    // State belongs to the worker too: an unresponsive foreign app cannot hang
    // hook shutdown or access the destroyed controller after returning.
  }
  void Submit(Request request) {
    std::lock_guard<std::mutex> lock(state_->mutex);
    if (request.restore) {
      // Remove pending samples for the cancelled gesture, keep older barriers.
      auto& pending = state_->pending;
      pending.erase(std::remove_if(pending.begin(), pending.end(), [&](const auto& item) {
        return !item.restore && item.gesture == request.gesture;
      }), pending.end());
    }
    if (!request.restore && !state_->pending.empty() &&
        !state_->pending.back().restore && state_->pending.back().gesture == request.gesture)
      state_->pending.back() = request;
    else state_->pending.push_back(request);
    state_->wake.notify_all();
  }
  DWORD SubmitAndWait(Request request) {
    request.completion = std::make_shared<std::promise<DWORD>>();
    auto finished = request.completion->get_future();
    Submit(request);
    if (finished.wait_for(std::chrono::seconds(2)) != std::future_status::ready) return ERROR_TIMEOUT;
    return finished.get();
  }
  bool Idle() {
    std::lock_guard<std::mutex> lock(state_->mutex);
    return !state_->busy && state_->pending.empty();
  }
  std::pair<DWORD, size_t> Diagnostics() {
    std::lock_guard<std::mutex> lock(state_->mutex);
    return {state_->last_error, state_->applied};
  }
#ifdef WINDOW_CONTROL_NATIVE_TEST
  bool WaitIdle() {
    std::unique_lock<std::mutex> lock(state_->mutex);
    return state_->wake.wait_for(lock, std::chrono::seconds(5), [&] {
      return !state_->busy && state_->pending.empty();
    });
  }
  size_t Applied() {
    std::lock_guard<std::mutex> lock(state_->mutex);
    return state_->applied;
  }
#endif
 private:
  struct State {
    std::mutex mutex;
    std::condition_variable wake;
    std::deque<Request> pending;
    bool stop = false;
    bool busy = false;
    size_t applied = 0;
    DWORD last_error = 0;
  };
  static DWORD Execute(const Request& request) {
    DWORD pid = 0;
    GetWindowThreadProcessId(request.saved.window, &pid);
    if (!request.saved.window || pid != request.saved.pid || !IsWindow(request.saved.window)) return ERROR_INVALID_WINDOW_HANDLE;
    const HWND window = request.saved.window;
    const RECT frame = request.restore ? request.saved.frame : request.frame;
    if (IsHungAppWindow(window)) return ERROR_TIMEOUT;
    const UINT flags = SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOOWNERZORDER;
    // No ASYNCWINDOWPOS: exactly one applied resize in flight for all requests.
    if (!SetWindowPos(window, nullptr, frame.left, frame.top,
        frame.right - frame.left, frame.bottom - frame.top, flags)) return GetLastError();
    if (!request.restore) {
      RECT actual{};
      if (!GetWindowRect(window, &actual)) return GetLastError();
      // Applications may clamp dimensions in WINDOWPOSCHANGING, beyond the
      // advertised MINMAXINFO. Keep the original opposite corner fixed anyway.
      LONG x = request.left ? frame.right - (actual.right - actual.left) : frame.left;
      LONG y = request.top ? frame.bottom - (actual.bottom - actual.top) : frame.top;
      if ((actual.left != x || actual.top != y) &&
          !SetWindowPos(window, nullptr, x, y, 0, 0, flags | SWP_NOSIZE)) return GetLastError();
    }
    return ERROR_SUCCESS;
  }
  std::shared_ptr<State> state_;
};
}  // namespace

class WindowGestureController::Impl {
 public:
  explicit Impl(flutter::BinaryMessenger* messenger, HWND owner) : owner_(owner) {
    settings_.launchAtLogin = ReadStartup();
    LoadMemory();
    AddTray();
    std::promise<void> ready;
    auto started = ready.get_future();
    worker_ = std::thread([this, &ready] { Run(ready); });
    started.wait();
    channel_ = std::make_unique<flutter::MethodChannel<Value>>(
        messenger, "window_control/native", &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler([this](const auto& call, auto result) {
      if (call.method_name() == "getStatus" || call.method_name() == "requestPermissions") {
        result->Success(Status());
      } else if (call.method_name() == "configure") {
        const auto* args = call.arguments();
        const auto* map = args ? std::get_if<Map>(args) : nullptr;
        Settings next;
        // Disabling must take effect even if another field is invalid/stale.
        if (map) {
          const auto* enabled = Find(*map, "enabled");
          if (enabled && std::holds_alternative<bool>(*enabled) && !std::get<bool>(*enabled)) {
            {
              std::lock_guard<std::mutex> lock(mutex_);
              settings_.enabled = false;
              ++settings_revision_;
            }
            PostThreadMessage(thread_id_, kCancel, 0, 0);
          }
        }
        bool valid = map != nullptr;
        if (map) {
          const auto* enabled = Find(*map, "enabled");
          valid = enabled && std::holds_alternative<bool>(*enabled) &&
              ReadMask(Find(*map, "resizeKeys"), next.resize);
          if (valid) next.enabled = std::get<bool>(*enabled);
          if (Find(*map, "moveKeys")) valid = valid && ReadMask(Find(*map, "moveKeys"), next.move);
          auto boolean = [&](const char* key, bool& destination) {
            const auto* value = Find(*map, key);
            if (!value) return;
            if (const auto* flag = std::get_if<bool>(value)) destination = *flag;
            else valid = false;
          };
          boolean("edgeResize", next.edgeResize);
          boolean("rememberWindows", next.rememberWindows);
          boolean("launchAtLogin", next.launchAtLogin);
          boolean("autoEnable", next.autoEnable);
          boolean("closeToTray", next.closeToTray);
          const int ratio = next.resize & kShift ? kAlt : kShift;
          valid = valid && next.resize != next.move && (next.resize | ratio) != next.move &&
              (next.resize & (kShift | kAlt)) != (kShift | kAlt);
          if (const auto* excluded = Find(*map, "excludedApps")) {
            const auto* list = std::get_if<flutter::EncodableList>(excluded);
            if (!list) valid = false;
            else for (const auto& item : *list) {
              const auto* app = std::get_if<std::string>(&item);
              if (!app || app->empty()) { valid = false; break; }
              auto name = Lower(std::filesystem::path(Wide(*app)).filename().wstring());
              if (!name.empty()) next.excludedApps.push_back(name);
            }
          }
        }
        if (!valid) {
          result->Error("invalid_settings", "Choose a non-empty combination of modifier keys.");
          return;
        }
        bool startupChanged;
        bool memoryChanged;
        {
          std::lock_guard<std::mutex> lock(mutex_);
          const auto* apply = Find(*map, "applyLaunchAtLogin");
          startupChanged = apply && std::holds_alternative<bool>(*apply) && std::get<bool>(*apply) &&
              next.launchAtLogin != settings_.launchAtLogin;
          if (!startupChanged) next.launchAtLogin = settings_.launchAtLogin;
          memoryChanged = next.rememberWindows != settings_.rememberWindows || (!settings_.enabled && next.enabled);
        }
        if (startupChanged && !SetStartup(next.launchAtLogin)) {
          result->Error("startup_failed", "无法更新当前用户的登录启动设置");
          return;
        }
        {
          std::lock_guard<std::mutex> lock(mutex_);
          settings_ = next;
          ++settings_revision_;
        }
        if (memoryChanged) PostThreadMessage(thread_id_, kConfigureMemory, 0, 0);
        PostThreadMessage(thread_id_, kCancel, 0, 0);
        if (next.enabled) PostThreadMessage(thread_id_, kRefreshHooks, 0, 0);
        result->Success(Status());
      } else if (call.method_name() == "restoreLast") {
        result->Success(Value(Undo()));
      } else if (call.method_name() == "listWindows") {
        flutter::EncodableList windows;
        std::pair<Impl*, flutter::EncodableList*> context{this, &windows};
        EnumWindows([](HWND window, LPARAM param) -> BOOL {
          auto* data = reinterpret_cast<std::pair<Impl*, flutter::EncodableList*>*>(param);
          if (!Allowed(window) || IsZoomed(window) || data->first->IsExcluded(window)) return TRUE;
          wchar_t title[1024]{};
          GetWindowText(window, title, 1024);
          if (!title[0]) return TRUE;
          data->second->emplace_back(Map{
            {Value("id"), Value(WindowToken(window))},
            {Value("title"), Value(Utf8(title))}, {Value("app"), Value(Utf8(AppName(window)))}});
          return TRUE;
        }, reinterpret_cast<LPARAM>(&context));
        result->Success(Value(windows));
      } else if (call.method_name() == "applyPreset" || call.method_name() == "centerWindow") {
        const auto* args = call.arguments();
        const auto* map = args ? std::get_if<Map>(args) : nullptr;
        result->Success(Value(map && ApplyPreset(*map, call.method_name() == "centerWindow")));

      } else {
        result->NotImplemented();
      }
    });
  }
  ~Impl() {
    RemoveTray();
    channel_->SetMethodCallHandler(nullptr);
    PostThreadMessage(thread_id_, WM_QUIT, 0, 0);
    if (worker_.joinable()) worker_.join();
  }
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wp, LPARAM lp) {
    if (message == taskbar_created_) { tray_added_ = false; AddTray(); }
    if (message == WM_CLOSE) {
      bool keep;
      { std::lock_guard<std::mutex> lock(mutex_); keep = settings_.closeToTray; }
      if (keep && tray_added_ && !exiting_) { ShowWindow(owner_, SW_HIDE); return 0; }
    }
    if (message == kTray) {
      if (lp == WM_LBUTTONUP || lp == WM_LBUTTONDBLCLK) ShowSettings();
      else if (lp == WM_RBUTTONUP || lp == WM_CONTEXTMENU) {
        HMENU menu = CreatePopupMenu();
        bool enabled;
        { std::lock_guard<std::mutex> lock(mutex_); enabled = settings_.enabled; }
        AppendMenu(menu, MF_STRING, 1, L"显示设置");
        AppendMenu(menu, MF_STRING, 2, enabled ? L"暂停服务" : L"开启服务");
        AppendMenu(menu, MF_STRING, 3, L"撤销上次操作");
        AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
        AppendMenu(menu, MF_STRING, 4, L"退出");
        POINT cursor{};
        GetCursorPos(&cursor);
        SetForegroundWindow(owner_);
        UINT command = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
            cursor.x, cursor.y, 0, owner_, nullptr);
        DestroyMenu(menu);
        PostMessage(owner_, WM_NULL, 0, 0);
        if (command == 1) ShowSettings();
        else if (command == 2) {
          {
            std::lock_guard<std::mutex> lock(mutex_);
            settings_.enabled = !settings_.enabled;
            ++settings_revision_;
          }
          PostThreadMessage(thread_id_, kCancel, 0, 0);
          PostThreadMessage(thread_id_, kConfigureMemory, 0, 0);
          PostThreadMessage(thread_id_, kRefreshHooks, 0, 0);
        } else if (command == 3) Undo();
        else if (command == 4) { exiting_ = true; PostMessage(owner_, WM_CLOSE, 0, 0); }
      }
      return 0;
    }
    return std::nullopt;
  }

 private:
#ifdef WINDOW_CONTROL_NATIVE_TEST
  friend class NativeGestureTest;
#endif
  void AddTray() {
    if (!owner_ || tray_added_) return;
    tray_.cbSize = sizeof(tray_);
    tray_.hWnd = owner_;
    tray_.uID = 1;
    tray_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    tray_.uCallbackMessage = kTray;
    tray_.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(101));
    if (!tray_.hIcon) tray_.hIcon = LoadIcon(nullptr, IDI_APPLICATION);
    wcscpy_s(tray_.szTip, L"Window Control · 窗口工具");
    tray_added_ = Shell_NotifyIcon(NIM_ADD, &tray_) != FALSE;
  }
  void RemoveTray() {
    if (tray_added_) Shell_NotifyIcon(NIM_DELETE, &tray_);
    tray_added_ = false;
  }
  void ShowSettings() {
    if (!owner_) return;
    ShowWindow(owner_, SW_RESTORE);
    SetForegroundWindow(owner_);
  }
  bool IsExcluded(HWND window) {
    Settings settings;
    { std::lock_guard<std::mutex> lock(mutex_); settings = settings_; }
    return Excluded(window, settings);
  }
  void Finish(const SavedWindow& saved) {
    std::lock_guard<std::mutex> lock(mutex_);
    last_ = saved;
    history_.push_back(saved);
    if (history_.size() > 20) history_.pop_front();
    if (settings_.rememberWindows)
      pending_remember_.push_back({saved.window, saved.pid, GetTickCount64() + 500});
  }
  bool Undo() {
    SavedWindow saved;
    while (true) {
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (history_.empty()) return false;
        saved = history_.back();
        history_.pop_back();
        pending_remember_.erase(std::remove_if(pending_remember_.begin(), pending_remember_.end(),
            [&](const auto& item) { return item.window == saved.window; }), pending_remember_.end());
      }
      DWORD pid = 0;
      GetWindowThreadProcessId(saved.window, &pid);
      if (saved.window && IsWindow(saved.window) && pid == saved.pid && !IsExcluded(saved.window)) {
        const DWORD error = geometry_.SubmitAndWait({saved, {}, 0, true});
        if (error == ERROR_SUCCESS) return true;
        { std::lock_guard<std::mutex> lock(mutex_); history_.push_back(saved); }
        return false;
      }
    }
  }
  static std::string WindowToken(HWND window) {
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    return std::to_string(reinterpret_cast<uintptr_t>(window)) + ":" + std::to_string(pid);
  }
  bool ApplyPreset(const Map& args, bool centerOnly) {
    const auto* id = Find(args, "windowId");
    if (!id || !std::holds_alternative<std::string>(*id)) return false;
    const std::string& token = std::get<std::string>(*id);
    auto separator = token.find(':');
    if (separator == std::string::npos || separator == 0 || separator + 1 == token.size() ||
        token.substr(0, separator).find_first_not_of("0123456789") != std::string::npos ||
        token.substr(separator + 1).find_first_not_of("0123456789") != std::string::npos) return false;
    wchar_t* end = nullptr;
    const auto wide = Wide(token.substr(0, separator));
    HWND window = reinterpret_cast<HWND>(static_cast<uintptr_t>(_wcstoui64(wide.c_str(), &end, 10)));
    if (!Allowed(window) || IsZoomed(window) || IsExcluded(window) || WindowToken(window) != token) return false;
    SavedWindow saved;
    saved.window = window;
    GetWindowThreadProcessId(window, &saved.pid);
    if (!GetWindowRect(window, &saved.frame) || !GetWindowPlacement(window, &saved.placement)) return false;
    RECT frame = saved.frame;
    LONG width = frame.right - frame.left;
    LONG height = frame.bottom - frame.top;
    bool center = centerOnly;
    if (!centerOnly) {
      const auto* w = Find(args, "width");
      const auto* h = Find(args, "height");
      const auto* c = Find(args, "center");
      if (!w || !h || !c || !std::holds_alternative<int32_t>(*w) ||
          !std::holds_alternative<int32_t>(*h) || !std::holds_alternative<bool>(*c)) return false;
      width = std::get<int32_t>(*w);
      height = std::get<int32_t>(*h);
      center = std::get<bool>(*c);
      if (width < 100 || height < 100 || width > 16384 || height > 16384) return false;
    }
    MONITORINFO info{sizeof(MONITORINFO)};
    if (!GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &info)) return false;
    const RECT work = info.rcWork;
    if (!centerOnly) {
      width = std::min(width, work.right - work.left);
      height = std::min(height, work.bottom - work.top);
    }
    if (center) { frame.left = work.left + (work.right - work.left - width) / 2;
                  frame.top = work.top + (work.bottom - work.top - height) / 2; }
    frame.right = frame.left + width;
    frame.bottom = frame.top + height;
    if (!centerOnly) frame = ClampToWorkArea(frame);
    if (EqualRect(&frame, &saved.frame)) return true;
    static std::atomic<uint64_t> presetId{1000000};
    const DWORD error = geometry_.SubmitAndWait({saved, frame, ++presetId, false});
    if (error != ERROR_SUCCESS) return false;
    Finish(saved);
    PostThreadMessage(thread_id_, kFinishRemember, 0, 0);
    return true;
  }
  std::filesystem::path MemoryPath() {
#ifdef WINDOW_CONTROL_NATIVE_TEST
    return {};  // Unit/integration tests never persist developer window memory.
#else
    wchar_t appdata[32768]{};
    if (!GetEnvironmentVariable(L"APPDATA", appdata, 32768)) return {};
    return std::filesystem::path(appdata) / L"WindowControl" / L"window-memory.txt";
#endif
  }
  void LoadMemory() {
    auto path = MemoryPath();
    if (path.empty()) return;
    std::ifstream input(path);
    std::string key;
    RECT rect{};
    while (input >> std::quoted(key) >> rect.left >> rect.top >> rect.right >> rect.bottom) {
      if (rect.right > rect.left && rect.bottom > rect.top && remembered_.size() < 200)
        remembered_[Wide(key)] = rect;
    }
  }
  void SaveMemory() {
    auto path = MemoryPath();
    if (path.empty()) return;
    std::error_code error;
    std::filesystem::create_directories(path.parent_path(), error);
    if (error) return;
    auto temporary = path;
    temporary += L".tmp";
    {
      std::ofstream output(temporary, std::ios::trunc);
      if (!output) return;
      for (const auto& entry : remembered_) {
        const auto& rect = entry.second;
        output << std::quoted(Utf8(entry.first)) << ' ' << rect.left << ' ' << rect.top
               << ' ' << rect.right << ' ' << rect.bottom << '\n';
      }
      if (!output.good()) return;
    }
    MoveFileEx(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
  }
  void SeedSeenWindows() {
    std::map<HWND, DWORD> next;
    EnumWindows([](HWND window, LPARAM param) -> BOOL {
      DWORD pid = 0;
      GetWindowThreadProcessId(window, &pid);
      if (IsWindowVisible(window)) reinterpret_cast<std::map<HWND, DWORD>*>(param)->emplace(window, pid);
      return TRUE;
    }, reinterpret_cast<LPARAM>(&next));
    seen_ = std::move(next);
    std::lock_guard<std::mutex> lock(mutex_);
    pending_remember_.clear();
  }
  void PollMemory() {
    Settings settings;
    { std::lock_guard<std::mutex> lock(mutex_); settings = settings_; }
    if (!settings.enabled || !settings.rememberWindows || !geometry_.Idle()) return;
    bool dirty = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      for (auto it = pending_remember_.begin(); it != pending_remember_.end();) {
        if (GetTickCount64() < it->when || (active_ && target_ == it->window)) { ++it; continue; }
        DWORD pid = 0;
        GetWindowThreadProcessId(it->window, &pid);
        RECT frame{};
        auto key = MemoryKey(it->window);
        if (geometry_.Diagnostics().first == 0 && pid == it->pid && !key.empty() && !Excluded(it->window, settings) &&
            GetWindowRect(it->window, &frame) && remembered_.size() < 200) {
          remembered_[key] = ClampToWorkArea(frame);
          dirty = true;
        }
        it = pending_remember_.erase(it);
      }
    }
    if (dirty) SaveMemory();
    std::map<HWND, DWORD> next;
    EnumWindows([](HWND window, LPARAM param) -> BOOL {
      DWORD pid = 0;
      GetWindowThreadProcessId(window, &pid);
      if (IsWindowVisible(window)) reinterpret_cast<std::map<HWND, DWORD>*>(param)->emplace(window, pid);
      return TRUE;
    }, reinterpret_cast<LPARAM>(&next));
    for (const auto& entry : next) {
      auto old = seen_.find(entry.first);
      if (old != seen_.end() && old->second == entry.second) continue;
      if (!Allowed(entry.first) || IsZoomed(entry.first) || Excluded(entry.first, settings)) continue;
      const auto key = MemoryKey(entry.first);
      auto memory = remembered_.find(key);
      if (memory == remembered_.end()) continue;
      SavedWindow saved;
      saved.window = entry.first;
      saved.pid = entry.second;
      GetWindowRect(entry.first, &saved.frame);
      geometry_.Submit({saved, ClampToWorkArea(memory->second), ++gesture_id_, false});
    }
    seen_ = std::move(next);
  }
  void Diagnose(std::string reason) {
    std::lock_guard<std::mutex> lock(mutex_);
    last_reason_ = std::move(reason);
  }
  Value Status() {
    const auto geometry = geometry_.Diagnostics();
    std::lock_guard<std::mutex> lock(mutex_);
    std::ostringstream message;
    message << (settings_.enabled ? "服务已开启" : "服务已关闭")
            << "；钩子=" << (hooks_ok_ ? "已安装" : "安装失败")
            << "；鼠标事件=" << mouse_events_.load() << "，按键事件=" << keyboard_events_.load()
            << "；最近组合=" << last_mask_ << "，要求=" << settings_.resize
            << "（Ctrl=1 Alt=2 Shift=4 Win=8）"
            << "；目标=" << last_class_ << "；" << last_reason_
            << "；窗口更新=" << geometry.second << "，Win32错误=" << geometry.first
            << "，钩子错误=" << hook_error_
            << "；托盘=" << (tray_added_ ? "可用" : "不可用，关闭窗口将退出");
    return Value(Map{
      {Value("enabled"), Value(settings_.enabled && hooks_ok_)},
      {Value("accessibility"), Value(hooks_ok_.load())},
      {Value("inputMonitoring"), Value(hooks_ok_.load())},
      {Value("message"), Value(message.str())},
      {Value("undoCount"), Value(static_cast<int32_t>(history_.size()))},
      {Value("launchAtLogin"), Value(settings_.launchAtLogin)}
    });
  }
  static LRESULT CALLBACK MouseHook(int code, WPARAM message, LPARAM param) {
    auto* self = current_;
    if (code < 0 || !self) return CallNextHookEx(nullptr, code, message, param);
    auto* event = reinterpret_cast<MSLLHOOKSTRUCT*>(param);
    ++self->mouse_events_;
    if (!AcceptMouseInput(*event)) {
      if (message == WM_LBUTTONDOWN) self->Diagnose("已拒绝低完整性或非测试标记的注入输入");
      return CallNextHookEx(nullptr, code, message, param);
    }
    if (message == WM_LBUTTONDOWN && !self->swallow_) {
      Settings settings;
      uint64_t revision = 0;
      {
        std::lock_guard<std::mutex> lock(self->mutex_);
        settings = self->settings_;
        revision = self->settings_revision_;
      }
      int mask = Modifiers();
      {
        std::lock_guard<std::mutex> lock(self->mutex_);
        self->last_mask_ = mask;
      }
      if (!settings.enabled) self->Diagnose("请先开启服务");
      else if (mask != settings.resize) self->Diagnose("按键组合不匹配，请按住全部已选修饰键");
      const int ratioModifier = settings.resize & kShift ? kAlt : kShift;
      const bool moving = mask == settings.move;
      const bool ratio = !moving && mask == (settings.resize | ratioModifier);
      if (settings.enabled && (moving || mask == settings.resize || ratio)) {
        HWND target = GetAncestor(WindowFromPoint(event->pt), GA_ROOT);
        wchar_t class_name[128]{};
        GetClassName(target, class_name, 128);
        char utf8[512]{};
        WideCharToMultiByte(CP_UTF8, 0, class_name, -1, utf8, 512, nullptr, nullptr);
        DWORD target_pid = 0;
        GetWindowThreadProcessId(target, &target_pid);
        {
          std::lock_guard<std::mutex> lock(self->mutex_);
          self->last_class_ = utf8;
        }
        if (target_pid == GetCurrentProcessId()) self->Diagnose("不支持缩放本工具自己的设置窗口，请拖动其他应用");
        else if (IsZoomed(target)) self->Diagnose("目标已最大化，请先还原为普通窗口");
        else if (!Allowed(target)) self->Diagnose("目标为系统、工具、不可缩放或不可用窗口");
        if (Excluded(target, settings)) self->Diagnose("目标应用已排除");
        if (Allowed(target) && !IsZoomed(target) && !Excluded(target, settings)) {
          self->Diagnose("已命中可缩放窗口，等待拖动");
          self->events_.push_back({kBegin, target, event->pt, settings, revision, moving, ratio});
          self->swallow_ = true;
          self->capturing_ = true;
          self->captured_mask_ = moving ? settings.move : settings.resize;
          self->captured_ratio_modifier_ = ratioModifier;
          self->pointer_ = event->pt;
          PostThreadMessage(self->thread_id_, kBegin, 0, 0);
          return 1;
        }
      }
    } else if (self->swallow_ && message == WM_MOUSEMOVE) {
      self->pointer_ = event->pt;
      if (!self->capturing_) return CallNextHookEx(nullptr, code, message, param);
      if (!self->events_.empty() && self->events_.back().kind == kMove) {
        self->events_.back().point = event->pt;
      } else {
        self->events_.push_back({kMove, nullptr, event->pt, Settings{}});
        PostThreadMessage(self->thread_id_, kMove, 0, 0);
      }
      // Never swallow movement: Windows must advance the system cursor.
      // Consuming the initiating button pair already prevents application drags.
      return CallNextHookEx(nullptr, code, message, param);
    } else if (self->swallow_ && message == WM_LBUTTONUP) {
      self->events_.push_back({kEnd, nullptr, event->pt, Settings{}});
      self->swallow_ = false;
      self->capturing_ = false;
      PostThreadMessage(self->thread_id_, kEnd, 0, 0);
      return 1;
    }
    return CallNextHookEx(nullptr, code, message, param);
  }
  static LRESULT CALLBACK KeyboardHook(int code, WPARAM message, LPARAM param) {
    auto* self = current_;
    if (code >= 0 && self) {
      auto* event = reinterpret_cast<KBDLLHOOKSTRUCT*>(param);
      ++self->keyboard_events_;
      if (!AcceptKeyboardInput(*event)) return CallNextHookEx(nullptr, code, message, param);
      if (self->swallow_ && self->capturing_ && !self->moving_) {
        const DWORD vk = event->vkCode;
        const bool shift = vk == VK_SHIFT || vk == VK_LSHIFT || vk == VK_RSHIFT;
        const bool alt = vk == VK_MENU || vk == VK_LMENU || vk == VK_RMENU;
        if ((shift && self->captured_ratio_modifier_ == kShift) || (alt && self->captured_ratio_modifier_ == kAlt))
          self->ratio_ = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
      }
      if (self->swallow_ && self->capturing_ &&
          (message == WM_KEYUP || message == WM_SYSKEYUP)) {
        const DWORD vk = event->vkCode;
        int released = 0;
        if ((vk == VK_LCONTROL && !(GetAsyncKeyState(VK_RCONTROL) & 0x8000)) ||
            (vk == VK_RCONTROL && !(GetAsyncKeyState(VK_LCONTROL) & 0x8000)) || vk == VK_CONTROL) released = kCtrl;
        else if ((vk == VK_LMENU && !(GetAsyncKeyState(VK_RMENU) & 0x8000)) ||
                 (vk == VK_RMENU && !(GetAsyncKeyState(VK_LMENU) & 0x8000)) || vk == VK_MENU) released = kAlt;
        else if ((vk == VK_LSHIFT && !(GetAsyncKeyState(VK_RSHIFT) & 0x8000)) ||
                 (vk == VK_RSHIFT && !(GetAsyncKeyState(VK_LSHIFT) & 0x8000)) || vk == VK_SHIFT) released = kShift;
        else if ((vk == VK_LWIN && !(GetAsyncKeyState(VK_RWIN) & 0x8000)) ||
                 (vk == VK_RWIN && !(GetAsyncKeyState(VK_LWIN) & 0x8000))) released = kMeta;
        if (released & self->captured_mask_) {
          self->capturing_ = false;
          self->events_.push_back({kRelease, nullptr, self->pointer_, Settings{}});
          PostThreadMessage(self->thread_id_, kRelease, 0, 0);
        }
      }
      if (event->vkCode == VK_ESCAPE) {
        if ((message == WM_KEYDOWN || message == WM_SYSKEYDOWN) && self->swallow_) {
          self->escape_down_ = true;
          self->capturing_ = false;
          PostThreadMessage(self->thread_id_, kCancel, 0, 0);
          return 1;
        }
        if (self->escape_down_) {
          if (message == WM_KEYUP || message == WM_SYSKEYUP) self->escape_down_ = false;
          return 1;
        }
      }
    }
    return CallNextHookEx(nullptr, code, message, param);
  }
  void Run(std::promise<void>& ready) {
    SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    current_ = this;
    thread_id_ = GetCurrentThreadId();
    MSG message{};
    PeekMessage(&message, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
    RefreshHooks();
    const UINT_PTR watchdog = SetTimer(nullptr, 0, 1000, nullptr);
    SeedSeenWindows();
    ready.set_value();
    while (GetMessage(&message, nullptr, 0, 0) > 0) {
#ifdef WINDOW_CONTROL_NATIVE_TEST
      if (message.message == WM_APP + 90) {
        swallow_ = message.wParam != 0;
        capturing_ = false;
        test_capture_ready_ = true;
      }
#endif
      if (message.hwnd == nullptr) {
        if (message.message == kBegin || message.message == kMove || message.message == kEnd || message.message == kRelease) {
          if (!events_.empty()) {
            const auto event = events_.front();
            events_.pop_front();
            latest_ = event.point;
            if (event.kind == kBegin) {
              target_ = event.target;
              origin_ = event.point;
              gesture_revision_ = event.revision;
              gesture_settings_ = event.settings;
              moving_ = event.moving;
              ratio_ = event.ratio;
              Begin();
            } else if (event.kind == kMove) Move();
            else if (event.kind == kRelease) Release();
            else End(false);
          }
        }
        else if (message.message == kConfigureMemory) SeedSeenWindows();
        else if (message.message == kFinishRemember) PollMemory();
        else if (message.message == kCancel) End(true);
        else if (message.message == kRefreshHooks ||
                 (message.message == WM_TIMER && message.wParam == watchdog)) {
          bool enabled;
          { std::lock_guard<std::mutex> lock(mutex_); enabled = settings_.enabled; }
          if (enabled && !swallow_ && GetTickCount64() - last_refresh_ > 10000) RefreshHooks();
          PollMemory();
        }
      }
      TranslateMessage(&message);
      DispatchMessage(&message);
    }
    End(true);
    if (watchdog) KillTimer(nullptr, watchdog);
    if (mouse_hook_) UnhookWindowsHookEx(mouse_hook_);
    if (keyboard_hook_) UnhookWindowsHookEx(keyboard_hook_);
    current_ = nullptr;
  }
  void RefreshHooks() {
    // Windows can silently remove timed-out low-level hooks. Reinstall on
    // enable and periodically while idle instead of trusting stale handles.
    HHOOK mouse = SetWindowsHookEx(WH_MOUSE_LL, MouseHook, GetModuleHandle(nullptr), 0);
    DWORD error = mouse ? 0 : GetLastError();
    HHOOK keyboard = SetWindowsHookEx(WH_KEYBOARD_LL, KeyboardHook, GetModuleHandle(nullptr), 0);
    if (!keyboard) error = GetLastError();
    if (mouse_hook_) UnhookWindowsHookEx(mouse_hook_);
    if (keyboard_hook_) UnhookWindowsHookEx(keyboard_hook_);
    mouse_hook_ = mouse;
    keyboard_hook_ = keyboard;
    if (!mouse || !keyboard) {
      if (mouse_hook_) UnhookWindowsHookEx(mouse_hook_);
      if (keyboard_hook_) UnhookWindowsHookEx(keyboard_hook_);
      mouse_hook_ = nullptr;
      keyboard_hook_ = nullptr;
    }
    hooks_ok_ = mouse_hook_ && keyboard_hook_;
    last_refresh_ = GetTickCount64();
    std::lock_guard<std::mutex> lock(mutex_);
    hook_error_ = error;
  }
  void Begin() {
    active_ = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      // A queued button-down must never resurrect a gesture after disable or
      // reconfiguration raced with hit-testing in the input callback.
      if (!settings_.enabled || gesture_revision_ != settings_revision_) return;
    }
    if (!Allowed(target_) || IsExcluded(target_) || !GetWindowRect(target_, &initial_)) return;
    original_ = SavedWindow{};
    original_.window = target_;
    GetWindowThreadProcessId(target_, &original_.pid);
    if (!GetWindowPlacement(target_, &original_.placement)) return;
    if (IsZoomed(target_)) return;
    original_.frame = initial_;
    if (moving_) {
      // Raise for this interaction without changing the window's persistent
      // topmost style. Geometry updates keep the resulting z-order unchanged.
      SetWindowPos(target_, HWND_TOP, 0, 0, 0, 0,
          SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_ASYNCWINDOWPOS);
      SetForegroundWindow(target_);
    }
    ++gesture_id_;
    left_anchor_ = origin_.x < (initial_.left + initial_.right) / 2;
    top_anchor_ = origin_.y < (initial_.top + initial_.bottom) / 2;
    minimum_ = {std::min(160L, initial_.right - initial_.left),
                std::min(100L, initial_.bottom - initial_.top)};
    maximum_ = {GetSystemMetrics(SM_CXVIRTUALSCREEN), GetSystemMetrics(SM_CYVIRTUALSCREEN)};
    MINMAXINFO limits{};
    limits.ptMinTrackSize = minimum_;
    limits.ptMaxTrackSize = maximum_;
    DWORD_PTR response = 0;
    // Run outside the hook callback and bound calls into unresponsive targets.
    if (SendMessageTimeout(target_, WM_GETMINMAXINFO, 0, reinterpret_cast<LPARAM>(&limits),
        SMTO_ABORTIFHUNG | SMTO_BLOCK, 30, &response)) {
      minimum_.x = std::max(1L, limits.ptMinTrackSize.x);
      minimum_.y = std::max(1L, limits.ptMinTrackSize.y);
      maximum_.x = std::max(minimum_.x, limits.ptMaxTrackSize.x);
      maximum_.y = std::max(minimum_.y, limits.ptMaxTrackSize.y);
    }
    horizontal_ = true;
    vertical_ = true;
    if (!moving_ && !ratio_ && gesture_settings_.edgeResize) {
      const LONG margin = std::max(8L, static_cast<LONG>(MulDiv(16, static_cast<int>(GetDpiForWindow(target_)), 96)));
      const bool nearX = origin_.x - initial_.left <= margin || initial_.right - origin_.x <= margin;
      const bool nearY = origin_.y - initial_.top <= margin || initial_.bottom - origin_.y <= margin;
      if (nearX && !nearY) vertical_ = false;
      if (nearY && !nearX) horizontal_ = false;
    }
    active_ = true;
    changed_ = false;
    Diagnose(moving_ ? "正在移动，已将目标窗口带到前景" : "正在自由缩放");
  }
  void Move() {
    if (!active_ || !IsWindow(target_)) return;
    const LONG dx = latest_.x - origin_.x;
    const LONG dy = latest_.y - origin_.y;
    if (!changed_ && std::abs(dx) < 3 && std::abs(dy) < 3) return;
    RECT frame = initial_;
    // Width/height derive only from the press snapshot and total pointer delta.
    // Neither asynchronous target feedback nor a previous sample changes anchors.
    if (moving_) {
      OffsetRect(&frame, dx, dy);
    } else {
      LONG width = initial_.right - initial_.left;
      LONG height = initial_.bottom - initial_.top;
      if (horizontal_ || ratio_) width = std::clamp(width + (left_anchor_ ? -dx : dx), minimum_.x, maximum_.x);
      if (vertical_ || ratio_) height = std::clamp(height + (top_anchor_ ? -dy : dy), minimum_.y, maximum_.y);
      if (ratio_) {
        const double aspect = static_cast<double>(initial_.right - initial_.left) / (initial_.bottom - initial_.top);
        const double scaleX = static_cast<double>(width) / (initial_.right - initial_.left);
        const double scaleY = static_cast<double>(height) / (initial_.bottom - initial_.top);
        double scale = std::abs(scaleX - 1.0) >= std::abs(scaleY - 1.0) ? scaleX : scaleY;
        const double low = std::max(static_cast<double>(minimum_.x) / (initial_.right - initial_.left),
                                    static_cast<double>(minimum_.y) / (initial_.bottom - initial_.top));
        const double high = std::min(static_cast<double>(maximum_.x) / (initial_.right - initial_.left),
                                     static_cast<double>(maximum_.y) / (initial_.bottom - initial_.top));
        scale = std::clamp(scale, low, std::max(low, high));
        width = static_cast<LONG>(std::lround((initial_.right - initial_.left) * scale));
        height = static_cast<LONG>(std::lround(width / aspect));
      }
      if (left_anchor_) frame.left = frame.right - width; else frame.right = frame.left + width;
      if (top_anchor_) frame.top = frame.bottom - height; else frame.bottom = frame.top + height;
    }
    geometry_.Submit({original_, frame, gesture_id_, false, left_anchor_, top_anchor_});
    changed_ = true;
  }
  void Release() {
    // Releasing modifiers finishes the latest resize in place.
    // Preserve the consumed mouse pair until the physical left-button release.
    if (active_ && changed_) Finish(original_);
    active_ = false;
  }
  void End(bool cancel) {
    if (active_) {
      if (cancel) {
        geometry_.Submit({original_, {}, gesture_id_, true});
      } else {
        Move();
        if (changed_) Finish(original_);
      }
    }
    active_ = false;
    // swallow_ remains until physical button-up, including after Escape/configure.
  }
  static thread_local Impl* current_;
  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
  std::thread worker_;
  DWORD thread_id_ = 0;
  std::mutex mutex_;
  Settings settings_;
  uint64_t settings_revision_ = 0;
  uint64_t gesture_revision_ = 0;
  HWND owner_ = nullptr;
  NOTIFYICONDATA tray_{};
  bool tray_added_ = false;
  bool exiting_ = false;
  UINT taskbar_created_ = RegisterWindowMessage(L"TaskbarCreated");
  std::deque<SavedWindow> history_;
  Settings gesture_settings_;
  bool moving_ = false;
  bool ratio_ = false;
  bool horizontal_ = true;
  bool vertical_ = true;
  ULONGLONG last_refresh_ = 0;
  std::map<std::wstring, RECT> remembered_;
  std::map<HWND, DWORD> seen_;
  struct PendingRemember { HWND window; DWORD pid; ULONGLONG when; };
  std::deque<PendingRemember> pending_remember_;
  GeometryQueue geometry_;
  uint64_t gesture_id_ = 0;
  SavedWindow last_;
  SavedWindow original_;
  std::atomic<bool> hooks_ok_{false};
  std::atomic<uint64_t> mouse_events_{0};
  std::atomic<uint64_t> keyboard_events_{0};
  HHOOK mouse_hook_ = nullptr;
  HHOOK keyboard_hook_ = nullptr;
  DWORD hook_error_ = 0;
  int last_mask_ = 0;
  std::string last_class_ = "尚未命中";
  std::string last_reason_ = "请按住快捷键并在其他应用窗口内拖动左键";
#ifdef WINDOW_CONTROL_NATIVE_TEST
  std::atomic<bool> test_capture_ready_{false};
#endif
  bool swallow_ = false;
  bool capturing_ = false;
  int captured_mask_ = 0;
  int captured_ratio_modifier_ = kShift;
  bool escape_down_ = false;
  std::deque<InputEvent> events_;
  bool active_ = false;
  bool left_anchor_ = false;
  bool top_anchor_ = false;
  bool changed_ = false;
  HWND target_ = nullptr;
  POINT minimum_{};
  POINT maximum_{};
  POINT origin_{};
  POINT latest_{};
  POINT pointer_{};
  RECT initial_{};
};
thread_local WindowGestureController::Impl* WindowGestureController::Impl::current_ = nullptr;
WindowGestureController::WindowGestureController(flutter::BinaryMessenger* messenger, HWND owner)
    : impl_(std::make_unique<Impl>(messenger, owner)) {}
std::optional<LRESULT> WindowGestureController::HandleMessage(UINT message, WPARAM wp, LPARAM lp) {
  return impl_->HandleMessage(message, wp, lp);
}
WindowGestureController::~WindowGestureController() = default;
