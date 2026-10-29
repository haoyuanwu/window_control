import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const modifierKeys = ['ctrl', 'alt', 'shift', 'meta'];

class SizePreset {
  const SizePreset({
    required this.name,
    required this.width,
    required this.height,
  });
  final String name;
  final int width, height;
  Map<String, dynamic> toJson() => {
    'name': name,
    'width': width,
    'height': height,
  };
  static SizePreset? parse(dynamic value) {
    if (value is! Map ||
        value['name'] is! String ||
        value['width'] is! num ||
        value['height'] is! num) {
      return null;
    }
    final w = (value['width'] as num).toInt(),
        h = (value['height'] as num).toInt();
    final name = (value['name'] as String).trim();
    return name.isEmpty || w < 100 || h < 100 || w > 16384 || h > 16384
        ? null
        : SizePreset(name: name, width: w, height: h);
  }
}

class WindowSettings {
  const WindowSettings({
    this.resizeKeys = const ['ctrl', 'alt'],
    this.moveKeys = const ['ctrl', 'shift'],
    this.excludedApps = const [],
    this.edgeResize = true,
    this.rememberWindows = false,
    this.launchAtLogin = false,
    this.autoEnable = false,
    this.closeToTray = true,
    this.presets = const [
      SizePreset(name: '专注窗口', width: 1280, height: 800),
      SizePreset(name: '紧凑窗口', width: 960, height: 640),
    ],
  });
  final List<String> resizeKeys, moveKeys, excludedApps;
  final bool edgeResize,
      rememberWindows,
      launchAtLogin,
      autoEnable,
      closeToTray;
  final List<SizePreset> presets;
  String get ratioModifier => resizeKeys.contains('shift') ? 'alt' : 'shift';
  List<String> get ratioKeys => modifierKeys
      .where((k) => resizeKeys.contains(k) || k == ratioModifier)
      .toList();
  String? get error {
    if (resizeKeys.isEmpty) return '至少选择一个缩放修饰键。';
    if (moveKeys.isEmpty) return '至少选择一个移动修饰键。';
    if (setEquals(resizeKeys.toSet(), moveKeys.toSet())) return '缩放与移动组合键不能相同。';
    if (resizeKeys.contains(ratioModifier)) {
      return '缩放组合不能同时包含 Shift 和 Alt，请为保持比例预留一个按键。';
    }
    if (setEquals(ratioKeys.toSet(), moveKeys.toSet())) {
      return '移动组合键与保持比例缩放组合冲突，请更换。';
    }
    return null;
  }

  WindowSettings copyWith({
    List<String>? resizeKeys,
    List<String>? moveKeys,
    List<String>? excludedApps,
    bool? edgeResize,
    bool? rememberWindows,
    bool? launchAtLogin,
    bool? autoEnable,
    bool? closeToTray,
    List<SizePreset>? presets,
  }) => WindowSettings(
    resizeKeys: resizeKeys ?? this.resizeKeys,
    moveKeys: moveKeys ?? this.moveKeys,
    excludedApps: excludedApps ?? this.excludedApps,
    edgeResize: edgeResize ?? this.edgeResize,
    rememberWindows: rememberWindows ?? this.rememberWindows,
    launchAtLogin: launchAtLogin ?? this.launchAtLogin,
    autoEnable: autoEnable ?? this.autoEnable,
    closeToTray: closeToTray ?? this.closeToTray,
    presets: presets ?? this.presets,
  );
  Map<String, dynamic> nativeArguments(bool enabled) => {
    'enabled': enabled,
    'resizeKeys': resizeKeys,
    'moveKeys': moveKeys,
    'excludedApps': excludedApps,
    'edgeResize': edgeResize,
    'rememberWindows': rememberWindows,
    'launchAtLogin': launchAtLogin,
    'autoEnable': autoEnable,
    'closeToTray': closeToTray,
  };
  Map<String, dynamic> toJson() => {
    ...nativeArguments(false)..remove('enabled'),
    'presets': presets.map((p) => p.toJson()).toList(),
  };
  factory WindowSettings.fromJson(Map<String, dynamic> json) {
    List<String> keys(String field, List<String> fallback) {
      final value = json[field];
      if (value is! List) return fallback;
      final keys = modifierKeys.where(value.contains).toList();
      return keys.isEmpty ? fallback : keys;
    }

    bool flag(String field, bool fallback) =>
        json[field] is bool ? json[field] as bool : fallback;
    final rawApps = json['excludedApps'];
    final apps = rawApps is List
        ? rawApps
              .whereType<String>()
              .map((v) => v.trim())
              .where((v) => v.isNotEmpty)
              .toSet()
              .toList()
        : <String>[];
    final rawPresets = json['presets'];
    final candidate = WindowSettings(
      resizeKeys: keys('resizeKeys', ['ctrl', 'alt']),
      moveKeys: keys('moveKeys', ['ctrl', 'shift']),
      excludedApps: apps,
      edgeResize: flag('edgeResize', true),
      rememberWindows: flag('rememberWindows', false),
      launchAtLogin: flag('launchAtLogin', false),
      autoEnable: flag('autoEnable', false),
      closeToTray: flag('closeToTray', true),
      presets: rawPresets is List
          ? rawPresets.map(SizePreset.parse).whereType<SizePreset>().toList()
          : const WindowSettings().presets,
    );
    return candidate.error == null
        ? candidate
        : candidate.copyWith(
            resizeKeys: const WindowSettings().resizeKeys,
            moveKeys: const WindowSettings().moveKeys,
          );
  }
}

