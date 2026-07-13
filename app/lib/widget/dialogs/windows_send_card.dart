import 'dart:async';

import 'package:common/model/device.dart';
import 'package:common/model/session_status.dart';
import 'package:flutter/material.dart';
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
import 'package:localsend_app/widget/file_thumbnail.dart';
import 'package:refena_flutter/refena_flutter.dart';

/// Windows 端的 AirDrop 风格发送浮动卡片。
class WindowsSendCard extends StatefulWidget {
  final Device? suggestedTarget;

  const WindowsSendCard({this.suggestedTarget, super.key});

  static bool _isOpen = false;

  static Future<void> open(
    BuildContext context, {
    Device? suggestedTarget,
  }) async {
    if (_isOpen) return;
    _isOpen = true;
    try {
      await showGeneralDialog<void>(
        context: context,
        barrierDismissible: false,
        barrierLabel: 'Windows send card',
        // 分享启动时完全遮住仪表盘，用户只看到发送卡片。
        barrierColor: const Color(0xFF151413),
        pageBuilder: (_, __, ___) => Center(
          child: WindowsSendCard(suggestedTarget: suggestedTarget),
        ),
      );
    } finally {
      _isOpen = false;
    }
  }

  @override
  State<WindowsSendCard> createState() => _WindowsSendCardState();
}

class _WindowsSendCardState extends State<WindowsSendCard> with Refena {
  String? _sessionId;
  SessionStatus? _terminalStatus;
  bool _starting = false;
  Timer? _closeTimer;

  @override
  void dispose() {
    _closeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final files = ref.watch(selectedSendingFilesProvider);
    final devices = ref.watch(nearbyDevicesProvider).devices.values.toList();
    final session = _sessionId == null ? null : ref.watch(sendProvider)[_sessionId];
    final progressNotifier = ref.watch(progressProvider);
    final status = session?.status ?? _terminalStatus;
    final metrics = _metricsOf(session, progressNotifier);

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 720,
        constraints: const BoxConstraints(maxHeight: 560),
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
            _Header(files: files, onClose: _cancelOrClose),
            const Divider(color: Color(0xFF68645F), height: 34),
            Expanded(
              child: status == null && !_starting
                  ? _DevicePicker(
                      devices: devices,
                      suggestedTarget: widget.suggestedTarget,
                      onSend: _start,
                    )
                  : _TransferStatus(
                      status: status,
                      session: session,
                      metrics: metrics,
                    ),
            ),
            const Divider(color: Color(0xFF68645F), height: 30),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: status == null && !_starting
                      ? () => unawaited(context.global.dispatchAsync(StartSmartScan(forceLegacy: true)))
                      : null,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('刷新设备'),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: status == null && !_starting ? _showQrNotice : null,
                  icon: const Icon(Icons.qr_code_rounded),
                  label: const Text('二维码'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: _cancelOrClose,
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFF56524F)),
                  child: Text(_sessionId == null ? '取消' : '关闭'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _start(Device target) async {
    final files = ref.read(selectedSendingFilesProvider);
    if (files.isEmpty) return;
    setState(() => _starting = true);
    final result = await ref.notifier(sendProvider).startSession(
          target: target,
          files: files,
          background: true,
          onSessionCreated: (id) {
            if (mounted) setState(() => _sessionId = id);
          },
        );
    if (!mounted) return;
    setState(() {
      _starting = false;
      _terminalStatus = result;
    });
    if (result == SessionStatus.finished) {
      _closeTimer = Timer(const Duration(seconds: 2), _close);
    }
  }

  void _cancelOrClose() {
    if (_sessionId != null && _terminalStatus == null) {
      ref.notifier(sendProvider).cancelSession(_sessionId!);
    }
    _close();
  }

  void _close() {
    if (mounted) Navigator.of(context).pop();
  }

  void _showQrNotice() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('二维码下载将在下一步接入网页下载服务。')),
    );
  }
}

class _Header extends StatelessWidget {
  final List<CrossFile> files;
  final VoidCallback onClose;

  const _Header({required this.files, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final total = files.fold<int>(0, (sum, file) => sum + file.size);
    return Row(children: [
      IconButton(onPressed: onClose, icon: const Icon(Icons.close_rounded, color: Colors.white70)),
      const CircleAvatar(radius: 39, backgroundColor: Color(0xFF35699B), child: Icon(Icons.person_rounded, size: 54, color: Color(0xFF2C2A28))),
      const SizedBox(width: 22),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('TanDrop', style: TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w800)),
        Text('准备发送 ${files.length} 个项目', style: const TextStyle(color: Colors.white70, fontSize: 23)),
        Text(files.isEmpty ? '未选择文件' : '${files.first.name} · ${total.asReadableFileSize}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60, fontSize: 17)),
      ])),
      SizedBox(width: 80, height: 80, child: files.isEmpty ? const Icon(Icons.insert_drive_file_outlined, color: Colors.white54, size: 45) : ClipRRect(borderRadius: BorderRadius.circular(12), child: SmartFileThumbnail.fromCrossFile(files.first))),
    ]);
  }
}

