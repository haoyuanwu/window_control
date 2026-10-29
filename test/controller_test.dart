import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_control/window_controller.dart';

class MemoryStore extends SettingsStore {
  WindowSettings value = const WindowSettings();
  bool failSave = false;
  @override
  Future<WindowSettings> load() async => value;
  @override
  Future<void> save(WindowSettings settings) async {
    if (failSave) throw const FileSystemException('read only');
    value = settings;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_control/native');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test(
    'only an explicit login toggle requests native startup writes',
    () async {
      final sent = <Map<dynamic, dynamic>>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'configure') sent.add(call.arguments as Map);
        return {'enabled': false, 'launchAtLogin': false};
      });
      final store = MemoryStore()
        ..value = const WindowSettings(launchAtLogin: true);
      final controller = WindowController(store: store);
      await controller.initialize();
      expect(sent.last['applyLaunchAtLogin'], isNot(true));
      await controller.update(controller.settings.copyWith(edgeResize: false));
      expect(sent.last['applyLaunchAtLogin'], false);
      await controller.update(
        controller.settings.copyWith(launchAtLogin: true),
      );
      expect(sent.last['applyLaunchAtLogin'], true);
      controller.dispose();
    },
  );
  test('shortcuts reject empty, identical and derived ratio conflicts', () {
    expect(const WindowSettings().error, isNull);
    expect(const WindowSettings(resizeKeys: []).error, isNotNull);
    expect(const WindowSettings(moveKeys: []).error, isNotNull);
    expect(
      const WindowSettings(moveKeys: ['alt', 'ctrl']).error,
      contains('不能相同'),
    );
    expect(
      const WindowSettings(moveKeys: ['ctrl', 'alt', 'shift']).error,
      contains('比例'),
    );
    expect(
      const WindowSettings(
        resizeKeys: ['shift'],
        moveKeys: ['alt', 'shift'],
      ).error,
      contains('比例'),
    );
    expect(const WindowSettings(resizeKeys: ['alt', 'shift']).error, isNotNull);
    expect(
      const WindowSettings(
        resizeKeys: ['ctrl', 'shift'],
        moveKeys: ['meta'],
      ).ratioModifier,
      'alt',
    );
  });
  test('old JSON migrates resize keys and discards all snap fields', () {
    final settings = WindowSettings.fromJson({
      'layout': 'quarters',
      'snapKeys': ['ctrl'],
      'gap': 16,
      'threshold': 24,
      'preview': true,
      'resizeKeys': ['bad', 'meta'],
    });
    expect(settings.resizeKeys, ['meta']);
    expect(settings.moveKeys, ['ctrl', 'shift']);
    expect(settings.toJson().keys, isNot(contains('layout')));
    expect(settings.toJson().keys, isNot(contains('snapKeys')));
    expect(settings.nativeArguments(true).keys.toSet(), {
      'enabled',
      'resizeKeys',
      'moveKeys',
      'excludedApps',
      'edgeResize',
      'rememberWindows',
      'launchAtLogin',
      'autoEnable',
      'closeToTray',
    });
    expect(settings.nativeArguments(true), isNot(contains('presets')));
  });
  test(
    'stored invalid shortcuts fall back while valid preferences survive',
    () {
      final settings = WindowSettings.fromJson({
        'resizeKeys': ['shift', 'alt'],
        'moveKeys': ['meta'],
        'autoEnable': true,
        'presets': [
          {'name': 'bad', 'width': -1, 'height': 200},
        ],
      });
      expect(settings.error, isNull);
      expect(settings.autoEnable, true);
      expect(settings.presets, isEmpty);
    },
  );
  test('startup stays stopped by default; invalid edit stops using last valid keys', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {
        'enabled': (call.arguments as Map)['enabled'],
        'accessibility': true,
        'inputMonitoring': true,
      };
    });
    final store = MemoryStore();
    final controller = WindowController(store: store);
    await controller.initialize();
    expect(calls.single.arguments['enabled'], false);
    await controller.setEnabled(true);
    expect(controller.status.enabled, true);
    await controller.update(controller.settings.copyWith(resizeKeys: []));
    expect(controller.status.enabled, false);
    expect(store.value.resizeKeys, ['ctrl', 'alt']);
    expect(calls.last.arguments['resizeKeys'], ['ctrl', 'alt']);
    await controller.setEnabled(true);
    expect(calls.length, 3);
    controller.dispose();
  });
  test(
    'autoEnable starts hooks; preference changes configure even while stopped',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return {'enabled': (call.arguments as Map)['enabled']};
      });
      final store = MemoryStore()
        ..value = const WindowSettings(autoEnable: true);
      final controller = WindowController(store: store);
      await controller.initialize();
      expect(controller.status.enabled, true);
      await controller.setEnabled(false);
      await controller.update(
        controller.settings.copyWith(closeToTray: false, launchAtLogin: true),
      );
      expect(calls.last.arguments['enabled'], false);
      expect(calls.last.arguments['launchAtLogin'], true);
      expect(store.value.closeToTray, false);
      controller.dispose();
    },
  );
  test('failed disable refreshes actual running state', () async {
    var running = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getStatus') return {'enabled': running};
      final enabled = (call.arguments as Map)['enabled'] == true;
      if (!enabled && running) throw PlatformException(code: 'disable_failed');
      running = enabled;
      return {'enabled': running};
    });
    final c = WindowController(store: MemoryStore());
    await c.initialize();
    await c.setEnabled(true);
    await c.update(c.settings.copyWith(resizeKeys: []));
    expect(c.status.enabled, true);
    expect(c.actionMessage, contains('本机服务调用失败'));
    c.dispose();
  });
  test('save failure retains session settings with warning', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {'enabled': false},
    );
    final c = WindowController(store: MemoryStore()..failSave = true);
    await c.initialize();
    await c.update(c.settings.copyWith(resizeKeys: ['meta']));
    expect(c.settings.resizeKeys, ['meta']);
    expect(c.storageWarning, contains('设置暂未保存'));
    c.dispose();
  });
  test('missing native service explicitly unavailable', () async {
    final c = WindowController(store: MemoryStore());
    await c.initialize();
    expect(c.status.available, false);
    expect(c.status.message, contains('本机窗口服务不可用'));
    c.dispose();
  });
  test('all preferences and custom sizes round trip without transient enabled state', () async {
    final dir = await Directory.systemTemp.createTemp('window_control_test_');
    try {
      final store = SettingsStore(
        file: File('${dir.path}/config/settings.json'),
      );
      const settings = WindowSettings(
        resizeKeys: ['meta'],
        moveKeys: ['ctrl'],
        excludedApps: ['example.exe'],
        edgeResize: false,
        rememberWindows: true,
        launchAtLogin: true,
        autoEnable: true,
        closeToTray: false,
        presets: [SizePreset(name: 'Custom', width: 1200, height: 750)],
      );
      await store.save(settings);
      final loaded = await store.load();
      expect(loaded.toJson(), settings.toJson());
      expect(
        jsonDecode(await store.file.readAsString()),
        isNot(contains('enabled')),
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test('window tools keep explicit target, send preset and center commands, clear stale targets', () async {
    final calls = <MethodCall>[];
    var exists = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'listWindows') {
        return exists
            ? [
                {'id': '42', 'title': 'Editor', 'app': 'editor.exe'},
              ]
            : [];
      }
      if (call.method == 'applyPreset' || call.method == 'centerWindow') {
        return true;
      }
      return {'enabled': false, 'undoCount': 2};
    });
    final c = WindowController(store: MemoryStore());
    await c.initialize();
    await c.loadWindows();
    expect(c.selectedWindowId, isNull);
    c.selectWindow('42');
    await c.applySize(
      const SizePreset(name: 'x', width: 1280, height: 800),
      center: false,
    );
    expect(calls.firstWhere((call) => call.method == 'applyPreset').arguments, {
      'windowId': '42',
      'width': 1280,
      'height': 800,
      'center': false,
    });
    await c.centerSelected();
    expect(
      calls.firstWhere((call) => call.method == 'centerWindow').arguments,
      {'windowId': '42'},
    );
    expect(c.status.undoCount, 2);
    exists = false;
    await c.loadWindows();
    expect(c.selectedWindowId, isNull);
    c.dispose();
  });
  test('undo refreshes remaining count and can repeat', () async {
    var count = 2;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'restoreLast') {
        count--;
        return true;
      }
      return {'enabled': false, 'undoCount': count};
    });
    final c = WindowController(store: MemoryStore());
    await c.initialize();
    await c.restore();
    expect(c.status.undoCount, 1);
    await c.restore();
    expect(c.status.undoCount, 0);
    c.dispose();
  });
}
