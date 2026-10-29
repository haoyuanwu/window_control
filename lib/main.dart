import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'window_controller.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key, this.controller});
  final WindowController? controller;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Window Control',
    theme: ThemeData(
      useMaterial3: true,
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: const Color(0xff4566ae),
            brightness: Brightness.light,
          ).copyWith(
            surface: const Color(0xfff9fbff),
            onSurface: const Color(0xff24334c),
            primaryContainer: const Color(0xffdce7ff),
          ),
      scaffoldBackgroundColor: Colors.transparent,
      fontFamily: Platform.isMacOS ? 'PingFang SC' : 'Microsoft YaHei',
      fontFamilyFallback: const ['Microsoft YaHei', 'PingFang SC'],
      textTheme: const TextTheme(
        bodyMedium: TextStyle(fontSize: 14, height: 1.6),
        bodySmall: TextStyle(fontSize: 12, height: 1.5),
      ),
      chipTheme: ChipThemeData(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        labelStyle: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          fontFamily: 'Microsoft YaHei',
          fontFamilyFallback: ['PingFang SC'],
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        side: const BorderSide(color: Color(0xffd7e0f0)),
        backgroundColor: const Color(0xfff8faff),
        selectedColor: const Color(0xffdce7ff),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(96, 52),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(96, 52),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    home: ControlPage(controller: controller),
  );
}

class ControlPage extends StatefulWidget {
  const ControlPage({super.key, this.controller});
  final WindowController? controller;
  @override
  State<ControlPage> createState() => _ControlPageState();
}

