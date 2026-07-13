import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/provider/animation_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/window_dimensions_provider.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/native/tray_helper.dart';
import 'package:localsend_app/widget/dialogs/windows_receive_card.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:window_manager/window_manager.dart';

final _logger = Logger('WindowWatcher');

class WindowWatcher extends StatefulWidget {
  final Widget child;

  const WindowWatcher({
    required this.child,
    super.key,
  });

  @override
  State<WindowWatcher> createState() => _WindowWatcherState();

  static Future<void> closeWindow(BuildContext context) async {
    final state = context.findAncestorStateOfType<_WindowWatcherState>();
    await state?.onWindowClose();
  }
}

class _WindowWatcherState extends State<WindowWatcher>
    with WindowListener, Refena {
  static WindowDimensionsController? _dimensionsController;
  static Stopwatch s = Stopwatch();
  Timer? _storeDimensionsTimer;
  bool _isClosing = false;

  WindowDimensionsController _ensureDimensionsProvider() =>
      ref.watch(windowDimensionProvider);

  @override
  Widget build(BuildContext context) {
    _dimensionsController ??= _ensureDimensionsProvider();
    s.start();
    return widget.child;
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    if (checkPlatformIsDesktop()) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          // always handle close actions manually
          await windowManager.setPreventClose(true);
        } catch (e) {
          _logger.warning('Failed to set prevent close', e);
        }
      });
    }
  }

  @override
  void dispose() {
    _storeDimensionsTimer?.cancel();
    windowManager.removeListener(this);
    super.dispose();
  }

  void _scheduleStoreDimensions() {
    _storeDimensionsTimer?.cancel();
    _storeDimensionsTimer = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(_storeCurrentDimensions()),
    );
  }

  Future<void> _storeCurrentDimensions() async {
    try {
      final results = await Future.wait([
        windowManager.getPosition(),
        windowManager.getSize(),
      ]);
      await _dimensionsController?.storeDimensions(
        windowOffset: results[0] as Offset,
        windowSize: results[1] as Size,
      );
    } catch (e) {
      _logger.warning('Failed to save window dimensions', e);
    }
  }

  //Linux alternative for onWindowMoved and onWindowResized
  @override
  Future<void> onWindowMove() async {
    if (checkPlatform([TargetPlatform.linux]) && s.elapsedMilliseconds >= 600) {
      s.reset();
      final windowOffset = await windowManager.getPosition();
      final windowSize = await windowManager.getSize();
      await _dimensionsController?.storeDimensions(
          windowOffset: windowOffset, windowSize: windowSize);
    }
  }

  @override
  Future<void> onWindowMoved() async {
    if (_isWindowsCardMode) return;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      _scheduleStoreDimensions();
      return;
    }
    final windowOffset = await windowManager.getPosition();
    await _dimensionsController?.storePosition(windowOffset: windowOffset);
  }

  @override
  Future<void> onWindowResized() async {
    if (_isWindowsCardMode) return;
    if (defaultTargetPlatform == TargetPlatform.windows) {
      _scheduleStoreDimensions();
      return;
    }
    final windowSize = await windowManager.getSize();
    await _dimensionsController?.storeSize(windowSize: windowSize);
  }

  @override
  Future<void> onWindowClose() async {
    if (!checkPlatformIsDesktop()) {
      return;
    }
    if (_isClosing) return;
    _isClosing = true;
    _storeDimensionsTimer?.cancel();

    try {
      if (ref.read(settingsProvider).minimizeToTray) {
        // 用户点击关闭后先立即隐藏，窗口信息改为后台保存。
        await hideToTray();
        if (!_isWindowsCardMode) {
          unawaited(_storeCurrentDimensions());
        }
        _isClosing = false;
      } else {
        // 真正退出时也先让主窗口从视觉上立即消失。
        if (defaultTargetPlatform == TargetPlatform.windows) {
          await windowManager.hide();
        }
        if (!_isWindowsCardMode) {
          await _storeCurrentDimensions();
        }
        await destroyTray();
        exit(0);
      }
    } catch (e) {
      _isClosing = false;
      _logger.warning('Failed to close window', e);
    }
  }

  @override
  void onWindowFocus() {
    // call set state according to window_manager README
    setState(() {});
  }

  @override
  void onWindowMinimize() {
    ref.notifier(sleepProvider).setState((_) => true);
  }

  @override
  void onWindowRestore() {
    ref.notifier(sleepProvider).setState((_) => false);
  }

  bool get _isWindowsCardMode => WindowsReceiveCardController.isWindowCardMode;
}
