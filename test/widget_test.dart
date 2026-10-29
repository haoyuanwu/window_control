import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_control/main.dart';
import 'package:window_control/window_controller.dart';

import 'controller_test.dart' show MemoryStore;

void main() {
  const channel = MethodChannel('window_control/native');
  testWidgets(
    'desktop controls configure service and stop on empty shortcuts',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => {
              'enabled': call.method == 'getStatus'
                  ? true
                  : (call.arguments as Map?)?['enabled'] ?? false,
              'accessibility': true,
              'inputMonitoring': true,
              'message': 'ready',
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final controller = WindowController(store: MemoryStore());
      await tester.pumpWidget(MyApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('自由缩放'), findsOneWidget);
      expect(find.textContaining('先打开右上方开关'), findsOneWidget);
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(find.text('窗口服务运行中'), findsOneWidget);
      await tester.tap(find.widgetWithText(OutlinedButton, '刷新诊断'));
      await tester.pumpAndSettle();
      expect(find.text('窗口服务运行中'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilterChip, 'Alt').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, 'Ctrl').first);
      await tester.pumpAndSettle();
      expect(find.text('至少选择一个缩放修饰键。'), findsOneWidget);
      expect(find.text('窗口服务已停止'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
  testWidgets('narrow window and larger text navigate without overflow', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => throw MissingPluginException(),
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    tester.view.physicalSize = const Size(375, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = WindowController(store: MemoryStore());
    await tester.pumpWidget(MyApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.textContaining('本机窗口服务不可用'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, '窗口工具'));
    await tester.pumpAndSettle();
    expect(find.text('目标窗口'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(ChoiceChip, '偏好与权限'));
    await tester.pumpAndSettle();
    expect(find.text('系统权限'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
