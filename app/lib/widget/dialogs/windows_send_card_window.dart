import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:common/model/device.dart';
import 'package:common/model/file_type.dart';
import 'package:common/model/session_status.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/persistence/color_mode.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/progress_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/device_type_ext.dart';
import 'package:localsend_app/util/file_size_helper.dart';
import 'package:localsend_app/util/file_speed_helper.dart';
import 'package:localsend_app/util/file_type_ext.dart';
import 'package:localsend_app/util/native/tray_helper.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:window_manager/window_manager.dart';

const _sendCardWindowType = 'windowsSendCard';
const _sendCardChannel = WindowMethodChannel(
  'tandrop.windows.send_card',
  mode: ChannelMode.unidirectional,
);
const _sendCardNativeChannel = MethodChannel(
  'tandrop/windows_send_card_native',
);
const double _sendCardCornerRadius = 16;

Brightness _brightnessFromSnapshot(
  Map<String, dynamic> snapshot,
  Brightness fallback,
) {
  return snapshot['brightness'] == Brightness.dark.name
      ? Brightness.dark
      : snapshot['brightness'] == Brightness.light.name
          ? Brightness.light
          : fallback;
}

bool isWindowsSendCardWindowArguments(String arguments) {
  try {
    final json = jsonDecode(arguments);
    return json is Map && json['type'] == _sendCardWindowType;
  } catch (_) {
    return false;
  }
}

Future<void> runWindowsSendCardWindow(String arguments) async {
  final controller = await WindowController.fromCurrentEngine();
  runApp(_WindowsSendCardWindowApp(controller: controller));
}

class WindowsSendCardWindowManager {
  WindowsSendCardWindowManager._();

  static WindowController? _controller;
  static Completer<void>? _closed;
  static bool _returnToTray = false;
  static Device? _suggestedTarget;

  static Future<void> open({
    Device? suggestedTarget,
    required bool returnToTray,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.windows) return;

    _returnToTray = returnToTray;
    _suggestedTarget = suggestedTarget;
    _closed ??= Completer<void>();

    _controller ??= await WindowController.create(
      const WindowConfiguration(
        arguments: '{"type":"windowsSendCard"}',
        hiddenAtLaunch: true,
      ),
    );

    // 子窗口自行在 Flutter 首帧绘制完成后显示，避免 Windows 先闪出默认白底。
    if (returnToTray) {
      await hideToTray();
    }
    return _closed!.future;
  }

  static Future<void> markClosed() async {
    _controller = null;
    if (_returnToTray) {
      await hideToTray();
    }
    _returnToTray = false;
    _suggestedTarget = null;
    final closed = _closed;
    _closed = null;
    if (closed != null && !closed.isCompleted) {
      closed.complete();
    }
  }

  static String? get suggestedTargetIp => _suggestedTarget?.ip;
}

class WindowsSendCardBridge extends StatefulWidget {
  final Widget child;

  const WindowsSendCardBridge({required this.child, super.key});

  @override
  State<WindowsSendCardBridge> createState() => _WindowsSendCardBridgeState();
}