class ManagedWindow {
  const ManagedWindow({
    required this.id,
    required this.title,
    required this.app,
  });
  final String id, title, app;
  static ManagedWindow? parse(dynamic value) {
    if (value is! Map ||
        value['id'] is! String ||
        value['title'] is! String ||
        value['app'] is! String) {
      return null;
    }
    return ManagedWindow(
      id: value['id'] as String,
      title: value['title'] as String,
      app: value['app'] as String,
    );
  }
}

class SettingsStore {
  SettingsStore({File? file})
    : _file = file; // ignore: prefer_initializing_formals
  final File? _file;
  File get file {
    if (_file != null) return _file;
    final env = Platform.environment;
    final root = Platform.isWindows
        ? env['APPDATA']
        : Platform.isMacOS
        ? (env['HOME'] == null
              ? null
              : '${env['HOME']}/Library/Application Support')
        : env['XDG_CONFIG_HOME'] ??
              (env['HOME'] == null ? null : '${env['HOME']}/.config');
    if (root == null || root.isEmpty) {
      throw const FileSystemException('无法定位用户配置目录');
    }
    return File('$root/window_control/settings.json');
  }

  Future<WindowSettings> load() async {
    if (!await file.exists()) return const WindowSettings();
    final json = jsonDecode(await file.readAsString());
    if (json is! Map<String, dynamic>) throw const FormatException('配置格式错误');
    return WindowSettings.fromJson(json);
  }

  Future<void> save(WindowSettings settings) async {
    final target = file;
    await target.parent.create(recursive: true);
    await target.writeAsString(jsonEncode(settings.toJson()), flush: true);
  }
}

class NativeStatus {
  const NativeStatus({
    this.enabled = false,
    this.accessibility = false,
    this.inputMonitoring = false,
    this.available = false,
    this.undoCount = 0,
    this.launchAtLogin = false,
    this.message = '正在连接本机服务…',
  });
  final bool enabled, accessibility, inputMonitoring, available, launchAtLogin;
  final int undoCount;
  final String message;
  factory NativeStatus.fromMap(Map<dynamic, dynamic> value) => NativeStatus(
    enabled: value['enabled'] == true,
    accessibility: value['accessibility'] == true,
    inputMonitoring: value['inputMonitoring'] == true,
    available: true,
    undoCount: value['undoCount'] is num
        ? (value['undoCount'] as num).toInt().clamp(0, 20)
        : 0,
    launchAtLogin: value['launchAtLogin'] == true,
    message: value['message'] is String
        ? value['message'] as String
        : '本机服务已连接',
  );
}

class WindowController extends ChangeNotifier {
  WindowController({SettingsStore? store, MethodChannel? channel})
    : store = store ?? SettingsStore(),
      channel = channel ?? const MethodChannel('window_control/native');
  final SettingsStore store;
  final MethodChannel channel;
  WindowSettings settings = const WindowSettings();
  WindowSettings _lastValidSettings = const WindowSettings();
  NativeStatus status = const NativeStatus();
  List<ManagedWindow> windows = [];
  String? selectedWindowId;
  bool busy = true;
  String? storageWarning, actionMessage;
  bool _disposed = false;
  void emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _unknownStatus(String message) {
    status = NativeStatus(
      enabled: status.enabled,
      accessibility: status.accessibility,
      inputMonitoring: status.inputMonitoring,
      undoCount: status.undoCount,
      launchAtLogin: status.launchAtLogin,
      available: false,
      message: message,
    );
  }

  Future<void> _statusCall(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    try {
      final result = await channel.invokeMapMethod<dynamic, dynamic>(
        method,
        arguments,
      );
      if (result == null) throw const FormatException('本机服务未返回状态');
      status = NativeStatus.fromMap(result);
    } on MissingPluginException {
      _unknownStatus('本机窗口服务不可用。请使用包含原生模块的 Windows 或 macOS 桌面版本。');
    } catch (error) {
      actionMessage = '本机服务调用失败：$error';
      try {
        final actual = await channel.invokeMapMethod<dynamic, dynamic>(
          'getStatus',
        );
        if (actual == null) throw const FormatException('无法查询状态');
        status = NativeStatus.fromMap(actual);
      } catch (_) {
        _unknownStatus('无法确认本机服务状态，请刷新重试。');
      }
    }
  }

