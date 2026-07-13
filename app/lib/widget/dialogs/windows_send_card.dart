import 'package:common/model/device.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/widget/dialogs/windows_send_card_window.dart';

/// Windows 发送卡片入口。
///
/// 当前实现打开真正的独立 Flutter 窗口，主窗口只负责 Provider 和传输逻辑。
class WindowsSendCard {
  const WindowsSendCard._();

  static Future<void> open(
    BuildContext context, {
    Device? suggestedTarget,
    bool returnToTray = false,
  }) {
    return WindowsSendCardWindowManager.open(
      suggestedTarget: suggestedTarget,
      returnToTray: returnToTray,
    );
  }
}
