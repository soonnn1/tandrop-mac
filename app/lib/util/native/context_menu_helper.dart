import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

final _logger = Logger('ContextMenuHelper');

Future<bool> enableContextMenu() async {
  if (defaultTargetPlatform != TargetPlatform.windows) {
    return false;
  }

  try {
    final targetPath = _escapePowerShellLiteral(Platform.resolvedExecutable);
    final shortcutPath =
        _escapePowerShellLiteral(_getWindowsFilePath(_windowsFileName));
    final workingDirectory =
        _escapePowerShellLiteral(File(Platform.resolvedExecutable).parent.path);
    final String script = '''
\$TargetPath = '$targetPath'
\$ShortcutFile = '$shortcutPath'
\$WScriptShell = New-Object -ComObject WScript.Shell
\$Shortcut = \$WScriptShell.CreateShortcut(\$ShortcutFile)
\$Shortcut.TargetPath = \$TargetPath
\$Shortcut.WorkingDirectory = '$workingDirectory'
\$Shortcut.IconLocation = \$TargetPath
\$Shortcut.Description = 'Send files with TanDrop'
\$Shortcut.Save()
''';
    final result = await Process.run('powershell', ['-Command', script]);
    if (result.exitCode != 0) {
      throw Exception('Failed to create shortcut: ${result.stderr}');
    }
    final enabled = await File(_getWindowsFilePath(_windowsFileName)).exists();
    if (enabled) {
      // 品牌改名后清理旧入口，避免“发送到”中同时出现两个应用名。
      await _deleteWindowsShortcut(_legacyWindowsFileName);
    }
    return enabled;
  } catch (e) {
    _logger.severe('Failed to enable context menu: $e');
    return false;
  }
}

Future<bool> disableContextMenu() async {
  try {
    switch (defaultTargetPlatform) {
      case TargetPlatform.windows:
        await _deleteWindowsShortcut(_windowsFileName);
        await _deleteWindowsShortcut(_legacyWindowsFileName);
        return true;
      default:
        return false;
    }
  } catch (e) {
    return false;
  }
}

Future<bool> isContextMenuEnabled() async {
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
      return await File(_getWindowsFilePath(_windowsFileName)).exists();
    default:
      return false;
  }
}

const _windowsFileName = 'TanDrop';
const _legacyWindowsFileName = 'LocalSend';

String _getWindowsFilePath(String appName) {
  final appData = Platform.environment['APPDATA'];
  if (appData == null || appData.isEmpty) {
    throw StateError('APPDATA is unavailable');
  }
  return '$appData/Microsoft/Windows/SendTo/$appName.lnk';
}

String _escapePowerShellLiteral(String value) => value.replaceAll("'", "''");

Future<void> _deleteWindowsShortcut(String name) async {
  final file = File(_getWindowsFilePath(name));
  if (await file.exists()) {
    await file.delete();
  }
}