  Future<void> initialize() async {
    try {
      settings = await store.load();
    } catch (_) {
      storageWarning = '配置读取失败，已使用默认设置；请检查配置文件和目录权限。';
    }
    _lastValidSettings = settings;
    await _statusCall(
      'configure',
      settings.nativeArguments(settings.autoEnable),
    );
    if (status.available) {
      settings = settings.copyWith(launchAtLogin: status.launchAtLogin);
      _lastValidSettings = settings;
    }
    busy = false;
    emit();
  }

  Future<void> update(WindowSettings value) async {
    if (busy) return;
    final applyLogin = value.launchAtLogin != settings.launchAtLogin;
    settings = value;
    actionMessage = null;
    busy = true;
    emit();
    if (value.error == null) {
      _lastValidSettings = value;
      try {
        await store.save(value);
        storageWarning = null;
      } catch (_) {
        storageWarning = '设置暂未保存：无法写入用户配置目录。当前设置仍可在本次运行使用。';
      }
      // Preferences, startup and tray options must reach native while hooks are stopped.
      await _statusCall('configure', {
        ...value.nativeArguments(status.enabled),
        'applyLaunchAtLogin': applyLogin,
      });
      if (applyLogin &&
          status.available &&
          settings.launchAtLogin != status.launchAtLogin) {
        settings = settings.copyWith(launchAtLogin: status.launchAtLogin);
        _lastValidSettings = settings;
        try {
          await store.save(settings);
        } catch (_) {
          storageWarning = '登录项状态已刷新，但配置未保存。';
        }
      }
    } else if (status.enabled) {
      await _statusCall('configure', _lastValidSettings.nativeArguments(false));
    }
    busy = false;
    emit();
  }

  Future<void> setEnabled(bool enabled) async {
    if (busy || (enabled && settings.error != null)) return;
    busy = true;
    actionMessage = null;
    emit();
    await _statusCall(
      'configure',
      (enabled ? settings : _lastValidSettings).nativeArguments(enabled),
    );
    busy = false;
    emit();
  }

  Future<void> refresh({bool request = false}) async {
    if (busy) return;
    busy = true;
    emit();
    await _statusCall(request ? 'requestPermissions' : 'getStatus');
    busy = false;
    emit();
  }

  Future<void> restore() async {
    if (busy) return;
    busy = true;
    emit();
    try {
      final restored = await channel.invokeMethod<bool>('restoreLast');
      actionMessage = restored == true
          ? '已撤销上一次窗口操作，可继续撤销更早的操作。'
          : '暂无可撤销的窗口，或该窗口已关闭。';
      await _statusCall('getStatus');
    } catch (_) {
      actionMessage = '无法还原窗口，请检查本机服务是否可用。';
    }
    busy = false;
    emit();
  }

  void selectWindow(String? id) {
    selectedWindowId = id;
    actionMessage = null;
    emit();
  }

  Future<void> loadWindows() async {
    if (busy) return;
    busy = true;
    actionMessage = null;
    emit();
    try {
      final result = await channel.invokeListMethod<dynamic>('listWindows');
      windows = (result ?? [])
          .map(ManagedWindow.parse)
          .whereType<ManagedWindow>()
          .toList();
      if (!windows.any((w) => w.id == selectedWindowId)) {
        selectedWindowId = null;
      }
      if (windows.isEmpty) actionMessage = '未找到可操作窗口，请打开其他应用的普通窗口后刷新。';
    } catch (_) {
      windows = [];
      selectedWindowId = null;
      actionMessage = '无法读取窗口列表，请检查系统权限后重试。';
    }
    busy = false;
    emit();
  }

  Future<void> applySize(SizePreset preset, {bool center = true}) async {
    if (busy || selectedWindowId == null) return;
    await _windowCommand('applyPreset', {
      'windowId': selectedWindowId,
      'width': preset.width,
      'height': preset.height,
      'center': center,
    }, '已应用 ${preset.width} × ${preset.height} 尺寸。');
  }

  Future<void> centerSelected() async {
    if (busy || selectedWindowId == null) return;
    await _windowCommand('centerWindow', {
      'windowId': selectedWindowId,
    }, '目标窗口已居中。');
  }

  Future<void> _windowCommand(
    String method,
    Map<String, dynamic> arguments,
    String success,
  ) async {
    busy = true;
    actionMessage = null;
    emit();
    try {
      final result = await channel.invokeMethod<bool>(method, arguments);
      actionMessage = result == true
          ? success
          : '窗口操作未成功。目标可能已关闭、受权限保护或不支持此尺寸。';
      await _statusCall('getStatus');
    } catch (_) {
      actionMessage = '窗口操作失败，请刷新目标窗口列表并检查权限。';
    }
    busy = false;
    emit();
  }
}