class _WindowsSendCardBridgeState extends State<WindowsSendCardBridge>
    with Refena {
  String? _sessionId;
  SessionStatus? _terminalStatus;
  Timer? _resetTimer;
  bool _temporarilyUsesHttp = false;

  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform == TargetPlatform.windows) {
      unawaited(_sendCardChannel.setMethodCallHandler(_handleCall));
    }
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    if (defaultTargetPlatform == TargetPlatform.windows) {
      unawaited(_sendCardChannel.setMethodCallHandler(null));
    }
    super.dispose();
  }

  Future<dynamic> _handleCall(MethodCall call) async {
    switch (call.method) {
      case 'snapshot':
        return _snapshot();
      case 'refresh':
        unawaited(
          context.global.dispatchAsync(StartSmartScan(forceLegacy: true)),
        );
        return _snapshot();
      case 'startSend':
        final args = (call.arguments as Map?)?.cast<String, dynamic>() ??
            <String, dynamic>{};
        return _startSend(args['ip'] as String?);
      case 'cancel':
        final args = (call.arguments as Map?)?.cast<String, dynamic>() ??
            <String, dynamic>{};
        final sessionId = args['sessionId'] as String?;
        if (sessionId != null && sessionId == _sessionId) {
          ref.notifier(sendProvider).cancelSession(sessionId);
          _terminalStatus = SessionStatus.canceledBySender;
          _scheduleTerminalReset();
        }
        return _snapshot();
      case 'downloadQr':
        return _createDownloadQr();
      case 'close':
        try {
          await _restoreServerAfterQr();
        } catch (_) {
          // 恢复 HTTPS 失败也不能阻止独立卡片关闭。
        }
        await WindowsSendCardWindowManager.markClosed();
        return null;
      default:
        return null;
    }
  }

  Future<Map<String, dynamic>> _startSend(String? ip) async {
    final target =
        ip == null ? null : ref.read(nearbyDevicesProvider).devices[ip];
    final files = ref.read(selectedSendingFilesProvider);
    if (target == null || files.isEmpty) {
      return _snapshot();
    }

    _terminalStatus = null;
    _resetTimer?.cancel();
    final created = Completer<String>();
    String? startedSessionId;
    unawaited(
      ref
          .notifier(sendProvider)
          .startSession(
            target: target,
            files: files,
            background: true,
            onSessionCreated: (sessionId) {
              startedSessionId = sessionId;
              _sessionId = sessionId;
              if (!created.isCompleted) {
                created.complete(sessionId);
              }
            },
          )
          .then((status) {
        if (_sessionId != startedSessionId) return;
        _terminalStatus = status;
        _scheduleTerminalReset();
      }),
    );
    await created.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => '',
    );
    return _snapshot();
  }

  void _scheduleTerminalReset() {
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(seconds: 1), () {
      _resetSession();
      unawaited(
          context.global.dispatchAsync(StartSmartScan(forceLegacy: true)));
    });
  }

  void _resetSession() {
    _resetTimer?.cancel();
    final sessionId = _sessionId;
    if (sessionId != null) {
      ref.notifier(sendProvider).closeSession(sessionId);
    }
    _sessionId = null;
    _terminalStatus = null;
  }

  Future<Map<String, dynamic>> _createDownloadQr() async {
    try {
      final files = ref.read(selectedSendingFilesProvider);
      final localIps = ref.read(localIpProvider).localIps;
      // 重启服务后 Provider 返回值可为空，显式保留可空类型避免错误的类型提升。
      ServerState? server = ref.read(serverProvider);
      if (files.isEmpty || localIps.isEmpty) {
        return {'error': '无法生成二维码，请确认文件与网络可用'};
      }

      if (server == null) {
        await ref.notifier(serverProvider).startServerFromSettings();
        server = ref.read(serverProvider);
      }
      if (server == null) {
        return {'error': '网页下载服务启动失败'};
      }
      if (server.session != null) {
        return {'error': '正在接收文件，暂时无法开启网页下载'};
      }

      if (server.https) {
        final settings = ref.read(settingsProvider);
        await ref.notifier(serverProvider).restartServer(
              alias: settings.alias,
              port: settings.port,
              https: false,
            );
        // 保留可空类型，避免前面的非空判断让 Dart 错误缩窄赋值类型。
        final restartedServer = ref.read(serverProvider);
        server = restartedServer;
        _temporarilyUsesHttp = true;
      }
      if (server == null) {
        return {'error': '网页下载服务启动失败'};
      }

      // 复用现有网页下载服务，扫码设备无需安装 TanDrop。
      await ref.notifier(serverProvider).initializeWebSend(files);
      final pin = (math.Random.secure().nextInt(900000) + 100000).toString();
      ref.notifier(serverProvider).setWebSendPin(pin);
      ref.notifier(serverProvider).setWebSendAutoAccept(true);
      return {
        'url': 'http://${localIps.first}:${server.port}/?pin=$pin',
        'pin': pin,
      };
    } catch (_) {
      return {'error': '二维码生成失败，请稍后重试'};
    }
  }

  Future<void> _restoreServerAfterQr() async {
    if (!_temporarilyUsesHttp) return;
    _temporarilyUsesHttp = false;
    await ref.notifier(serverProvider).restartServerFromSettings();
  }

  Map<String, dynamic> _snapshot() {
    final files = ref.read(selectedSendingFilesProvider);
    final devices = ref.read(nearbyDevicesProvider).devices.values.toList()
      ..sort((a, b) {
        final suggested = WindowsSendCardWindowManager.suggestedTargetIp;
        if (a.ip == suggested) return -1;
        if (b.ip == suggested) return 1;
        return a.alias.compareTo(b.alias);
      });
    final session =
        _sessionId == null ? null : ref.read(sendProvider)[_sessionId];
    final status = session?.status ?? _terminalStatus;
    final metrics = _metricsOf(session, ref.read(progressProvider));

    return {
      // 独立 Flutter 引擎无法直接读取主窗口主题，通过快照同步。
      'brightness': _currentBrightness().name,
      'files': _filesToJson(files),
      'devices': devices.map(_deviceToJson).toList(),
      'session': {
        'id': _sessionId,
        'status': status?.name,
        'message': _messageOf(status, session),
        'progress': metrics.progress,
        'speedLabel': metrics.speedLabel,
        'remainingLabel': metrics.remainingLabel,
      },
    };
  }

  Brightness _currentBrightness() {
    final settings = ref.read(settingsProvider);
    if (settings.colorMode == ColorMode.oled ||
        settings.theme == ThemeMode.dark) {
      return Brightness.dark;
    }
    if (settings.theme == ThemeMode.light) {
      return Brightness.light;
    }
    return WidgetsBinding.instance.platformDispatcher.platformBrightness;
  }

  Map<String, dynamic> _filesToJson(List<CrossFile> files) {
    final total = files.fold<int>(0, (sum, file) => sum + file.size);
    final first = files.isEmpty ? null : files.first;
    return {
      'count': files.length,
      'totalSize': total,
      'firstName': first?.name ?? '未选择文件',
      'firstSize': first?.size ?? 0,
      'firstPath': first?.path,
      'firstType': first?.fileType.name,
      'firstThumbnail': first?.thumbnail,
    };
  }

  Map<String, dynamic> _deviceToJson(Device device) {
    return {
      'ip': device.ip,
      'alias': device.alias,
      'deviceModel': device.deviceModel,
      'deviceType': device.deviceType.name,
    };
  }

  String _messageOf(SessionStatus? status, SendSessionState? session) {
    return switch (status) {
      null => '正在搜索附近设备...',
      SessionStatus.waiting => '等待对方接受...',
      SessionStatus.sending => '正在发送',
      SessionStatus.finished => '发送完成',
      SessionStatus.declined => '对方已拒绝接收',
      SessionStatus.recipientBusy => '对方正在忙碌',
      SessionStatus.tooManyAttempts => '尝试次数过多',
      SessionStatus.canceledBySender => '已取消发送',
      SessionStatus.canceledByReceiver => '对方已取消接收',
      SessionStatus.finishedWithErrors => session?.errorMessage ?? '发送失败',
    };
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _WindowsSendCardWindowApp extends StatefulWidget {
  final WindowController controller;

  const _WindowsSendCardWindowApp({required this.controller});

  @override
  State<_WindowsSendCardWindowApp> createState() =>
      _WindowsSendCardWindowAppState();
}

class _WindowsSendCardWindowAppState extends State<_WindowsSendCardWindowApp>
    with WindowListener {
  Timer? _pollTimer;
  Map<String, dynamic>? _snapshot;
  bool _closing = false;
  String? _connectionError;
  String? _qrUrl;
  String? _qrPin;
  String? _qrError;
  bool _qrLoading = false;
  Brightness _brightness =
      WidgetsBinding.instance.platformDispatcher.platformBrightness;

  @override
  void initState() {
    super.initState();
    // 子窗口拥有独立 Flutter 引擎，需要单独关闭调试绘制标记。
    debugPaintSizeEnabled = false;
    debugPaintBaselinesEnabled = false;
    debugPaintPointersEnabled = false;
    debugRepaintRainbowEnabled = false;
    windowManager.addListener(this);
    unawaited(_initializeWindow());
  }

  Future<void> _initializeWindow() async {
    // 先取得主窗口主题，避免卡片先显示错误颜色再跳变。
    await _loadSnapshot(refresh: true);
    if (!mounted) return;
    await _configureWindow();
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => unawaited(_loadSnapshot()),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _configureWindow() async {
    await windowManager.ensureInitialized();
    final cardColor = _brightness == Brightness.dark
        ? const Color(0xFF2C2A28)
        : const Color(0xFFF7F7F7);
    final options = WindowOptions(
      size: const Size(720, 520),
      center: true,
      // 与卡片同色，避免 Flutter 圆角抗锯齿与透明黑底混合出黑边。
      // 外部四角仍由 Windows SetWindowRgn 真正裁掉。
      backgroundColor: cardColor,
      skipTaskbar: true,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.setPreventClose(true);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.waitUntilReadyToShow(options, () async {
      // 必须先完成尺寸设置，再裁剪真实顶层 HWND。
      await windowManager.setAsFrameless();
      await windowManager.setHasShadow(false);
      await _sendCardNativeChannel.invokeMethod<void>(
        'setRoundedRegion',
        _sendCardCornerRadius.round(),
      );
      // 等待 Flutter 首帧，不能让原生窗口的默认白底先暴露出来。
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await windowManager.show();
      // 显示后窗口 DPI/尺寸已稳定，再裁一次避免矩形外角。
      await _sendCardNativeChannel.invokeMethod<void>(
        'setRoundedRegion',
        _sendCardCornerRadius.round(),
      );
      await windowManager.focus();
    });
  }

  Future<void> _loadSnapshot({bool refresh = false}) async {
    try {
      final result = await _sendCardChannel.invokeMethod<Map<dynamic, dynamic>>(
        refresh ? 'refresh' : 'snapshot',
      );
      if (!mounted || result == null) return;
      final data = result.cast<String, dynamic>();
      final brightness = _brightnessFromSnapshot(data, _brightness);
      setState(() {
        _snapshot = data;
        _brightness = brightness;
        _connectionError = null;
      });
    } catch (_) {
      // 主窗口还在注册跨窗口通信时会短暂失败；轮询会自动重试。
      if (mounted) {
        setState(() => _connectionError = '正在连接 TanDrop…');
      }
    }
  }

  Future<void> _startSend(String ip) async {
    final result = await _sendCardChannel.invokeMethod<Map<dynamic, dynamic>>(
      'startSend',
      {'ip': ip},
    );
    if (!mounted || result == null) return;
    setState(() => _snapshot = result.cast<String, dynamic>());
  }

  Future<void> _showQr() async {
    setState(() {
      _qrLoading = true;
      _qrUrl = null;
      _qrPin = null;
      _qrError = null;
    });
    try {
      final result = await _sendCardChannel
          .invokeMethod<Map<dynamic, dynamic>>('downloadQr');
      if (!mounted) return;
      final data = result?.cast<String, dynamic>() ?? <String, dynamic>{};
      setState(() {
        _qrLoading = false;
        _qrUrl = data['url'] as String?;
        _qrPin = data['pin'] as String?;
        _qrError = data['error'] as String?;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _qrLoading = false;
        _qrError = '二维码生成失败，请稍后重试';
      });
    }
  }

  void _hideQr() {
    setState(() {
      _qrUrl = null;
      _qrPin = null;
      _qrError = null;
      _qrLoading = false;
    });
  }

  Future<void> _terminateTransfer() async {
    final session = (_snapshot?['session'] as Map?)?.cast<String, dynamic>();
    final sessionId = session?['id'] as String?;
    if (sessionId == null) return;
    final result = await _sendCardChannel.invokeMethod<Map<dynamic, dynamic>>(
      'cancel',
      {'sessionId': sessionId},
    );
    if (!mounted || result == null) return;
    setState(() => _snapshot = result.cast<String, dynamic>());
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    try {
      await _sendCardChannel.invokeMethod('close');
    } finally {
      // 主引擎已退出时通信会失败，子窗口仍必须能自行关闭。
      await windowManager.setPreventClose(false);
      await windowManager.close();
    }
  }

  @override
  Future<void> onWindowClose() => _close();

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF00A99D),
      brightness: _brightness,
      surface: _brightness == Brightness.dark
          ? const Color(0xFF2C2A28)
          : const Color(0xFFF7F7F7),
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: _brightness,
        colorScheme: colorScheme,
        scaffoldBackgroundColor: colorScheme.surface,
      ),
      home: ClipRRect(
        borderRadius: BorderRadius.circular(_sendCardCornerRadius),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: colorScheme.surface,
          child: _SendCardPanel(
            snapshot: _snapshot,
            connectionError: _connectionError,
            qrUrl: _qrUrl,
            qrPin: _qrPin,
            qrError: _qrError,
            qrLoading: _qrLoading,
            onRefresh: () => unawaited(_loadSnapshot(refresh: true)),
            onSend: (ip) => unawaited(_startSend(ip)),
            onQr: () => unawaited(_showQr()),
            onHideQr: _hideQr,
            onTerminate: () => unawaited(_terminateTransfer()),
            onClose: () => unawaited(_close()),
          ),
        ),
      ),
    );
  }
}

