import 'dart:async';

import 'package:flutter/services.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/util/native/taskbar_helper.dart';
import 'package:localsend_app/util/native/tray_helper.dart';

const _methodChannel = MethodChannel('main-delegate-channel');

Future<void> setupStatusBar() async {
  await _methodChannel.invokeMethod('setupStatusBar', {
    'open': t.tray.open,
    'quit': t.tray.close,
  });
}

Future<void> removeExistingDestinationAccess() async {
  await _methodChannel.invokeMethod('removeExistingDestinationAccess');
}

Future<void> persistDestinationFolderAccess(String path) async {
  await _methodChannel.invokeMethod('persistDestinationFolderAccess', path);
}

Future<void> updateDockProgress(double progress) async {
  await _methodChannel.invokeMethod('updateDockProgress', progress);
}

Future<void> setLaunchAtLogin(bool value) async {
  await _methodChannel.invokeMethod('setLaunchAtLogin', value);
}

Future<bool> getLaunchAtLogin() async {
  return await _methodChannel.invokeMethod('getLaunchAtLogin');
}

Future<void> setLaunchAtLoginMinimized(bool value) async {
  await _methodChannel.invokeMethod('setLaunchAtLoginMinimized', value);
}

Future<bool> getLaunchAtLoginMinimized() async {
  return await _methodChannel.invokeMethod('getLaunchAtLoginMinimized');
}

Future<bool> isLaunchedAsLoginItem() async {
  return await _methodChannel.invokeMethod('isLaunchedAsLoginItem');
}

Future<void> setDockIcon(TaskbarIcon icon) async {
  await _methodChannel.invokeMethod('setDockIcon', icon.index);
}

// This happens:
/// - on macOS when text is dropped onto the app Dock icon
/// - on macOS when text is dropped onto the app menu bar icon
/// - on macOS when text\web link are shared to the app using the share extension (i.e. the system share menu)
final _pendingFilesStreamController =
    StreamController<List<String>>.broadcast();
Stream<List<String>> get pendingFilesStream =>
    _pendingFilesStreamController.stream;

/// This happens:
/// - on macOS when text is dropped onto the app Dock icon
/// - on macOS when text is dropped onto the app menu bar icon
/// - on macOS when text\web link are shared to the app using the share extension (i.e. the system share menu)
final _pendingStringsStreamController =
    StreamController<List<String>>.broadcast();
Stream<List<String>> get pendingStringsStream =>
    _pendingStringsStreamController.stream;

final _receivePanelActionStreamController =
    StreamController<String>.broadcast();
Stream<String> get receivePanelActionStream =>
    _receivePanelActionStreamController.stream;

final _sendPanelActionStreamController =
    StreamController<Map<String, dynamic>>.broadcast();
Stream<Map<String, dynamic>> get sendPanelActionStream =>
    _sendPanelActionStreamController.stream;

Future<void> updateSendPanelDevices({
  required List<Map<String, dynamic>> devices,
}) async {
  await _methodChannel.invokeMethod('updateSendPanelDevices', {
    'devices': devices,
  });
}

Future<void> updateSendPanelStatus({
  required String status,
  String? detail,
  double? progress,
}) async {
  await _methodChannel.invokeMethod('updateSendPanelStatus', {
    'status': status,
    'detail': detail,
    'progress': progress,
  });
}

/// 在原生发送卡片中显示当前文件的浏览器下载二维码。
Future<void> showSendPanelQr({required String url}) async {
  await _methodChannel.invokeMethod('showSendPanelQr', {'url': url});
}

Future<void> showReceivePanel({
  required String senderAlias,
  required String fileName,
  required int fileCount,
  required int totalSize,
  required String destination,
}) async {
  await _methodChannel.invokeMethod('showReceivePanel', {
    'senderAlias': senderAlias,
    'fileName': fileName,
    'fileCount': fileCount,
    'totalSize': totalSize,
    'destination': destination,
  });
}

Future<void> updateReceivePanel({
  required String status,
  required double progress,
  String? currentFile,
  String? openPath,
  String? folderPath,
}) async {
  await _methodChannel.invokeMethod('updateReceivePanel', {
    'status': status,
    'progress': progress,
    'currentFile': currentFile,
    'openPath': openPath,
    'folderPath': folderPath,
  });
}

Future<void> hideReceivePanel() async {
  await _methodChannel.invokeMethod('hideReceivePanel');
}

/// Sets up the method call handler.
/// Any call from swift native code is dropped until this method is called.
Future<void> setupMethodCallHandler() async {
  _methodChannel.setMethodCallHandler((call) async {
    switch (call.method) {
      case 'onPendingFiles':
        _pendingFilesStreamController
            .add((call.arguments as List).cast<String>());
        break;
      case 'onPendingStrings':
        _pendingStringsStreamController
            .add((call.arguments as List).cast<String>());
        break;
      case 'showLocalSendFromMenuBar':
        await showFromTray();
        break;
      case 'receivePanelAction':
        _receivePanelActionStreamController.add(call.arguments as String);
        break;
      case 'sendPanelAction':
        _sendPanelActionStreamController
            .add(Map<String, dynamic>.from(call.arguments as Map));
        break;
    }
  });

  await _methodChannel.invokeMethod('methodChannelInitialized');
}
