// Standalone integration harness. The only manipulated HWND belongs to a child
// process of this test. Tagged SendInput exercises the real OS hook chain.
#include "../window_gesture_controller.cpp"
#include <iostream>

namespace {
class TestMessenger : public flutter::BinaryMessenger {
 public:
  void Send(const std::string&, const uint8_t*, size_t, flutter::BinaryReply) const override {}
  void SetMessageHandler(const std::string&, flutter::BinaryMessageHandler handler) override {
    handler_ = std::move(handler);
  }
  flutter::BinaryMessageHandler handler_;
};
LRESULT CALLBACK HostProc(HWND hwnd, UINT message, WPARAM wp, LPARAM lp) {
  if (message == WM_GETMINMAXINFO) {
    auto* limits = reinterpret_cast<MINMAXINFO*>(lp);
    limits->ptMinTrackSize = {320, 240};
    limits->ptMaxTrackSize = {4000, 3000};
    return 0;
  }
  if (message == WM_WINDOWPOSCHANGING) {
    auto* pos = reinterpret_cast<WINDOWPOS*>(lp);
    if (!(pos->flags & SWP_NOSIZE)) {
      auto count = reinterpret_cast<INT_PTR>(GetProp(hwnd, L"TestResizeCount"));
      SetProp(hwnd, L"TestResizeCount", reinterpret_cast<HANDLE>(count + 1));
      if (GetProp(hwnd, L"TestSlow")) Sleep(12);
      if (GetProp(hwnd, L"TestClamp")) {
        pos->cx = std::max(pos->cx, 450);
        pos->cy = std::max(pos->cy, 330);
      }
    }
  }
  if (message == WM_DESTROY) { PostQuitMessage(0); return 0; }
  return DefWindowProc(hwnd, message, wp, lp);
}
struct FindHost { DWORD pid; HWND window; };
BOOL CALLBACK FindTestWindow(HWND hwnd, LPARAM param) {
  auto* host = reinterpret_cast<FindHost*>(param);
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  if (pid == host->pid && IsWindowVisible(hwnd)) { host->window = hwnd; return FALSE; }
  return TRUE;
}
bool WaitFrame(HWND hwnd, const RECT& expected) {
  for (int i = 0; i < 300; ++i) {
    RECT actual{};
    GetWindowRect(hwnd, &actual);
    if (EqualRect(&actual, &expected)) return true;
    Sleep(20);
  }
  return false;
}
int RunHost() {
  WNDCLASS klass{};
  klass.hInstance = GetModuleHandle(nullptr);
  klass.lpszClassName = L"WindowControlNativeTestHost";
  klass.lpfnWndProc = HostProc;
  RegisterClass(&klass);
  MONITORINFO info{sizeof(MONITORINFO)};
  GetMonitorInfo(MonitorFromPoint({0, 0}, MONITOR_DEFAULTTOPRIMARY), &info);
  HWND window = CreateWindow(klass.lpszClassName, L"Window Control isolated native test",
      WS_OVERLAPPEDWINDOW, info.rcWork.left + 160, info.rcWork.top + 100,
      600, 400, nullptr, nullptr, klass.hInstance, nullptr);
  ShowWindow(window, SW_SHOWNOACTIVATE);
  MSG msg{};
  while (GetMessage(&msg, nullptr, 0, 0) > 0) { TranslateMessage(&msg); DispatchMessage(&msg); }
  return 0;
}
}  // namespace