class _DevicePicker extends StatelessWidget {
  final List<Device> devices;
  final Device? suggestedTarget;
  final ValueChanged<Device> onSend;

  const _DevicePicker({required this.devices, required this.suggestedTarget, required this.onSend});

  @override
  Widget build(BuildContext context) {
    if (devices.isEmpty) return const Center(child: Text('正在搜索附近设备…', style: TextStyle(color: Colors.white70, fontSize: 20)));
    final ordered = [...devices]..sort((a, b) => a.ip == suggestedTarget?.ip ? -1 : 0);
    return ListView.separated(
      itemCount: ordered.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, index) {
        final device = ordered[index];
        return ListTile(
          tileColor: const Color(0xFF3A3734),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          leading: Icon(device.deviceType.icon, color: Colors.white, size: 32),
          title: Text(device.alias, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          subtitle: Text(device.deviceModel ?? device.ip, style: const TextStyle(color: Colors.white60)),
          trailing: FilledButton(onPressed: () => onSend(device), child: const Text('发送')),
          onTap: () => onSend(device),
        );
      },
    );
  }
}

class _TransferStatus extends StatelessWidget {
  final SessionStatus? status;
  final SendSessionState? session;
  final _TransferMetrics metrics;

  const _TransferStatus({required this.status, required this.session, required this.metrics});

  @override
  Widget build(BuildContext context) {
    final text = switch (status) {
      null || SessionStatus.waiting => '等待对方接受…',
      SessionStatus.sending => '正在发送',
      SessionStatus.finished => '发送完成',
      SessionStatus.declined => '对方已拒绝接收',
      SessionStatus.recipientBusy => '对方正在忙碌',
      SessionStatus.tooManyAttempts => '尝试次数过多',
      SessionStatus.canceledBySender => '已取消发送',
      SessionStatus.canceledByReceiver => '对方已取消接收',
      SessionStatus.finishedWithErrors => session?.errorMessage ?? '发送失败，请重试',
    };
    return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Icon(status == SessionStatus.finished ? Icons.check_circle_rounded : Icons.send_rounded, color: status == SessionStatus.finished ? Colors.greenAccent : Colors.white, size: 54),
      const SizedBox(height: 16),
      Text(text, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700)),
      if (status == SessionStatus.sending) ...[
        const SizedBox(height: 22),
        SizedBox(width: 420, child: LinearProgressIndicator(value: metrics.progress, minHeight: 10, borderRadius: BorderRadius.circular(10))),
        const SizedBox(height: 10),
        Text('${(metrics.progress * 100).toStringAsFixed(0)}%  ·  ${metrics.speedLabel}  ·  ${metrics.remainingLabel}', style: const TextStyle(color: Colors.white70, fontSize: 17)),
      ],
    ]));
  }
}

class _TransferMetrics {
  final double progress;
  final String speedLabel;
  final String remainingLabel;

  const _TransferMetrics({required this.progress, required this.speedLabel, required this.remainingLabel});
}

_TransferMetrics _metricsOf(SendSessionState? session, ProgressNotifier notifier) {
  if (session == null || session.files.isEmpty) return const _TransferMetrics(progress: 0, speedLabel: '计算中', remainingLabel: '剩余 --');
  final active = session.files.values.where((file) => file.token != null);
  final total = active.fold<int>(0, (sum, file) => sum + file.file.size);
  if (total == 0) return const _TransferMetrics(progress: 0, speedLabel: '计算中', remainingLabel: '剩余 --');
  final current = active.fold<int>(0, (sum, file) => sum + (notifier.getProgress(sessionId: session.sessionId, fileId: file.file.id) * file.file.size).round());
  final progress = current / total;
  if (session.startTime == null || current < 500 * 1024) return _TransferMetrics(progress: progress, speedLabel: '计算中', remainingLabel: '剩余 --');
  final speed = getFileSpeed(start: session.startTime!, end: DateTime.now().millisecondsSinceEpoch, bytes: current);
  return _TransferMetrics(progress: progress, speedLabel: '${speed.asReadableFileSize}/s', remainingLabel: getRemainingTime(bytesPerSeconds: speed, remainingBytes: total - current));
}
