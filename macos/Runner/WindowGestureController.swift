import Cocoa
import ApplicationServices
import FlutterMacOS
import ServiceManagement

/// Native input stays local; only settings and status cross the Flutter channel.
final class WindowGestureController: NSObject, NSWindowDelegate, NSMenuDelegate {
  private let channel: FlutterMethodChannel
  private var tap: CFMachPort?
  private var source: CFRunLoopSource?
  private var timer: Timer?
  private var resizeKeys: Set<String> = ["ctrl", "alt"]
  private var moveKeys: Set<String> = ["ctrl", "shift"]
  private var excludedApps = Set<String>()
  private var edgeResize = true
  private var rememberWindows = false
  private var closeToTray = true
  private var moving = false
  private var ratioLocked = false
  private var capturedKeys = Set<String>()
  private var horizontalOnly = false
  private var verticalOnly = false
  private var history: [(AXUIElement, CGRect)] = []
  private var windowRefs: [String: AXUIElement] = [:]
  private var seenWindows = Set<String>()
  private var memory: [String: [String: Double]] = [:]
  private var memoryTimer: Timer?
  private var statusItem: NSStatusItem?
  weak var settingsWindow: NSWindow?
  private var message = "服务已暂停"
  private var target: AXUIElement?
  private var original = CGRect.zero
  private var start = CGPoint.zero
  private var pointer = CGPoint.zero
  private var left = false
  private var top = false
  private var dirty = false
  private var changed = false
  private var geometryRevision = 0
  private var swallowed = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "window_control/native", binaryMessenger: messenger)
    super.init()
    installMenu()
    loadMemory()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "getStatus": result(self.status())
      case "requestPermissions":
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestListenEventAccess()
        result(self.status())
      case "configure":
        guard let args = call.arguments as? [String: Any] else {
          result(FlutterError(code: "invalid_settings", message: "设置格式无效", details: nil)); return
        }
        if args["enabled"] as? Bool == false { self.stop() }
        guard let resize = args["resizeKeys"] as? [String], !resize.isEmpty,
              let move = args["moveKeys"] as? [String], !move.isEmpty else {
          result(FlutterError(code: "invalid_settings", message: "快捷键不能为空", details: nil)); return
        }
        let allowed: Set<String> = ["ctrl", "alt", "shift", "meta"]
        let r = Set(resize), m = Set(move)
        let extra = r.contains("shift") ? "alt" : "shift"
        guard r.isSubset(of: allowed), m.isSubset(of: allowed),
              r.count == resize.count, m.count == move.count,
              !r.contains(extra), r != m, r.union([extra]) != m else {
          result(FlutterError(code: "invalid_settings", message: "快捷键冲突，请为等比例预留 Shift 或 Alt", details: nil)); return
        }
        self.stop()
        self.resizeKeys = r; self.moveKeys = m
        self.excludedApps = Set((args["excludedApps"] as? [String] ?? []).map { $0.lowercased() })
        self.edgeResize = args["edgeResize"] as? Bool ?? true
        self.closeToTray = args["closeToTray"] as? Bool ?? true
        let remember = args["rememberWindows"] as? Bool ?? false
        if remember && !self.rememberWindows { _ = self.enumerateWindows(); self.seenWindows = Set(self.windowRefs.keys) }
        self.rememberWindows = remember
        if args["applyLaunchAtLogin"] as? Bool == true {
          do { try self.setLogin(args["launchAtLogin"] as? Bool ?? false) }
          catch { result(FlutterError(code: "login_failed", message: error.localizedDescription, details: nil)); return }
        }
        if args["enabled"] as? Bool == true { self.enable() }
        result(self.status())
      case "restoreLast": result(self.undo())
      case "listWindows": result(self.enumerateWindows())
      case "applyPreset", "centerWindow":
        guard let args = call.arguments as? [String: Any], let id = args["windowId"] as? String,
              let window = self.windowRefs[id], self.supported(window), let current = self.rectOf(window) else {
          result(false); return
        }
        var rect = current
        if call.method == "applyPreset" {
          guard let width = args["width"] as? Int, let height = args["height"] as? Int,
                width >= 100, width <= 16384, height >= 100, height <= 16384 else { result(false); return }
          rect.size = CGSize(width: CGFloat(width), height: CGFloat(height))
        }
        let work = self.workArea(current)
        if call.method == "centerWindow" || args["center"] as? Bool == true {
          rect.origin = CGPoint(x: work.midX - rect.width / 2, y: work.midY - rect.height / 2)
        }
        if call.method == "applyPreset" {
          var sizable: DarwinBoolean = false
          AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &sizable)
          guard sizable.boolValue else { result(false); return }
          rect = self.visibleRect(rect, work)
        }
        if rect == current { result(true); return }
        self.geometryRevision += 1
        let success = call.method == "centerWindow" ? self.position(window, rect.origin) : self.apply(window, rect)
        if success { self.pushUndo(window, current); self.saveWindow(window) }
        result(success)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  deinit {
    stop(); memoryTimer?.invalidate()
    if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
  }

  private func status() -> [String: Any] {
    let ax = AXIsProcessTrusted(), input = CGPreflightListenEventAccess()
    if tap != nil && (!ax || !input) { stop(); message = "权限已失效，请重新授权后启用" }
    return ["enabled": tap != nil, "accessibility": ax, "inputMonitoring": input, "message": message, "undoCount": history.count, "launchAtLogin": loginEnabled()]
  }

  private func enable() {
    guard AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
      message = "请在系统设置中允许辅助功能与输入监控，再刷新权限"; return
    }
    if rememberWindows { _ = enumerateWindows(); seenWindows = Set(windowRefs.keys) }
    let events: [CGEventType] = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .keyDown, .flagsChanged]
    let mask = events.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
      options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, info in
        guard let info = info else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<WindowGestureController>.fromOpaque(info).takeUnretainedValue()
        return controller.handle(type, event) ? nil : Unmanaged.passUnretained(event)
      }, userInfo: Unmanaged.passUnretained(self).toOpaque())
    guard let tap = tap else { message = "无法监听全局输入，请检查权限并重启应用"; return }
    source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    if let source = source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
    CGEvent.tapEnable(tap: tap, enable: true)
    timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.update() }
    if let timer = timer { RunLoop.main.add(timer, forMode: .common) }
    message = "服务运行中"
  }

  private func stop() {
    geometryRevision += 1
    finish(cancel: true)
    timer?.invalidate(); timer = nil
    if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
    if let source = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    tap = nil; source = nil; swallowed = false; message = "服务已暂停"
  }

  private func keys(_ flags: CGEventFlags) -> Set<String> {
    var value = Set<String>()
    if flags.contains(.maskControl) { value.insert("ctrl") }
    if flags.contains(.maskAlternate) { value.insert("alt") }
    if flags.contains(.maskShift) { value.insert("shift") }
    if flags.contains(.maskCommand) { value.insert("meta") }
    if flags.contains(.maskSecondaryFn) { value.insert("fn") }
    return value
  }

  private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      finish(cancel: true)
      if let tap = tap { CGEvent.tapEnable(tap: tap, enable: true) }
      return false
    }
    if type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 53 && target != nil {
      finish(cancel: true); return true
    }
    if type == .flagsChanged && target != nil {
      let held = keys(event.flags)
      if moving ? held != moveKeys : (held != resizeKeys && held != resizeKeys.union([ratioModifier])) {
        dirty = true; update(); finish(cancel: false)
      }
      ratioLocked = !moving && held.contains(ratioModifier)
      dirty = true
      return false
    }
    if type == .leftMouseUp && swallowed {
      pointer = event.location
      if target != nil { dirty = true; update() }
      finish(cancel: false); swallowed = false; return true
    }
    if type == .leftMouseDragged && swallowed {
      // Keep pointer motion flowing; only consume the initiating and ending clicks.
      pointer = event.location; dirty = target != nil; return false
    }
    guard type == .leftMouseDown, !swallowed else { return false }
    let held = keys(event.flags)
    guard held == moveKeys || held == resizeKeys || held == resizeKeys.union([ratioModifier]),
          let (window, rect) = windowAt(event.location, allowMoveOnly: held == moveKeys) else { return false }
    geometryRevision += 1
    target = window; original = rect; start = event.location; pointer = start
    moving = held == moveKeys
    if moving {
      var pid: pid_t = 0
      if AXUIElementGetPid(window, &pid) == .success {
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
      }
      _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
    capturedKeys = held
    ratioLocked = !moving && held.contains(ratioModifier)
    let nearX = min(start.x - rect.minX, rect.maxX - start.x) <= 16
    let nearY = min(start.y - rect.minY, rect.maxY - start.y) <= 16
    horizontalOnly = edgeResize && nearX && !nearY
    verticalOnly = edgeResize && nearY && !nearX
    left = start.x < rect.midX; top = start.y < rect.midY
    swallowed = true; changed = false
    return true
  }

  private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
    return value
  }

  private func windowAt(_ point: CGPoint, allowMoveOnly: Bool) -> (AXUIElement, CGRect)? {
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 0.02)
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
          let element = hit else { return nil }
    let window: AXUIElement
    if let role = attribute(element, kAXRoleAttribute) as? String, role == kAXWindowRole {
      window = element
    } else if let value = attribute(element, kAXWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
      window = unsafeBitCast(value, to: AXUIElement.self)
    } else { return nil }
    AXUIElementSetMessagingTimeout(window, 0.02)
    guard supported(window) else { return nil }
    var movable: DarwinBoolean = false, sizable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &movable)
    AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &sizable)
    guard movable.boolValue, (sizable.boolValue || allowMoveOnly),
          let p = attribute(window, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
          let s = attribute(window, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var position = CGPoint.zero; var size = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &position),
          AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
    return (window, CGRect(origin: position, size: size))
  }

  private func sizeOf(_ window: AXUIElement) -> CGSize? {
    guard let value = attribute(window, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size) else { return nil }
    return size
  }

  private func position(_ window: AXUIElement, _ point: CGPoint) -> Bool {
    var point = point
    guard let value = AXValueCreate(.cgPoint, &point) else { return false }
    return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
  }

  @discardableResult private func apply(_ window: AXUIElement, _ rect: CGRect,
                                        anchor: Bool = false) -> Bool {
    var size = rect.size
    guard let value = AXValueCreate(.cgSize, &size),
          AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success,
          let actual = sizeOf(window) else {
      message = "目标应用拒绝调整窗口，或窗口已关闭"; return false
    }
    // AX clients may clamp requested sizes. Read back before fixing the opposite corner.
    var point = rect.origin
    if anchor {
      if left { point.x = original.maxX - actual.width }
      if top { point.y = original.maxY - actual.height }
    }
    return position(window, point)
  }

  private func update() {
    guard dirty, let target = target else { return }
    dirty = false
    let dx = pointer.x - start.x, dy = pointer.y - start.y
    if !changed && abs(dx) < 3 && abs(dy) < 3 { return }
    changed = true
    var rect = original
    if moving {
      rect.origin.x += dx; rect.origin.y += dy
      if !position(target, rect.origin) { finish(cancel: true) }
      return
    }
    rect.size.width = max(min(160, original.width), original.width + (left ? -dx : dx))
    rect.size.height = max(min(100, original.height), original.height + (top ? -dy : dy))
    if ratioLocked {
      let ratio = original.width / original.height
      if abs(dx) / original.width >= abs(dy) / original.height {
        rect.size.height = rect.width / ratio
      } else { rect.size.width = rect.height * ratio }
    } else {
      if horizontalOnly { rect.size.height = original.height }
      if verticalOnly { rect.size.width = original.width }
    }
    if left { rect.origin.x = original.maxX - rect.width }
    if top { rect.origin.y = original.maxY - rect.height }
    if !apply(target, rect, anchor: true) { finish(cancel: true) }
  }

  private func finish(cancel: Bool) {
    guard let window = target else { return }
    if cancel { apply(window, original) }
    else if changed { pushUndo(window, original); if moving { saveWindow(window) } }
    if !cancel && changed && !moving {
      // AX size application can finish after mouse-up. Bounded readback corrections
      // preserve the same fixed corner without queuing more size writes.
      let revision = geometryRevision
      let frame = original, fixedLeft = left, fixedTop = top
      for delay in [0.03, 0.08, 0.16] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
          guard let self = self, self.geometryRevision == revision, self.target == nil,
                let size = self.sizeOf(window) else { return }
          var point = frame.origin
          if fixedLeft { point.x = frame.maxX - size.width }
          if fixedTop { point.y = frame.maxY - size.height }
          _ = self.position(window, point)
          if delay == 0.16 { self.saveWindow(window) }
        }
      }
    }
    target = nil; dirty = false
  }

  private var ratioModifier: String { resizeKeys.contains("shift") ? "alt" : "shift" }

  private func appID(_ window: AXUIElement) -> String? {
    var pid: pid_t = 0
    guard AXUIElementGetPid(window, &pid) == .success,
          let app = NSRunningApplication(processIdentifier: pid) else { return nil }
    return app.bundleIdentifier ?? app.executableURL?.lastPathComponent
  }

  private func supported(_ window: AXUIElement) -> Bool {
    var pid: pid_t = 0
    guard AXUIElementGetPid(window, &pid) == .success, pid != ProcessInfo.processInfo.processIdentifier,
          let id = appID(window), !excludedApps.contains(id.lowercased()),
          attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
          attribute(window, kAXMinimizedAttribute) as? Bool != true,
          attribute(window, "AXFullScreen") as? Bool != true else { return false }
    var movable: DarwinBoolean = false
    AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &movable)
    return movable.boolValue
  }

  private func rectOf(_ window: AXUIElement) -> CGRect? {
    guard let p = attribute(window, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
          let size = sizeOf(window) else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point) else { return nil }
    return CGRect(origin: point, size: size)
  }

  private func enumerateWindows() -> [[String: String]] {
    guard AXIsProcessTrusted() else { return [] }
    var next: [String: AXUIElement] = [:]
    var rows: [[String: String]] = []
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
      if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { continue }
      let ax = AXUIElementCreateApplication(app.processIdentifier)
      AXUIElementSetMessagingTimeout(ax, 0.02)
      guard let windows = attribute(ax, kAXWindowsAttribute) as? [AXUIElement] else { continue }
      for window in windows {
        AXUIElementSetMessagingTimeout(window, 0.02)
        guard supported(window), rectOf(window) != nil else { continue }
        let id = windowRefs.first(where: { CFEqual($0.value, window) })?.key ?? UUID().uuidString
        next[id] = window
        rows.append(["id": id, "title": attribute(window, kAXTitleAttribute) as? String ?? app.localizedName ?? "窗口",
                     "app": appID(window) ?? ""])
      }
    }
    windowRefs = next
    return rows
  }

  private func pushUndo(_ window: AXUIElement, _ rect: CGRect) {
    history.append((window, rect))
    if history.count > 20 { history.removeFirst(history.count - 20) }
  }

  @discardableResult private func undo() -> Bool {
    geometryRevision += 1
    finish(cancel: true)
    while let saved = history.popLast() {
      if supported(saved.0), apply(saved.0, visibleRect(saved.1, workArea(saved.1))) {
        saveWindow(saved.0); message = "已撤销上一次窗口操作"; return true
      }
    }
    message = "没有可撤销的窗口操作"; return false
  }

  private func workArea(_ rect: CGRect) -> CGRect {
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    let screens = NSScreen.screens.map { screen -> CGRect in
      let v = screen.visibleFrame
      return CGRect(x: v.minX, y: top - v.maxY, width: v.width, height: v.height)
    }
    return screens.max(by: {
      let a = $0.intersection(rect), b = $1.intersection(rect)
      return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
    }) ?? rect
  }

  private func visibleRect(_ rect: CGRect, _ work: CGRect) -> CGRect {
    var result = rect
    result.size.width = min(result.width, work.width)
    result.size.height = min(result.height, work.height)
    result.origin.x = min(max(result.minX, work.minX), work.maxX - result.width)
    result.origin.y = min(max(result.minY, work.minY), work.maxY - result.height)
    return result
  }

  private var memoryURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("WindowControl/window-memory.json")
  }
  private func loadMemory() {
    if let data = try? Data(contentsOf: memoryURL),
       let value = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Double]] { memory = value }
    memoryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.restoreNewWindows() }
  }
  private func saveWindow(_ window: AXUIElement) {
    guard rememberWindows, let id = appID(window), let rect = rectOf(window) else { return }
    memory[id] = ["x": Double(rect.minX), "y": Double(rect.minY), "w": Double(rect.width), "h": Double(rect.height)]
    do {
      try FileManager.default.createDirectory(at: memoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONSerialization.data(withJSONObject: memory)
      try data.write(to: memoryURL, options: .atomic)
    } catch { message = "窗口记忆保存失败：" + error.localizedDescription }
  }
  private func restoreNewWindows() {
    guard rememberWindows, tap != nil, target == nil else { return }
    _ = enumerateWindows()
    for (id, window) in windowRefs where !seenWindows.contains(id) {
      if let app = appID(window), let entry = memory[app],
         let x = entry["x"], let y = entry["y"], let w = entry["w"], let h = entry["h"],
         x.isFinite, y.isFinite, w.isFinite, h.isFinite, w > 0, h > 0 {
        let rect = CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
        if let before = rectOf(window), apply(window, visibleRect(rect, workArea(rect))) { pushUndo(window, before) }
      }
    }
    seenWindows = Set(windowRefs.keys)
  }

  private func loginEnabled() -> Bool {
    if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
    return false
  }
  private func setLogin(_ enabled: Bool) throws {
    guard #available(macOS 13.0, *) else {
      throw NSError(domain: "WindowControl", code: 13, userInfo: [NSLocalizedDescriptionKey: "登录启动需要 macOS 13 或更新版本"])
    }
    if enabled == loginEnabled() { return }
    if enabled { try SMAppService.mainApp.register() }
    else { try SMAppService.mainApp.unregister() }
  }

  private func installMenu() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    guard let button = item.button else { NSStatusBar.system.removeStatusItem(item); return }
    button.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Window Control")
    button.toolTip = "Window Control"
    let menu = NSMenu(); menu.delegate = self
    for (title, action) in [("显示设置", #selector(showSettings)), ("启用 / 暂停", #selector(toggleService)),
                            ("撤销上次操作", #selector(undoFromMenu)), ("退出", #selector(quit))] {
      let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
      entry.target = self; menu.addItem(entry)
    }
    item.menu = menu; statusItem = item
  }
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.items[1].title = tap == nil ? "启用服务" : "暂停服务"
    menu.items[2].isEnabled = !history.isEmpty
  }
  @objc private func showSettings() {
    NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
  }
  @objc private func toggleService() { if tap == nil { enable() } else { stop() } }
  @objc private func undoFromMenu() { _ = undo() }
  @objc private func quit() { stop(); NSApp.terminate(nil) }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if closeToTray && statusItem?.button != nil { sender.orderOut(nil); return false }
    return true
  }
}