class _SendCardPanel extends StatelessWidget {
  final Map<String, dynamic>? snapshot;
  final String? connectionError;
  final String? qrUrl;
  final String? qrPin;
  final String? qrError;
  final bool qrLoading;
  final VoidCallback onRefresh;
  final ValueChanged<String> onSend;
  final VoidCallback onQr;
  final VoidCallback onHideQr;
  final VoidCallback onTerminate;
  final VoidCallback onClose;

  const _SendCardPanel({
    required this.snapshot,
    required this.connectionError,
    required this.qrUrl,
    required this.qrPin,
    required this.qrError,
    required this.qrLoading,
    required this.onRefresh,
    required this.onSend,
    required this.onQr,
    required this.onHideQr,
    required this.onTerminate,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final files = (snapshot?['files'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};
    final devices = (snapshot?['devices'] as List?)
            ?.cast<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList() ??
        <Map<String, dynamic>>[];
    final session = (snapshot?['session'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};
    final status = session['status'] as String?;
    final count = files['count'] as int? ?? 0;
    final totalSize = files['totalSize'] as int? ?? 0;
    final firstName = files['firstName'] as String? ?? '未选择文件';
    final isIdle = status == null;
    final isTransferring = status == SessionStatus.waiting.name ||
        status == SessionStatus.sending.name;
    final showingQr = qrLoading || qrUrl != null || qrError != null;

    return Container(
      width: 720,
      height: 520,
      padding: const EdgeInsets.fromLTRB(34, 26, 34, 28),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(_sendCardCornerRadius),
        border: Border.all(color: colors.outlineVariant, width: 1.4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: onClose,
                icon: Icon(Icons.close_rounded, color: colors.onSurfaceVariant),
              ),
              CircleAvatar(
                radius: 39,
                backgroundColor: Color(0xFF35699B),
                child: Icon(
                  Icons.person_rounded,
                  size: 54,
                  color: colors.surface,
                ),
              ),
              const SizedBox(width: 22),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'TanDrop',
                      style: TextStyle(
                        color: colors.onSurface,
                        fontSize: 34,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      '准备发送 $count 个项目',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 23,
                      ),
                    ),
                    Text(
                      '$firstName · ${totalSize.asReadableFileSize}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.onSurfaceVariant.withOpacity(0.8),
                        fontSize: 17,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 80,
                height: 80,
                child: _FilePreview(files: files),
              ),
            ],
          ),
          Divider(color: colors.outlineVariant, height: 34),
          Expanded(
            child: showingQr
                ? _QrDownloadView(
                    url: qrUrl,
                    pin: qrPin,
                    error: qrError,
                    loading: qrLoading,
                  )
                : isIdle
                    ? _DevicePicker(
                        devices: devices,
                        connectionError: connectionError,
                        onSend: onSend,
                      )
                    : _TransferStatus(session: session),
          ),
          Divider(color: colors.outlineVariant, height: 30),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: isIdle && !showingQr ? onRefresh : null,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('刷新设备'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: isIdle ? (showingQr ? onHideQr : onQr) : null,
                icon: Icon(
                  showingQr ? Icons.arrow_back_rounded : Icons.qr_code_rounded,
                ),
                label: Text(showingQr ? '返回设备' : '二维码'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: isTransferring ? onTerminate : onClose,
                style: FilledButton.styleFrom(
                  backgroundColor: isTransferring
                      ? Colors.red.shade700
                      : colors.surfaceContainerHighest,
                  foregroundColor:
                      isTransferring ? Colors.white : colors.onSurfaceVariant,
                ),
                child: Text(
                  isTransferring
                      ? '终止'
                      : isIdle
                          ? '取消'
                          : '关闭',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FilePreview extends StatelessWidget {
  final Map<String, dynamic> files;

  const _FilePreview({required this.files});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final typeName = files['firstType'] as String?;
    final fileType = FileType.values.firstWhere(
      (type) => type.name == typeName,
      orElse: () => FileType.other,
    );
    final thumbnail = files['firstThumbnail'] as Uint8List?;
    final path = files['firstPath'] as String?;
    final Widget preview;
    if (thumbnail != null) {
      preview = Image.memory(
        thumbnail,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Icon(fileType.icon, size: 38),
      );
    } else if (fileType == FileType.image && path != null) {
      preview = Image.file(
        File(path),
        fit: BoxFit.cover,
        cacheWidth: 180,
        errorBuilder: (_, __, ___) => Icon(fileType.icon, size: 38),
      );
    } else {
      preview = Icon(fileType.icon, size: 38);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ColoredBox(
        color: colors.secondaryContainer,
        child: IconTheme(
          data: IconThemeData(color: colors.onSecondaryContainer),
          child: Center(child: preview),
        ),
      ),
    );
  }
}

class _QrDownloadView extends StatelessWidget {
  final String? url;
  final String? pin;
  final String? error;
  final bool loading;

  const _QrDownloadView({
    required this.url,
    required this.pin,
    required this.error,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 3));
    }
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded,
                color: Colors.redAccent, size: 44),
            const SizedBox(height: 12),
            Text(
              error!,
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 18),
            ),
          ],
        ),
      );
    }
    if (url == null) return const SizedBox.shrink();

    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 190,
            height: 190,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
            ),
            child: PrettyQrView.data(
              data: url!,
              errorCorrectLevel: QrErrorCorrectLevel.Q,
              decoration: const PrettyQrDecoration(
                shape: PrettyQrSmoothSymbol(roundFactor: 0),
              ),
            ),
          ),
          const SizedBox(width: 24),
          SizedBox(
            width: 230,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '扫码下载文件',
                  style: TextStyle(
                    color: colors.onSurface,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '手机连接同一局域网后，用浏览器扫码即可下载。',
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 15,
                  ),
                ),
                if (pin != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    '访问码  $pin',
                    style: TextStyle(
                      color: colors.onSurface,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DevicePicker extends StatelessWidget {
  final List<Map<String, dynamic>> devices;
  final String? connectionError;
  final ValueChanged<String> onSend;

  const _DevicePicker({
    required this.devices,
    required this.connectionError,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (devices.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 14),
            Text(
              connectionError ?? '正在搜索附近设备…',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 18),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
      itemCount: devices.length,
      separatorBuilder: (_, __) => const SizedBox(width: 16),
      itemBuilder: (_, index) {
        final device = devices[index];
        final ip = device['ip'] as String;
        final deviceTypeName = device['deviceType'] as String?;
        final deviceType = DeviceType.values.firstWhere(
          (type) => type.name == deviceTypeName,
          orElse: () => DeviceType.desktop,
        );
        final alias = device['alias'] as String? ?? ip;
        return SizedBox(
          width: 112,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => onSend(ip),
              borderRadius: BorderRadius.circular(18),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 8),
                child: Column(
                  children: [
                    Container(
                      width: 78,
                      height: 78,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colors.surfaceContainerHighest,
                        border: Border.all(
                          color: colors.outline,
                          width: 1.5,
                        ),
                      ),
                      child: Icon(
                        deviceType.icon,
                        color: colors.onSurface,
                        size: 38,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      alias,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: colors.onSurface,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      device['deviceModel'] as String? ?? '点击发送',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TransferStatus extends StatelessWidget {
  final Map<String, dynamic> session;

  const _TransferStatus({required this.session});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final status = session['status'] as String?;
    final progress = (session['progress'] as num?)?.toDouble() ?? 0;
    final finished = status == SessionStatus.finished.name;
    final failed = status == SessionStatus.finishedWithErrors.name ||
        status == SessionStatus.declined.name ||
        status == SessionStatus.canceledBySender.name ||
        status == SessionStatus.canceledByReceiver.name ||
        status == SessionStatus.recipientBusy.name ||
        status == SessionStatus.tooManyAttempts.name;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            finished
                ? Icons.check_circle_rounded
                : failed
                    ? Icons.cancel_rounded
                    : Icons.send_rounded,
            color: finished
                ? Colors.greenAccent
                : failed
                    ? Colors.redAccent
                    : colors.primary,
            size: 54,
          ),
          const SizedBox(height: 16),
          Text(
            session['message'] as String? ?? '正在发送',
            style: TextStyle(
              color: colors.onSurface,
              fontSize: 24,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (status == SessionStatus.sending.name) ...[
            const SizedBox(height: 22),
            SizedBox(
              width: 420,
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 10,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '${(progress * 100).toStringAsFixed(0)}%  ·  '
              '${session['speedLabel']}  ·  ${session['remainingLabel']}',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 17),
            ),
          ],
        ],
      ),
    );
  }
}

class _TransferMetrics {
  final double progress;
  final String speedLabel;
  final String remainingLabel;

  const _TransferMetrics({
    required this.progress,
    required this.speedLabel,
    required this.remainingLabel,
  });
}

_TransferMetrics _metricsOf(
  SendSessionState? session,
  ProgressNotifier notifier,
) {
  if (session == null || session.files.isEmpty) {
    return const _TransferMetrics(
      progress: 0,
      speedLabel: '计算中',
      remainingLabel: '剩余 --',
    );
  }
  final active = session.files.values.where((file) => file.token != null);
  final total = active.fold<int>(0, (sum, file) => sum + file.file.size);
  if (total == 0) {
    return const _TransferMetrics(
      progress: 0,
      speedLabel: '计算中',
      remainingLabel: '剩余 --',
    );
  }
  final current = active.fold<int>(
    0,
    (sum, file) =>
        sum +
        (notifier.getProgress(
                  sessionId: session.sessionId,
                  fileId: file.file.id,
                ) *
                file.file.size)
            .round(),
  );
  final progress = current / total;
  if (session.startTime == null || current < 500 * 1024) {
    return _TransferMetrics(
      progress: progress,
      speedLabel: '计算中',
      remainingLabel: '剩余 --',
    );
  }
  final speed = getFileSpeed(
    start: session.startTime!,
    end: DateTime.now().millisecondsSinceEpoch,
    bytes: current,
  );
  return _TransferMetrics(
    progress: progress,
    speedLabel: '${speed.asReadableFileSize}/s',
    remainingLabel: getRemainingTime(
      bytesPerSeconds: speed,
      remainingBytes: total - current,
    ),
  );
}