class NativeGestureTest {
 public:
  static int Run(HWND host) {
    TestMessenger messenger;
    WindowGestureController controller(&messenger);
    auto& native = *controller.impl_;
    Check(native.hooks_ok_, "global mouse and keyboard hook installation");
    const auto status = std::get<Map>(native.Status());
    Check(!std::get<bool>(status.at(Value("enabled"))), "service starts disabled");
    Map settings{
      {Value("enabled"), Value(true)},
      {Value("resizeKeys"), Value(flutter::EncodableList{Value("ctrl"), Value("alt")})}
    };
    auto invoke = [&](const Map& args) {
      flutter::MethodCall<Value> call("configure", std::make_unique<Value>(args));
      auto bytes = flutter::StandardMethodCodec::GetInstance().EncodeMethodCall(call);
      bool replied = false;
      messenger.handler_(bytes->data(), bytes->size(), [&](const uint8_t*, size_t) { replied = true; });
      Check(replied, "configuration channel responds");
    };
    invoke(settings);
    Check(std::get<bool>(std::get<Map>(native.Status()).at(Value("enabled"))), "valid configure enables service");
    // Only relative movement, no keys or clicks: verifies cursor advancement.
    const auto hookEventsBefore = native.mouse_events_.load();
    POINT moveBefore{};
    GetCursorPos(&moveBefore);
    native.test_capture_ready_ = false;
    PostThreadMessage(native.thread_id_, WM_APP + 90, 1, 0);
    for (int i = 0; i < 100 && !native.test_capture_ready_; ++i) Sleep(5);
    INPUT relative{};
    relative.type = INPUT_MOUSE;
    relative.mi.dwFlags = MOUSEEVENTF_MOVE;
    relative.mi.dx = -20;
    relative.mi.dy = -10;
    relative.mi.dwExtraInfo = kTestInputMarker;
    Check(SendInput(1, &relative, sizeof(INPUT)) == 1, "relative OS mouse sample accepted");
    Sleep(50);
    POINT moveAfter{};
    GetCursorPos(&moveAfter);
    std::cout << "OBSERVATION captured move cursor before=" << moveBefore.x << "," << moveBefore.y
              << " after=" << moveAfter.x << "," << moveAfter.y << std::endl;
    const bool capturedAdvanced = moveAfter.x != moveBefore.x || moveAfter.y != moveBefore.y;
    native.test_capture_ready_ = false;
    PostThreadMessage(native.thread_id_, WM_APP + 90, 0, 0);
    for (int i = 0; i < 100 && !native.test_capture_ready_; ++i) Sleep(5);
    Check(SendInput(1, &relative, sizeof(INPUT)) == 1, "relative control mouse sample accepted");
    Sleep(50);
    GetCursorPos(&moveAfter);
    std::cout << "EVIDENCE passed move cursor after=" << moveAfter.x << "," << moveAfter.y << std::endl;
    const bool controlAdvanced = moveAfter.x != moveBefore.x || moveAfter.y != moveBefore.y;
    if (controlAdvanced && native.mouse_events_.load() > hookEventsBefore)
      Check(capturedAdvanced, "captured mouse movement advances cursor like uncaptured control");
    else std::cout << "SKIP relative cursor regression: no delivered hook callbacks or desktop ignores control input" << std::endl;
    SetCursorPos(moveBefore.x, moveBefore.y);
    // End-to-end input uses the real Windows hook, hit-testing, key state,
    // mouse stream and geometry worker. Only the dedicated child window is used.
    POINT savedCursor{};
    GetCursorPos(&savedCursor);
    RECT e2eInitial{};
    GetWindowRect(host, &e2eInitial);
    SetWindowPos(host, HWND_TOPMOST, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    auto key = [&](WORD vk, bool up) {
      INPUT input{};
      input.type = INPUT_KEYBOARD;
      input.ki.wVk = vk;
      input.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
      input.ki.dwExtraInfo = 0x57435445;
      Check(SendInput(1, &input, sizeof(INPUT)) == 1, "OS accepts tagged key input");
      Sleep(25);
    };
    auto mouse = [&](DWORD flags, LONG x, LONG y) {
      INPUT input{};
      input.type = INPUT_MOUSE;
      input.mi.dwFlags = flags;
      if (flags & MOUSEEVENTF_MOVE) {
        input.mi.dwFlags |= MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
        input.mi.dx = (x - GetSystemMetrics(SM_XVIRTUALSCREEN)) * 65536 / GetSystemMetrics(SM_CXVIRTUALSCREEN);
        input.mi.dy = (y - GetSystemMetrics(SM_YVIRTUALSCREEN)) * 65536 / GetSystemMetrics(SM_CYVIRTUALSCREEN);
      }
      input.mi.dwExtraInfo = 0x57435445;
      Check(SendInput(1, &input, sizeof(INPUT)) == 1, "OS accepts tagged mouse input");
      Sleep(35);
    };
    const POINT start{e2eInitial.left + 420, e2eInitial.top + 260};
    mouse(MOUSEEVENTF_MOVE, start.x, start.y);
    wchar_t hitClass[128]{};
    HWND hit = GetAncestor(WindowFromPoint(start), GA_ROOT);
    GetClassName(hit, hitClass, 128);
    POINT observedCursor{};
    GetCursorPos(&observedCursor);
    std::wcout << L"E2E hit host=" << host << L" hit=" << hit << L" class=" << hitClass
               << L" point=" << start.x << L"," << start.y << L" cursor=" << observedCursor.x << L"," << observedCursor.y << std::endl;

    if (hit == host && std::abs(observedCursor.x - start.x) <= 2 && std::abs(observedCursor.y - start.y) <= 2) {
      key(VK_LCONTROL, false);
      key(VK_LMENU, false);
      mouse(MOUSEEVENTF_LEFTDOWN, 0, 0);
      mouse(MOUSEEVENTF_MOVE, start.x + 80, start.y + 60);
      mouse(MOUSEEVENTF_LEFTUP, 0, 0);
      key(VK_LMENU, true);
      key(VK_LCONTROL, true);
      native.geometry_.WaitIdle();
      RECT e2eActual{};
      GetWindowRect(host, &e2eActual);
      Check(std::abs((e2eActual.right - e2eActual.left) - (e2eInitial.right - e2eInitial.left) - 80) <= 2 &&
          std::abs((e2eActual.bottom - e2eActual.top) - (e2eInitial.bottom - e2eInitial.top) - 60) <= 2,
          "OS SendInput through hooks and hit-test resizes the child window");
      native.geometry_.Submit({native.last_, {}, 0, true});
      Check(native.geometry_.WaitIdle() && WaitFrame(host, e2eInitial), "OS-driven resize restores test child window");
    } else {
      std::cout << "SKIP physical OS E2E: current desktop prevents cursor/hit-test reaching test HWND; no key or click sent" << std::endl;
    }
    mouse(MOUSEEVENTF_MOVE, savedCursor.x, savedCursor.y);
    SetWindowPos(host, HWND_NOTOPMOST, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    MSLLHOOKSTRUCT injectedMouse{};
    injectedMouse.flags = LLMHF_INJECTED;
    injectedMouse.dwExtraInfo = kTestInputMarker;
    Check((injectedMouse.flags & LLMHF_INJECTED) != 0 && AcceptMouseInput(injectedMouse),
        "tagged injected mouse formerly always rejected now passes input filter");
    injectedMouse.flags |= LLMHF_LOWER_IL_INJECTED;
    Check(!AcceptMouseInput(injectedMouse), "lower-integrity mouse input remains rejected");
    KBDLLHOOKSTRUCT injectedKey{};
    injectedKey.flags = LLKHF_INJECTED;
    injectedKey.dwExtraInfo = kTestInputMarker;
    Check(AcceptKeyboardInput(injectedKey), "tagged injected keyboard input passes input filter");
    injectedKey.flags |= LLKHF_LOWER_IL_INJECTED;
    Check(!AcceptKeyboardInput(injectedKey), "lower-integrity keyboard input remains rejected");
    settings[Value("enabled")] = Value(false);
    settings[Value("resizeKeys")] = Value(flutter::EncodableList{});
    invoke(settings);
    Check(!std::get<bool>(std::get<Map>(native.Status()).at(Value("enabled"))),
        "disable remains effective even when shortcut settings invalid");
    Map login = settings;
    login[Value("enabled")] = Value(false);
    login[Value("resizeKeys")] = Value(flutter::EncodableList{Value("ctrl"), Value("alt")});
    login[Value("launchAtLogin")] = Value(true);
    const int writes = startup_write_count;
    invoke(login);
    Check(startup_write_count == writes, "configure without explicit user intent never writes startup");
    login[Value("applyLaunchAtLogin")] = Value(true);
    invoke(login);
    Check(startup_write_count == writes + 1, "explicit login toggle calls isolated startup adapter");
    login[Value("launchAtLogin")] = Value(false);
    invoke(login);
    // Stop monitoring before deterministic event replay. Native drag methods are
    // then called directly, never synthesizing system input or touching other HWNDs.
    PostThreadMessage(native.thread_id_, WM_QUIT, 0, 0);
    native.worker_.join();
    // Deterministic callback-level regression, separate from physical OS E2E.
    // A local hook-chain sentinel makes forwarding observable without moving or
    // clicking any actual application window.
    WindowGestureController::Impl::current_ = &native;
    native.swallow_ = true;
    native.capturing_ = true;
    MSLLHOOKSTRUCT callbackMove{};
    callbackMove.pt = {123, 234};
    callbackMove.flags = LLMHF_INJECTED;
    callbackMove.dwExtraInfo = kTestInputMarker;
    const LRESULT forwarded = CallNextHookEx(nullptr, HC_ACTION, WM_MOUSEMOVE,
        reinterpret_cast<LPARAM>(&callbackMove));
    const size_t queuedBefore = native.events_.size();
    Check(WindowGestureController::Impl::MouseHook(HC_ACTION, WM_MOUSEMOVE,
        reinterpret_cast<LPARAM>(&callbackMove)) == forwarded &&
        native.events_.size() == queuedBefore + 1 && native.events_.back().kind == kMove,
        "callback: captured movement forwards hook chain and queues latest point");
    native.capturing_ = false;
    Check(WindowGestureController::Impl::MouseHook(HC_ACTION, WM_MOUSEMOVE,
        reinterpret_cast<LPARAM>(&callbackMove)) == forwarded,
        "callback: post-release movement forwards hook chain");
    Check(WindowGestureController::Impl::MouseHook(HC_ACTION, WM_LBUTTONUP,
        reinterpret_cast<LPARAM>(&callbackMove)) == 1 && !native.swallow_,
        "callback: consumed left-button pair still swallows its release");
    native.events_.clear();
    WindowGestureController::Impl::current_ = nullptr;
    native.settings_.enabled = true;
    native.gesture_revision_ = native.settings_revision_;
    Check(Allowed(host), "separate-process resizable test window accepted");
    Check(!Allowed(GetShellWindow()), "desktop shell rejected");
    native.target_ = host;
    native.settings_.enabled = false;
    native.Begin();
    Check(!native.active_, "queued gesture cannot start after service disable");
    native.settings_.enabled = true;
    ++native.gesture_revision_;
    native.Begin();
    Check(!native.active_, "stale queued gesture cannot start after reconfiguration");
    native.gesture_revision_ = native.settings_revision_;
    RECT initial{};
    GetWindowRect(host, &initial);
    native.origin_ = {(initial.left + initial.right) / 2 + 10,
                      (initial.top + initial.bottom) / 2 + 10};
    native.latest_ = native.origin_;
    native.Begin();
    Check(native.minimum_.x == 320 && native.minimum_.y == 240,
        "target WM_GETMINMAXINFO constraints read");
    native.latest_ = {native.origin_.x - 2000, native.origin_.y - 2000};
    native.Move();
    RECT smallest{initial.left, initial.top, initial.left + 320, initial.top + 240};
    Check(WaitFrame(host, smallest), "resize obeys target minimum dimensions");
    native.End(true);
    Check(native.geometry_.WaitIdle() && WaitFrame(host, initial), "Escape cancellation restores original frame");
    // Each corner must keep its opposite corner fixed throughout the drag.
    for (int corner = 0; corner < 4; ++corner) {
      const bool left = (corner & 1) != 0;
      const bool top = (corner & 2) != 0;
      native.origin_ = {left ? initial.left + 30 : initial.right - 30,
                        top ? initial.top + 30 : initial.bottom - 30};
      native.latest_ = native.origin_;
      native.Begin();
      native.latest_ = {native.origin_.x + (left ? -80 : 80),
                        native.origin_.y + (top ? -60 : 60)};
      native.Move();
      native.End(false);
      RECT expected = initial;
      if (left) expected.left -= 80; else expected.right += 80;
      if (top) expected.top -= 60; else expected.bottom += 60;
      Check(native.geometry_.WaitIdle() && WaitFrame(host, expected), "quadrant resize keeps opposite corner fixed");
      native.geometry_.Submit({native.last_, {}, 0, true});
      Check(native.geometry_.WaitIdle() && WaitFrame(host, initial), "committed quadrant resize restores");
    }
    native.origin_ = {initial.left + 30, initial.top + 30};
    native.latest_ = native.origin_;
    native.Begin();
    native.latest_ = {native.origin_.x + 400, native.origin_.y + 300};
    SetProp(host, L"TestClamp", reinterpret_cast<HANDLE>(1));
    // The former path trusts the requested minimum dimensions. A target with
    // additional constraints grows toward the supposedly fixed right/bottom.
    RECT legacyClamped{initial.right - 320, initial.bottom - 240,
                       initial.right - 320 + 450, initial.bottom - 240 + 330};
    SetWindowPos(host, nullptr, initial.right - 320, initial.bottom - 240, 320, 240,
        SWP_ASYNCWINDOWPOS | SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOOWNERZORDER);
    Check(WaitFrame(host, legacyClamped), "legacy application clamp reproduces opposite-corner drift");
    std::cout << "EVIDENCE legacy clamp: fixed corner drift_x=130 drift_y=90\n";
    native.Move();
    RECT clamped{initial.right - 450, initial.bottom - 330, initial.right, initial.bottom};
    Check(native.geometry_.WaitIdle() && WaitFrame(host, clamped),
        "unadvertised application size constraints preserve fixed opposite corner");
    native.End(true);
    RemoveProp(host, L"TestClamp");
    Check(native.geometry_.WaitIdle() && WaitFrame(host, initial), "clamped resize cancels cleanly");

    // Evidence for the old update strategy: queue 80 async requests against a
    // target that spends 12ms handling each resize. The pointer burst has ended,
    // yet the target continues to process stale intermediate sizes for ~1s.
    SetProp(host, L"TestSlow", reinterpret_cast<HANDLE>(1));
    SetProp(host, L"TestResizeCount", nullptr);
    const auto before = GetTickCount64();
    for (int sample = 1; sample <= 80; ++sample)
      SetWindowPos(host, nullptr, initial.left, initial.top,
          initial.right - initial.left + sample, initial.bottom - initial.top + sample,
          SWP_ASYNCWINDOWPOS | SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOOWNERZORDER);
    RECT legacyFinal = initial;
    legacyFinal.right += 80;
    legacyFinal.bottom += 80;
    Check(WaitFrame(host, legacyFinal), "legacy async reproduction finishes");
    const auto legacyTime = GetTickCount64() - before;
    const auto legacyCount = reinterpret_cast<INT_PTR>(GetProp(host, L"TestResizeCount"));
    std::cout << "EVIDENCE legacy async: requests=80 applied=" << legacyCount
              << " drain_ms=" << legacyTime << '\n';
    Check(legacyCount >= 70 && legacyTime >= 500, "legacy path reproduces stale resize backlog");
    RemoveProp(host, L"TestSlow");
    native.geometry_.Submit({native.original_, {}, 0, true});
    Check(native.geometry_.WaitIdle() && WaitFrame(host, initial), "legacy reproduction restores test window");

    SetProp(host, L"TestSlow", reinterpret_cast<HANDLE>(1));
    SetProp(host, L"TestResizeCount", nullptr);
    const size_t applicationsBefore = native.geometry_.Applied();
    const auto fixedStart = GetTickCount64();
    native.origin_ = {initial.right - 30, initial.bottom - 30};
    native.latest_ = native.origin_;
    native.Begin();
    for (int sample = 1; sample <= 2000; ++sample) {
      native.latest_ = {native.origin_.x + sample % 180, native.origin_.y + sample % 100};
      native.Move();
    }
    native.latest_ = {native.origin_.x + 120, native.origin_.y + 90};
    native.End(false);
    RECT finalFrame = initial;
    finalFrame.right += 120;
    finalFrame.bottom += 90;
    Check(native.geometry_.WaitIdle() && WaitFrame(host, finalFrame), "2000-sample rapid resize reaches latest frame");
    const auto fixedTime = GetTickCount64() - fixedStart;
    const size_t applied = native.geometry_.Applied() - applicationsBefore;
    std::cout << "EVIDENCE serialized latest-only: samples=2000 applied=" << applied
              << " drain_ms=" << fixedTime << '\n';
    Check(applied < 50, "rapid samples coalesce instead of accumulating target requests");
    native.geometry_.Submit({native.last_, {}, 0, true});
    Check(native.geometry_.WaitIdle() && WaitFrame(host, initial), "rapid resize restore wins over all stale updates");
    native.Begin();
    for (int sample = 0; sample < 1000; ++sample) {
      native.latest_ = {native.origin_.x + sample % 200, native.origin_.y + sample % 120};
      native.Move();
    }
    native.End(true);
    Check(native.geometry_.WaitIdle() && WaitFrame(host, initial), "rapid resize Escape discards pending updates and restores");
    RemoveProp(host, L"TestSlow");
    native.Begin();
    native.latest_ = {native.origin_.x + 70, native.origin_.y + 50};
    native.Move();
    native.Release();
    RECT released = initial;
    released.right += 70;
    released.bottom += 50;
    native.latest_ = {native.origin_.x + 300, native.origin_.y + 300};
    native.End(false);
    Check(native.geometry_.WaitIdle() && WaitFrame(host, released), "modifier release preserves last resize and stops further changes");
    native.geometry_.Submit({native.last_, {}, 0, true});
    Check(native.geometry_.WaitIdle() && WaitFrame(host, initial), "released resize remains restorable");
    // New-feature regressions use only our child-process window and never
    // enable persistent startup/remember settings on the developer account.
    native.history_.clear();
    native.moving_ = true;
    native.gesture_settings_.edgeResize = true;
    native.origin_ = {initial.left + 200, initial.top + 150};
    native.latest_ = native.origin_;
    native.Begin();
    native.latest_ = {native.origin_.x + 90, native.origin_.y + 70};
    native.Move();
    native.End(false);
    RECT moved = initial;
    OffsetRect(&moved, 90, 70);
    Check(native.geometry_.WaitIdle() && WaitFrame(host, moved), "move gesture translates window without changing size");
    Check(native.Undo() && native.geometry_.WaitIdle() && WaitFrame(host, initial), "move gesture supports undo");
    native.moving_ = false;
    native.ratio_ = true;
    native.origin_ = {initial.right - 40, initial.bottom - 40};
    native.latest_ = native.origin_;
    native.Begin();
    native.latest_ = {native.origin_.x + 120, native.origin_.y + 10};
    native.Move();
    native.End(false);
    RECT proportional = initial;
    proportional.right += 120;
    proportional.bottom += 80;
    Check(native.geometry_.WaitIdle() && WaitFrame(host, proportional), "ratio resize preserves original aspect and anchor");
    Check(native.Undo() && native.geometry_.WaitIdle() && WaitFrame(host, initial), "ratio resize undo restores both dimensions");
    native.ratio_ = false;
    native.origin_ = {initial.right - 3, initial.top + 200};
    native.latest_ = native.origin_;
    native.Begin();
    native.latest_ = {native.origin_.x + 50, native.origin_.y + 90};
    native.Move();
    native.End(false);
    RECT horizontal = initial;
    horizontal.right += 50;
    Check(native.geometry_.WaitIdle() && WaitFrame(host, horizontal), "side-edge resize changes width only");
    Check(native.Undo() && native.geometry_.WaitIdle() && WaitFrame(host, initial), "side-edge resize undo");
    native.origin_ = {initial.left + 250, initial.bottom - 3};
    native.latest_ = native.origin_;
    native.Begin();
    native.latest_ = {native.origin_.x + 80, native.origin_.y + 40};
    native.Move();
    native.End(false);
    RECT vertical = initial;
    vertical.bottom += 40;
    Check(native.geometry_.WaitIdle() && WaitFrame(host, vertical), "top-bottom edge resize changes height only");
    Check(native.Undo() && native.geometry_.WaitIdle() && WaitFrame(host, initial), "top-bottom edge resize undo");
    Map preset{{Value("windowId"), Value(WindowGestureController::Impl::WindowToken(host))},
               {Value("width"), Value(800)}, {Value("height"), Value(500)}, {Value("center"), Value(true)}};
    Map stale = preset;
    stale[Value("windowId")] = Value(std::to_string(reinterpret_cast<uintptr_t>(host)) + ":0");
    Check(!native.ApplyPreset(stale, false), "preset rejects mismatched process identity");
    Check(native.ApplyPreset(preset, false) && native.geometry_.WaitIdle(), "size preset applies to selected test window");
    RECT presetActual{};
    GetWindowRect(host, &presetActual);
    MONITORINFO presetMonitor{sizeof(MONITORINFO)};
    GetMonitorInfo(MonitorFromWindow(host, MONITOR_DEFAULTTONEAREST), &presetMonitor);
    Check(presetActual.right - presetActual.left == 800 && presetActual.bottom - presetActual.top == 500 &&
        presetActual.left == presetMonitor.rcWork.left + (presetMonitor.rcWork.right - presetMonitor.rcWork.left - 800) / 2,
        "size preset dimensions and work-area centering are exact");
    Check(native.Undo() && native.geometry_.WaitIdle() && WaitFrame(host, initial), "size preset joins undo history");
    native.settings_.excludedApps = {AppName(host)};
    Check(native.IsExcluded(host) && !native.ApplyPreset(preset, false), "excluded executable blocks presets");
    native.Begin();
    Check(!native.active_, "excluded executable blocks gesture start");
    native.settings_.excludedApps.clear();
    for (int step = 0; step < 25; ++step) native.Finish(native.original_);
    Check(native.history_.size() == 20, "undo history is bounded at twenty operations");
    SavedWindow invalid;
    native.history_.push_back(invalid);
    Check(native.Undo() && native.geometry_.WaitIdle(), "undo skips stale invalid history entries");
    native.history_.clear();
    Check(!native.Undo(), "empty undo returns false");
    RECT outside{-100000, -100000, -99200, -99500};
    RECT workClamped = ClampToWorkArea(outside);
    MONITORINFO clampMonitor{sizeof(MONITORINFO)};
    GetMonitorInfo(MonitorFromRect(&workClamped, MONITOR_DEFAULTTONEAREST), &clampMonitor);
    Check(workClamped.left >= clampMonitor.rcWork.left && workClamped.top >= clampMonitor.rcWork.top &&
        workClamped.right <= clampMonitor.rcWork.right && workClamped.bottom <= clampMonitor.rcWork.bottom,
        "remembered geometry clamps to currently available monitor work area");
    native.settings_.rememberWindows = true;
    native.SeedSeenWindows();
    native.remembered_[MemoryKey(host)] = proportional;
    native.PollMemory();
    Check(native.geometry_.WaitIdle() && WaitFrame(host, initial), "enabling memory does not move existing windows");
    native.seen_.erase(host);
    native.PollMemory();
    Check(native.geometry_.WaitIdle() && WaitFrame(host, proportional), "newly appearing test window restores app-class memory");
    native.geometry_.Submit({native.original_, {}, 0, true});
    Check(native.geometry_.WaitIdle() && WaitFrame(host, initial), "memory test restores child window");
    native.settings_.rememberWindows = false;
    Check(native.MemoryPath().empty(), "native tests disable all persistent geometry writes");
    Map conflict{{Value("enabled"), Value(true)},
                 {Value("resizeKeys"), Value(flutter::EncodableList{Value("ctrl"), Value("alt")})},
                 {Value("moveKeys"), Value(flutter::EncodableList{Value("ctrl"), Value("alt"), Value("shift")})}};
    const auto oldRevision = native.settings_revision_;
    invoke(conflict);
    Check(native.settings_revision_ == oldRevision, "move shortcut cannot collide with ratio-resize shortcut");
    std::cout << "DIAGNOSTICS " << std::get<std::string>(std::get<Map>(native.Status()).at(Value("message"))) << std::endl;
    HWND owner = CreateWindow(L"STATIC", L"Tray lifecycle test", WS_OVERLAPPEDWINDOW,
        0, 0, 300, 200, nullptr, nullptr, GetModuleHandle(nullptr), nullptr);
    Check(owner != nullptr, "tray lifecycle uses a test-owned settings window");
    if (owner) {
      TestMessenger trayMessenger;
      {
        WindowGestureController trayController(&trayMessenger, owner);
        auto& trayNative = *trayController.impl_;
        auto hidden = trayNative.HandleMessage(WM_CLOSE, 0, 0);
        Check(trayNative.tray_added_ ? hidden.has_value() : !hidden.has_value(),
            "close-to-tray hides only when system icon creation succeeded");
        trayNative.settings_.closeToTray = false;
        Check(!trayNative.HandleMessage(WM_CLOSE, 0, 0).has_value(), "disabled close-to-tray permits normal close");
      }
      DestroyWindow(owner);
    }
    std::cout << (failures_ ? "FAIL" : "PASS") << ": native integration checks=" << checks_ << "; failures=" << failures_ << '\n';
    return failures_ ? 1 : 0;
  }
 private:
  static void Check(bool condition, const char* label) {
    std::cout << (condition ? "PASS " : "FAIL ") << label << '\n';
    ++checks_;
    if (!condition) ++failures_;
  }
  static int failures_;
  static int checks_;
};
int NativeGestureTest::failures_ = 0;
int NativeGestureTest::checks_ = 0;

int wmain(int argc, wchar_t** argv) {
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  if (argc > 1 && wcscmp(argv[1], L"--host") == 0) return RunHost();
  wchar_t path[MAX_PATH]{};
  GetModuleFileName(nullptr, path, MAX_PATH);
  std::wstring command = L"\"" + std::wstring(path) + L"\" --host";
  STARTUPINFO startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!CreateProcess(nullptr, command.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW,
      nullptr, nullptr, &startup, &process)) return 2;
  FindHost host{process.dwProcessId, nullptr};
  for (int i = 0; i < 100 && !host.window; ++i) {
    EnumWindows(FindTestWindow, reinterpret_cast<LPARAM>(&host));
    if (!host.window) Sleep(20);
  }
  int result = host.window ? NativeGestureTest::Run(host.window) : 3;
  if (host.window) PostMessage(host.window, WM_CLOSE, 0, 0);
  WaitForSingleObject(process.hProcess, 3000);
  CloseHandle(process.hProcess);
  CloseHandle(process.hThread);
  return result;
}
