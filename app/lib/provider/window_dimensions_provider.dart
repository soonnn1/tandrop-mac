import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:localsend_app/provider/persistence_provider.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

class WindowDimensions {
  final Offset position;
  final Size size;

  WindowDimensions({
    required this.position,
    required this.size,
  });
}

final windowDimensionProvider = Provider<WindowDimensionsController>((ref) {
  return WindowDimensionsController(ref.read(persistenceProvider));
});

const Size _minimalSize = Size(400, 500);
const Size _defaultSize = Size(900, 600);
const Size _macOSMinimalSize = Size(1180, 760);
const Size _macOSDefaultSize = Size(1280, 840);

class WindowDimensionsController {
  final PersistenceService _service;

  WindowDimensionsController(this._service);

  /// Sets window position & size according to saved settings.
  Future<void> initDimensionsConfiguration() async {
    final minimalSize = _platformMinimalSize;
    final defaultSize = _platformDefaultSize;
    await WindowManager.instance.setMinimumSize(minimalSize);

    // load saved Window placement and preferences
    final useSavedPlacement = _service.getSaveWindowPlacement();
    final persistedDimensions = _service.getWindowLastDimensions();

    if (useSavedPlacement &&
        persistedDimensions != null &&
        await isInScreenBounds(
            persistedDimensions.position, persistedDimensions.size)) {
      // macOS 新仪表盘需要更大的默认可视区域；旧版本保存的小窗口不再直接复用。
      await WindowManager.instance.setSize(
        _clampToMinimum(persistedDimensions.size, minimalSize),
      );
      await WindowManager.instance.setPosition(persistedDimensions.position);
    } else {
      final primaryDisplay = await ScreenRetriever.instance.getPrimaryDisplay();
      final hasEnoughWidthForDefaultSize =
          primaryDisplay.digestedSize.width >= 1200;
      await WindowManager.instance
          .setSize(hasEnoughWidthForDefaultSize ? defaultSize : minimalSize);
      await WindowManager.instance.center();
    }
  }

  Size get _platformMinimalSize {
    return defaultTargetPlatform == TargetPlatform.macOS
        ? _macOSMinimalSize
        : _minimalSize;
  }

  Size get _platformDefaultSize {
    return defaultTargetPlatform == TargetPlatform.macOS
        ? _macOSDefaultSize
        : _defaultSize;
  }

  Size _clampToMinimum(Size size, Size minimum) {
    return Size(
      size.width < minimum.width ? minimum.width : size.width,
      size.height < minimum.height ? minimum.height : size.height,
    );
  }

  Future<bool> isInScreenBounds(Offset windowPosition,
      [Size? windowSize]) async {
    final displays = await ScreenRetriever.instance.getAllDisplays();
    final sumWidth = displays.fold(0.0,
        (previousValue, element) => previousValue + element.digestedSize.width);
    final maxHeight = displays.fold(
      0.0,
      (previousValue, element) => previousValue > element.digestedSize.height
          ? previousValue
          : element.digestedSize.height,
    );
    final minX = displays.fold(0.0, (previousValue, element) {
      final currX = element.visiblePosition?.dx ?? 0;
      return currX < previousValue ? currX : previousValue;
    });
    final minY = displays.fold(0.0, (previousValue, element) {
      final currY = element.visiblePosition?.dy ?? 0;
      return currY < previousValue ? currY : previousValue;
    });
    final checkX = windowPosition.dx >= minX &&
        windowPosition.dx + (windowSize?.width ?? 0) <= sumWidth;
    final checkY = windowPosition.dy >= minY &&
        windowPosition.dy + (windowSize?.height ?? 0) <= maxHeight;

    return checkX && checkY;
  }

  Future<void> storeDimensions({
    required Offset windowOffset,
    required Size windowSize,
  }) async {
    if (await isInScreenBounds(windowOffset)) {
      await _service.setWindowOffsetX(windowOffset.dx);
      await _service.setWindowOffsetY(windowOffset.dy);
      await _service.setWindowHeight(windowSize.height);
      await _service.setWindowWidth(windowSize.width);
    }
  }

  Future<void> storePosition({required Offset windowOffset}) async {
    if (await isInScreenBounds(windowOffset)) {
      await _service.setWindowOffsetX(windowOffset.dx);
      await _service.setWindowOffsetY(windowOffset.dy);
    }
  }

  Future<void> storeSize({required Size windowSize}) async {
    await _service.setWindowHeight(windowSize.height);
    await _service.setWindowWidth(windowSize.width);
  }
}

extension on Display {
  Size get digestedSize => visibleSize ?? size;
}