class _ControlPageState extends State<ControlPage> with WidgetsBindingObserver {
  Timer? _statusTimer;
  AppLifecycleState? _lifecycle;
  late final WindowController model = widget.controller ?? WindowController();
  int page = 0;
  final titles = const ['操作设置', '窗口工具', '偏好与权限'];
  final appInput = TextEditingController();
  bool centerPreset = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if ((_lifecycle == null || _lifecycle == AppLifecycleState.resumed) &&
          !model.busy &&
          model.status.available) {
        unawaited(model.refresh());
      }
    });
    unawaited(model.initialize());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    if (state == AppLifecycleState.resumed && !model.busy) {
      unawaited(model.refresh());
    }
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    appInput.dispose();
    if (widget.controller == null) model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xffe7f2ff), Color(0xffeeeafb), Color(0xffe3f4ee)],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 760;
              final content = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (model.busy) const LinearProgressIndicator(minHeight: 2),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.all(wide ? 32 : 16),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 920),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                titles[page],
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -.8,
                                    ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                [
                                  '让鼠标停留的位置，成为窗口操作的起点。',
                                  '选择目标窗口，应用尺寸预设或移到屏幕中央。',
                                  '按你的习惯运行，并管理系统权限与排除名单。',
                                ][page],
                              ),
                              const SizedBox(height: 24),
                              _serviceCard(),
                              if (model.storageWarning != null)
                                _notice(model.storageWarning!, error: true),
                              if (model.settings.error != null)
                                _notice(model.settings.error!, error: true),
                              if (model.actionMessage != null)
                                _notice(model.actionMessage!),
                              const SizedBox(height: 16),
                              if (page == 0) ..._operationPage(),
                              if (page == 1) ..._toolsPage(),
                              if (page == 2) ..._helpPage(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
              return wide
                  ? Row(
                      children: [
                        SizedBox(width: 232, child: _navigation()),
                        Expanded(child: content),
                      ],
                    )
                  : Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Wrap(
                            spacing: 8,
                            children: List.generate(
                              titles.length,
                              (i) => ChoiceChip(
                                label: Text(titles[i]),
                                selected: page == i,
                                onSelected: (_) => _navigate(i),
                              ),
                            ),
                          ),
                        ),
                        Expanded(child: content),
                      ],
                    );
            },
          ),
        ),
      ),
    ),
  );

  Widget _navigation() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 24, 0, 24),
    child: _glass(
      radius: 30,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xff6489d5), Color(0xff7b91c9)],
                ),
                borderRadius: BorderRadius.circular(22),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x30617fbe),
                    blurRadius: 20,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: const Icon(
                Icons.window_rounded,
                color: Colors.white,
                size: 34,
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Window Control',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 19,
              letterSpacing: -.5,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '窗口随手掌控',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xff596b86)),
          ),
          const SizedBox(height: 32),
          ...List.generate(
            titles.length,
            (i) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ListTile(
                minTileHeight: 62,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                selected: page == i,
                selectedTileColor: const Color(0xffdce7fc),
                leading: Icon(
                  [
                    Icons.tune_rounded,
                    Icons.web_asset_rounded,
                    Icons.verified_user_outlined,
                  ][i],
                ),
                title: Text(
                  titles[i],
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: page == i ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                onTap: () => _navigate(i),
              ),
            ),
          ),
          const Spacer(),
          const Icon(Icons.mouse_outlined, size: 22, color: Color(0xff7184a1)),
          const SizedBox(height: 8),
          const Text(
            'Windows · macOS',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Color(0xff596b86)),
          ),
        ],
      ),
    ),
  );

  bool get _canToggle =>
      !model.busy &&
      (model.status.enabled ||
          (model.status.available && model.settings.error == null));
  Widget _serviceCard() => _glass(
    featured: true,
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .65),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(
                model.status.enabled
                    ? Icons.check_circle_outline_rounded
                    : Icons.pause_circle_outline_rounded,
                size: 28,
                color: const Color(0xff4566ae),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                model.status.enabled ? '窗口服务运行中' : '窗口服务已停止',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Switch(
              value: model.status.enabled,
              onChanged: _canToggle ? model.setEnabled : null,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Semantics(liveRegion: true, child: Text(model.status.message)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: model.busy ? null : model.refresh,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('刷新诊断'),
            ),
            Text(
              model.status.enabled
                  ? '缩放无反应时，操作目标窗口后点击刷新诊断。'
                  : '先打开右上方开关，再尝试缩放其他应用窗口。',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          model.settings.autoEnable
              ? '已设为启动后自动启用。关闭设置窗口后的行为由偏好控制。'
              : '启动后默认关闭，可在偏好中开启自动启用。设置会自动保存。',
          style: TextStyle(fontSize: 12, color: Color(0xff526580)),
        ),
      ],
    ),
  );

  void _navigate(int index) {
    setState(() => page = index);
    if (index == 1 && model.windows.isEmpty && !model.busy) {
      unawaited(model.loadWindows());
    }
  }

  Widget _undoButton() => OutlinedButton.icon(
    onPressed: model.busy || !model.status.available ? null : model.restore,
    icon: const Icon(Icons.undo_rounded),
    label: Text('撤销上一步（${model.status.undoCount} / 20）'),
  );
  List<Widget> _operationPage() => [
    LayoutBuilder(
      builder: (context, constraints) {
        final cards = [
          _keyCard(
            '自由缩放',
            Icons.open_in_full_rounded,
            '组合键 + 鼠标左键拖动，固定对侧锚点。',
            model.settings.resizeKeys,
            (keys) => model.update(model.settings.copyWith(resizeKeys: keys)),
          ),
          _keyCard(
            '自由移动',
            Icons.pan_tool_alt_outlined,
            '组合键 + 鼠标左键，从任意位置移动，自动显示到前景。',
            model.settings.moveKeys,
            (keys) => model.update(model.settings.copyWith(moveKeys: keys)),
          ),
        ];
        return constraints.maxWidth < 720
            ? Column(children: [cards[0], const SizedBox(height: 20), cards[1]])
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: cards[0]),
                  const SizedBox(width: 20),
                  Expanded(child: cards[1]),
                ],
              );
      },
    ),
    const SizedBox(height: 20),
    _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '保持比例：额外按住 ${_keyLabel(model.settings.ratioModifier)}',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
          ),
          const SizedBox(height: 8),
          const Text('在缩放组合键之外按住比例键，沿原宽高比调整。组合键按精确匹配判断；移动与比例组合不能重复。'),
          const SizedBox(height: 12),
          _preference(
            '边缘单轴缩放',
            '靠近边缘中段时仅调整宽或高；四角和窗口中心区域保持双轴缩放。',
            model.settings.edgeResize,
            (v) => model.update(model.settings.copyWith(edgeResize: v)),
          ),
          const SizedBox(height: 12),
          const Text(
            '四象限锚点：左上拖动固定右下，右上固定左下；左下固定右上，右下固定左上。按下时确定方向，拖动期间不会切换。Esc 取消当前拖动。',
          ),
          const SizedBox(height: 12),
          _undoButton(),
        ],
      ),
    ),
  ];

  Widget _preference(
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: Text(subtitle),
    value: value,
    onChanged: model.busy ? null : onChanged,
  );

  List<Widget> _toolsPage() => [
    _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading('目标窗口', Icons.web_asset_outlined),
          const SizedBox(height: 12),
          const Text('从列表选择目标，点击本工具不会把目标切换为当前设置窗口。窗口关闭后请刷新列表。'),
          const SizedBox(height: 16),
          if (model.windows.isNotEmpty)
            DropdownButtonFormField<String>(
              key: ValueKey(
                '${model.selectedWindowId}:${model.windows.map((w) => w.id).join(',')}',
              ),
              initialValue: model.selectedWindowId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '选择目标窗口'),
              items: model.windows
                  .map(
                    (w) => DropdownMenuItem(
                      value: w.id,
                      child: Text(
                        '${w.title} · ${w.app}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: model.busy ? null : model.selectWindow,
            )
          else
            const Text('暂无目标窗口。请打开其他应用，然后刷新列表。'),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              OutlinedButton.icon(
                onPressed: model.busy ? null : model.loadWindows,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新窗口列表'),
              ),
              FilledButton.tonalIcon(
                onPressed: model.busy || model.selectedWindowId == null
                    ? null
                    : model.centerSelected,
                icon: const Icon(Icons.center_focus_strong),
                label: const Text('目标窗口居中'),
              ),
            ],
          ),
        ],
      ),
    ),
    const SizedBox(height: 20),
    _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading('尺寸预设', Icons.aspect_ratio_rounded),
          _preference(
            '应用尺寸时居中',
            '尺寸受目标应用最小大小及系统缩放影响。',
            centerPreset,
            (v) => setState(() => centerPreset = v),
          ),
          const SizedBox(height: 8),
          if (model.settings.presets.isEmpty) const Text('还没有尺寸预设，可添加常用宽高。'),
          ...model.settings.presets.asMap().entries.map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton(
                    onPressed: model.busy || model.selectedWindowId == null
                        ? null
                        : () => model.applySize(
                            entry.value,
                            center: centerPreset,
                          ),
                    child: Text(
                      '${entry.value.name}   ${entry.value.width} × ${entry.value.height}',
                    ),
                  ),
                  IconButton(
                    tooltip: '删除 ${entry.value.name}',
                    onPressed: model.busy
                        ? null
                        : () {
                            final presets = [...model.settings.presets]
                              ..removeAt(entry.key);
                            unawaited(
                              model.update(
                                model.settings.copyWith(presets: presets),
                              ),
                            );
                          },
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: model.busy ? null : _addPreset,
              icon: const Icon(Icons.add),
              label: const Text('新增尺寸预设'),
            ),
          ),
          const SizedBox(height: 16),
          _undoButton(),
        ],
      ),
    ),
  ];
  Widget _heading(String title, IconData icon) => Row(
    children: [
      Icon(icon, color: const Color(0xff4566ae)),
      const SizedBox(width: 12),
      Expanded(
        child: Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
    ],
  );

  Future<void> _addPreset() async {
    final name = TextEditingController(),
        width = TextEditingController(),
        height = TextEditingController();
    final form = GlobalKey<FormState>();
    final preset = await showDialog<SizePreset>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新增尺寸预设'),
        content: SizedBox(
          width: 360,
          child: Form(
            key: form,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: name,
                    decoration: const InputDecoration(labelText: '名称'),
                    maxLength: 40,
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? '请输入预设名称' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: width,
                    decoration: const InputDecoration(labelText: '宽度（px）'),
                    keyboardType: TextInputType.number,
                    validator: _validateSize,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: height,
                    decoration: const InputDecoration(labelText: '高度（px）'),
                    keyboardType: TextInputType.number,
                    validator: _validateSize,
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) {
                Navigator.pop(
                  context,
                  SizePreset(
                    name: name.text.trim(),
                    width: int.parse(width.text),
                    height: int.parse(height.text),
                  ),
                );
              }
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
    // Let dialog exit animations release the text fields before disposing them.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    name.dispose();
    width.dispose();
    height.dispose();
    if (preset != null && mounted) {
      await model.update(
        model.settings.copyWith(presets: [...model.settings.presets, preset]),
      );
    }
  }

  String? _validateSize(String? value) {
    final number = int.tryParse(value ?? '');
    return number == null || number < 100 || number > 16384
        ? '请输入 100–16384 的整数'
        : null;
  }

  Widget _keyCard(
    String title,
    IconData icon,
    String description,
    List<String> selected,
    ValueChanged<List<String>> update,
  ) => _card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xffe8edfc),
                borderRadius: BorderRadius.circular(17),
              ),
              child: Icon(icon, size: 25, color: const Color(0xff4566ae)),
            ),
            const SizedBox(width: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(description),
        const SizedBox(height: 16),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: modifierKeys
              .map(
                (key) => FilterChip(
                  label: Text(
                    _keyLabel(key),
                    style: const TextStyle(color: Color(0xff344d76)),
                  ),
                  side: BorderSide(
                    color: selected.contains(key)
                        ? const Color(0xff7993c8)
                        : const Color(0xffd7e0f0),
                  ),
                  elevation: selected.contains(key) ? 2 : 0,
                  shadowColor: const Color(0x204566ae),
                  selected: selected.contains(key),
                  onSelected: model.busy
                      ? null
                      : (value) {
                          final keys = selected.toSet();
                          value ? keys.add(key) : keys.remove(key);
                          update(modifierKeys.where(keys.contains).toList());
                        },
                ),
              )
              .toList(),
        ),
      ],
    ),
  );
  String _keyLabel(String key) => switch (key) {
    'ctrl' => Platform.isMacOS ? 'Control ⌃' : 'Ctrl',
    'alt' => Platform.isMacOS ? 'Option ⌥' : 'Alt',
    'shift' => 'Shift',
    _ => Platform.isMacOS ? 'Command ⌘' : 'Win',
  };

  List<Widget> _helpPage() => [
    _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading('运行偏好', Icons.tune_rounded),
          const SizedBox(height: 12),
          _preference(
            '登录后启动',
            '随系统登录启动本工具。当前系统状态：${model.status.launchAtLogin ? '已开启' : '未开启'}。',
            model.settings.launchAtLogin,
            (v) => model.update(model.settings.copyWith(launchAtLogin: v)),
          ),
          _preference(
            '启动后自动启用',
            '下次启动直接监听组合键；关闭此选项时启动后等待手动启用。',
            model.settings.autoEnable,
            (v) => model.update(model.settings.copyWith(autoEnable: v)),
          ),
          _preference(
            '关闭设置后驻留托盘',
            '关闭窗口后继续运行；从系统托盘或菜单栏选择退出以完全结束程序。',
            model.settings.closeToTray,
            (v) => model.update(model.settings.copyWith(closeToTray: v)),
          ),
          _preference(
            '记住窗口位置与尺寸',
            '记录受控窗口的几何信息，在后续识别到匹配窗口时恢复。',
            model.settings.rememberWindows,
            (v) => model.update(model.settings.copyWith(rememberWindows: v)),
          ),
        ],
      ),
    ),
    const SizedBox(height: 20),
    _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading('排除应用', Icons.block_outlined),
          const SizedBox(height: 12),
          Text(
            Platform.isMacOS
                ? '输入应用 bundle ID，例如 com.apple.finder；排除应用不接受本工具的窗口操作。'
                : '输入可执行文件名，例如 explorer.exe；排除应用不接受本工具的窗口操作。',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: appInput,
            decoration: InputDecoration(
              labelText: Platform.isMacOS ? '应用 bundle ID' : '应用 exe 文件名',
            ),
            onSubmitted: model.busy ? null : (_) => _addExcluded(appInput.text),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.tonalIcon(
                onPressed: model.busy
                    ? null
                    : () => _addExcluded(appInput.text),
                icon: const Icon(Icons.add),
                label: const Text('添加排除应用'),
              ),
              OutlinedButton(
                onPressed: model.busy ? null : model.loadWindows,
                child: const Text('读取运行中的应用'),
              ),
            ],
          ),
          if (model.windows.isNotEmpty) ...[
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              key: ValueKey(model.windows.map((w) => w.app).join(',')),
              isExpanded: true,
              decoration: const InputDecoration(labelText: '从运行中的应用添加'),
              items: model.windows
                  .map((w) => w.app)
                  .where((app) => app.isNotEmpty)
                  .toSet()
                  .map(
                    (app) => DropdownMenuItem(
                      value: app,
                      child: Text(app, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: model.busy
                  ? null
                  : (app) {
                      if (app != null) _addExcluded(app);
                    },
            ),
          ],
          const SizedBox(height: 16),
          if (model.settings.excludedApps.isEmpty)
            const Text('暂无排除应用。')
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: model.settings.excludedApps
                  .map(
                    (app) => InputChip(
                      label: Text(app),
                      onDeleted: model.busy
                          ? null
                          : () => model.update(
                              model.settings.copyWith(
                                excludedApps: model.settings.excludedApps
                                    .where((item) => item != app)
                                    .toList(),
                              ),
                            ),
                    ),
                  )
                  .toList(),
            ),
        ],
      ),
    ),
    const SizedBox(height: 20),

    _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '系统权限',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          _permission('辅助功能 / 窗口控制', model.status.accessibility),
          _permission('输入监听', model.status.inputMonitoring),
          const SizedBox(height: 12),
          Text(
            Platform.isMacOS
                ? 'macOS 需要在“系统设置 → 隐私与安全性”允许辅助功能及输入监控。授权后返回此处刷新状态，必要时重新启动应用。'
                : 'Windows 通常无需额外授权。普通权限进程可能无法操作管理员权限窗口、安全桌面和部分受保护窗口。',
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: model.busy
                    ? null
                    : () => model.refresh(request: true),
                icon: const Icon(Icons.security),
                label: const Text('请求权限'),
              ),
              OutlinedButton.icon(
                onPressed: model.busy ? null : model.refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新状态'),
              ),
            ],
          ),
        ],
      ),
    ),
    const SizedBox(height: 16),
    _card(
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '使用说明',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          SizedBox(height: 12),
          Text(
            '1. 选择互不冲突的缩放、移动组合键并启用服务。\n2. 对其他应用的普通、非最大化窗口按组合键 + 左键拖动。\n3. 缩放时额外按比例键保持宽高比；Esc 取消当前操作。\n4. 在窗口工具中选择目标，应用尺寸预设或居中。可连续撤销最多 20 次。\n\n本设置窗口、系统保护窗口及部分特殊应用无法控制。关闭设置是否继续运行取决于驻留托盘偏好。',
          ),
        ],
      ),
    ),
  ];
  void _addExcluded(String value) {
    final app = value.trim();
    if (app.isEmpty || model.busy) return;
    final apps = [...model.settings.excludedApps];
    if (!apps.any(
      (item) => Platform.isWindows
          ? item.toLowerCase() == app.toLowerCase()
          : item == app,
    )) {
      apps.add(app);
    }
    appInput.clear();
    unawaited(model.update(model.settings.copyWith(excludedApps: apps)));
  }

  Widget _permission(String label, bool granted) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        Icon(
          granted ? Icons.check_circle_outline : Icons.info_outline,
          size: 20,
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(label)),
        Text(
          !model.status.available
              ? '不可用'
              : granted
              ? '已允许'
              : '未允许',
        ),
      ],
    ),
  );
  Widget _notice(String text, {bool error = false}) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: error
              ? Theme.of(context).colorScheme.errorContainer
              : Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text),
      ),
    ),
  );
  Widget _card({required Widget child}) => _glass(child: child);

  Widget _glass({
    required Widget child,
    bool featured = false,
    double radius = 28,
    EdgeInsets padding = const EdgeInsets.all(24),
  }) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(radius),
      boxShadow: [
        BoxShadow(
          color: const Color(0xff617aab)
              .withValues(alpha: featured ? .12 : .07),
          blurRadius: featured ? 30 : 24,
          offset: const Offset(0, 10),
        ),
      ],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: featured
                ? const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xe6dceaff),
                      Color(0xdde5e1fc),
                      Color(0xe6ddf3ed),
                    ],
                  )
                : null,
            color: featured ? null : Colors.white.withValues(alpha: .66),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: Colors.white.withValues(alpha: .85),
              width: 1.3,
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    ),
  );
}
