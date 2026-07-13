import 'dart:async';
import 'dart:convert';

import 'package:common/model/device.dart';
import 'package:common/model/session_status.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/progress_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/device_type_ext.dart';
import 'package:localsend_app/util/file_size_helper.dart';
import 'package:localsend_app/util/file_speed_helper.dart';
import 'package:localsend_app/util/native/tray_helper.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:window_manager/window_manager.dart';

const _sendCardWindowType = 'windowsSendCard';
const _sendCardChannel = WindowMethodChannel(
  'tandrop.windows.send_card',
  mode: ChannelMode.unidirectional,
);

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

    await _controller!.show();
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

  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform == TargetPlatform.windows) {
      unawaited(_sendCardChannel.setMethodCallHandler(_handleCall));
    }
  }

  @override
  void dispose() {
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
        final sessionId = _sessionId;
        if (sessionId != null) {
          ref.notifier(sendProvider).cancelSession(sessionId);
        }
        return _snapshot();
      case 'close':
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
    final created = Completer<String>();
    unawaited(
      ref
          .notifier(sendProvider)
          .startSession(
            target: target,
            files: files,
            background: true,
            onSessionCreated: (sessionId) {
              _sessionId = sessionId;
              if (!created.isCompleted) {
                created.complete(sessionId);
              }
            },
          )
          .then((status) {
        _terminalStatus = status;
      }),
    );
    await created.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => '',
    );
    return _snapshot();
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

  Map<String, dynamic> _filesToJson(List<CrossFile> files) {
    final total = files.fold<int>(0, (sum, file) => sum + file.size);
    return {
      'count': files.length,
      'totalSize': total,
      'firstName': files.isEmpty ? '未选择文件' : files.first.name,
      'firstSize': files.isEmpty ? 0 : files.first.size,
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

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(_configureWindow());
    unawaited(_loadSnapshot(refresh: true));
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
    const options = WindowOptions(
      size: Size(760, 560),
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: true,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.setPreventClose(true);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  Future<void> _loadSnapshot({bool refresh = false}) async {
    final result = await _sendCardChannel.invokeMethod<Map<dynamic, dynamic>>(
      refresh ? 'refresh' : 'snapshot',
    );
    if (!mounted || result == null) return;
    setState(() => _snapshot = result.cast<String, dynamic>());
  }

  Future<void> _startSend(String ip) async {
    final result = await _sendCardChannel.invokeMethod<Map<dynamic, dynamic>>(
      'startSend',
      {'ip': ip},
    );
    if (!mounted || result == null) return;
    setState(() => _snapshot = result.cast<String, dynamic>());
  }

  Future<void> _cancelOrClose() async {
    final session = (_snapshot?['session'] as Map?)?.cast<String, dynamic>();
    final status = session?['status'] as String?;
    if (status == 'waiting' || status == 'sending') {
      await _sendCardChannel.invokeMethod('cancel');
    }
    await _close();
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    await _sendCardChannel.invokeMethod('close');
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  @override
  Future<void> onWindowClose() => _close();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF151413),
        body: Center(
          child: _SendCardPanel(
            snapshot: _snapshot,
            onRefresh: () => unawaited(_loadSnapshot(refresh: true)),
            onSend: (ip) => unawaited(_startSend(ip)),
            onClose: () => unawaited(_cancelOrClose()),
          ),
        ),
      ),
    );
  }
}

class _SendCardPanel extends StatelessWidget {
  final Map<String, dynamic>? snapshot;
  final VoidCallback onRefresh;
  final ValueChanged<String> onSend;
  final VoidCallback onClose;

  const _SendCardPanel({
    required this.snapshot,
    required this.onRefresh,
    required this.onSend,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
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

    return Container(
      width: 720,
      height: 520,
      padding: const EdgeInsets.fromLTRB(34, 26, 34, 28),
      decoration: BoxDecoration(
        color: const Color(0xFF2C2A28),
        borderRadius: BorderRadius.circular(34),
        border: Border.all(color: const Color(0xFF6B6864), width: 1.4),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 36)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: onClose,
                icon: const Icon(Icons.close_rounded, color: Colors.white70),
              ),
              const CircleAvatar(
                radius: 39,
                backgroundColor: Color(0xFF35699B),
                child: Icon(
                  Icons.person_rounded,
                  size: 54,
                  color: Color(0xFF2C2A28),
                ),
              ),
              const SizedBox(width: 22),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'TanDrop',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 34,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      '准备发送 $count 个项目',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 23,
                      ),
                    ),
                    Text(
                      '$firstName · ${totalSize.asReadableFileSize}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 17,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 80, height: 80, child: _FilePreview()),
            ],
          ),
          const Divider(color: Color(0xFF68645F), height: 34),
          Expanded(
            child: isIdle
                ? _DevicePicker(devices: devices, onSend: onSend)
                : _TransferStatus(session: session),
          ),
          const Divider(color: Color(0xFF68645F), height: 30),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: isIdle ? onRefresh : null,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('刷新设备'),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: isIdle ? () {} : null,
                icon: const Icon(Icons.qr_code_rounded),
                label: const Text('二维码'),
              ),
              const Spacer(),
              FilledButton(
                onPressed: onClose,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF56524F),
                ),
                child: Text(isIdle ? '取消' : '关闭'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FilePreview extends StatelessWidget {
  const _FilePreview();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFFD7F0EA),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Center(
        child: Icon(Icons.attach_file_rounded, color: Color(0xFF1D2C2A)),
      ),
    );
  }
}

class _DevicePicker extends StatelessWidget {
  final List<Map<String, dynamic>> devices;
  final ValueChanged<String> onSend;

  const _DevicePicker({required this.devices, required this.onSend});

  @override
  Widget build(BuildContext context) {
    if (devices.isEmpty) {
      return const Center(
        child: Text(
          '正在搜索附近设备...',
          style: TextStyle(color: Colors.white70, fontSize: 20),
        ),
      );
    }
    return ListView.separated(
      itemCount: devices.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, index) {
        final device = devices[index];
        final ip = device['ip'] as String;
        final deviceType = device['deviceType'] == 'mobile'
            ? DeviceType.mobile
            : DeviceType.desktop;
        return ListTile(
          tileColor: const Color(0xFF3A3734),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          leading: Icon(deviceType.icon, color: Colors.white, size: 32),
          title: Text(
            device['alias'] as String? ?? ip,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Text(
            device['deviceModel'] as String? ?? ip,
            style: const TextStyle(color: Colors.white60),
          ),
          trailing: FilledButton(
            onPressed: () => onSend(ip),
            child: const Text('发送'),
          ),
          onTap: () => onSend(ip),
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
                    : Colors.white,
            size: 54,
          ),
          const SizedBox(height: 16),
          Text(
            session['message'] as String? ?? '正在发送',
            style: const TextStyle(
              color: Colors.white,
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
              style: const TextStyle(color: Colors.white70, fontSize: 17),
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
