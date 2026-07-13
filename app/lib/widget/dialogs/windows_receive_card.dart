import 'dart:async';
import 'dart:convert';

import 'package:common/model/dto/file_dto.dart';
import 'package:common/model/file_type.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:localsend_app/util/file_size_helper.dart';
import 'package:localsend_app/util/native/open_folder.dart';
import 'package:localsend_app/widget/dialogs/open_file_dialog.dart';
import 'package:routerino/routerino.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

const _receiveCardWindowType = 'windowsReceiveCard';
const _receiveCardChannel = WindowMethodChannel(
  'tandrop.windows.receive_card',
  mode: ChannelMode.unidirectional,
);
const _receiveCardNativeChannel = MethodChannel(
  'tandrop/windows_send_card_native',
);

bool isWindowsReceiveCardWindowArguments(String arguments) {
  try {
    final json = jsonDecode(arguments);
    return json is Map && json['type'] == _receiveCardWindowType;
  } catch (_) {
    return false;
  }
}

Future<void> runWindowsReceiveCardWindow(String arguments) async {
  final controller = await WindowController.fromCurrentEngine();
  runApp(_WindowsReceiveCardWindowApp(controller: controller));
}

class WindowsReceiveRequest {
  final String sessionId;
  final String senderAlias;
  final List<FileDto> files;
  final String destination;
  final VoidCallback? onCancel;

  const WindowsReceiveRequest({
    required this.sessionId,
    required this.senderAlias,
    required this.files,
    required this.destination,
    this.onCancel,
  });

  int get totalSize => files.fold<int>(0, (sum, file) => sum + file.size);

  FileDto get firstFile => files.first;
}

class WindowsReceiveProgress {
  final String sessionId;
  final double progress;
  final String currentFile;

  const WindowsReceiveProgress({
    required this.sessionId,
    required this.progress,
    required this.currentFile,
  });
}

class WindowsReceiveFinished {
  final String sessionId;
  final bool hasError;
  final String? openPath;
  final String folderPath;

  const WindowsReceiveFinished({
    required this.sessionId,
    required this.hasError,
    required this.openPath,
    required this.folderPath,
  });
}

class WindowsReceiveCanceled {
  final String sessionId;

  const WindowsReceiveCanceled({required this.sessionId});
}

sealed class _WindowsReceiveEvent {
  const _WindowsReceiveEvent();
}

class _RequestEvent extends _WindowsReceiveEvent {
  final WindowsReceiveRequest request;
  final Completer<bool> completer;
  final bool alreadyAccepted;

  const _RequestEvent(this.request, this.completer, this.alreadyAccepted);
}

class _ProgressEvent extends _WindowsReceiveEvent {
  final WindowsReceiveProgress progress;

  const _ProgressEvent(this.progress);
}

class _FinishedEvent extends _WindowsReceiveEvent {
  final WindowsReceiveFinished finished;

  const _FinishedEvent(this.finished);
}

class _CanceledEvent extends _WindowsReceiveEvent {
  final WindowsReceiveCanceled canceled;

  const _CanceledEvent(this.canceled);
}

class WindowsReceiveCardController {
  WindowsReceiveCardController._();

  static final _events = StreamController<_WindowsReceiveEvent>.broadcast();

  /// WindowWatcher 据此忽略卡片窗口的临时尺寸，避免覆盖主窗口布局记录。
  static bool isWindowCardMode = false;

  static Future<bool> request(WindowsReceiveRequest request) {
    final completer = Completer<bool>();
    _events.add(_RequestEvent(request, completer, false));
    return completer.future;
  }

  static void showReceiving(WindowsReceiveRequest request) {
    final completer = Completer<bool>()..complete(true);
    _events.add(_RequestEvent(request, completer, true));
  }

  static void updateProgress(WindowsReceiveProgress progress) {
    _events.add(_ProgressEvent(progress));
  }

  static void finish(WindowsReceiveFinished finished) {
    _events.add(_FinishedEvent(finished));
  }

  static void cancel(WindowsReceiveCanceled canceled) {
    _events.add(_CanceledEvent(canceled));
  }
}

class _WindowsReceiveCardWindowManager {
  _WindowsReceiveCardWindowManager._();

  static WindowController? _controller;

  static Future<void> show() async {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    _controller ??= await WindowController.create(
      const WindowConfiguration(
        arguments: '{"type":"windowsReceiveCard"}',
        hiddenAtLaunch: true,
      ),
    );
  }

  static void markClosed() {
    _controller = null;
  }
}

class WindowsReceiveCardHost extends StatefulWidget {
  final Widget child;

  const WindowsReceiveCardHost({required this.child, super.key});

  @override
  State<WindowsReceiveCardHost> createState() => _WindowsReceiveCardHostState();
}

class _WindowsReceiveCardHostState extends State<WindowsReceiveCardHost> {
  StreamSubscription<_WindowsReceiveEvent>? _subscription;
  Timer? _hideTimer;
  WindowsReceiveRequest? _request;
  Completer<bool>? _decision;
  _ReceiveCardStage _stage = _ReceiveCardStage.waiting;
  double _progress = 0;
  String? _currentFile;
  bool _hasError = false;
  String? _openPath;

  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform != TargetPlatform.windows) {
      return;
    }
    _subscription =
        WindowsReceiveCardController._events.stream.listen(_handleEvent);
    unawaited(_receiveCardChannel.setMethodCallHandler(_handleWindowCall));
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    unawaited(_subscription?.cancel());
    if (_decision != null && !_decision!.isCompleted) {
      _decision!.complete(false);
    }
    unawaited(_receiveCardChannel.setMethodCallHandler(null));
    super.dispose();
  }

  Future<dynamic> _handleWindowCall(MethodCall call) async {
    switch (call.method) {
      case 'snapshot':
        return _snapshot();
      case 'accept':
        _accept();
        return _snapshot();
      case 'decline':
        _decline();
        return _snapshot();
      case 'open':
        _openFile();
        return null;
      case 'folder':
        _openFolder();
        return null;
      case 'closed':
        _WindowsReceiveCardWindowManager.markClosed();
        return null;
      default:
        return null;
    }
  }

  void _handleEvent(_WindowsReceiveEvent event) {
    switch (event) {
      case _RequestEvent():
        _showRequest(
          event.request,
          event.completer,
          alreadyAccepted: event.alreadyAccepted,
        );
        break;
      case _ProgressEvent():
        if (_request?.sessionId != event.progress.sessionId) return;
        setState(() {
          _stage = _ReceiveCardStage.receiving;
          _progress = event.progress.progress.clamp(0, 1);
          _currentFile = event.progress.currentFile;
        });
        break;
      case _FinishedEvent():
        if (_request?.sessionId != event.finished.sessionId) return;
        setState(() {
          _stage = event.finished.hasError
              ? _ReceiveCardStage.failed
              : _ReceiveCardStage.finished;
          _progress = 1;
          _hasError = event.finished.hasError;
          _openPath = event.finished.openPath;
        });
        _scheduleHide(const Duration(seconds: 4), event.finished.sessionId);
        break;
      case _CanceledEvent():
        if (_request?.sessionId != event.canceled.sessionId) return;
        if (_decision != null && !_decision!.isCompleted) {
          _decision!.complete(false);
        }
        setState(() {
          _stage = _ReceiveCardStage.failed;
          _hasError = true;
        });
        _scheduleHide(const Duration(seconds: 2), event.canceled.sessionId);
        break;
    }
  }

  void _showRequest(
    WindowsReceiveRequest request,
    Completer<bool> decision, {
    required bool alreadyAccepted,
  }) {
    _hideTimer?.cancel();
    if (_decision != null && !_decision!.isCompleted) {
      _decision!.complete(false);
    }
    setState(() {
      _request = request;
      _decision = decision;
      _stage = alreadyAccepted
          ? _ReceiveCardStage.receiving
          : _ReceiveCardStage.waiting;
      _progress = 0;
      _currentFile = request.firstFile.fileName;
      _hasError = false;
      _openPath = null;
    });
    unawaited(_WindowsReceiveCardWindowManager.show());
  }

  void _accept() {
    if (_decision != null && !_decision!.isCompleted) {
      _decision!.complete(true);
    }
    setState(() {
      _stage = _ReceiveCardStage.receiving;
    });
  }

  void _decline() {
    if (_stage == _ReceiveCardStage.waiting &&
        _decision != null &&
        !_decision!.isCompleted) {
      _decision!.complete(false);
    } else {
      // 接收阶段的“取消”必须真正终止会话，不能只隐藏界面。
      _request?.onCancel?.call();
    }
    _hide();
  }

  void _openFile() {
    final path = _openPath;
    if (path == null || path.isEmpty) return;
    unawaited(
      OpenFileDialog.open(
        Routerino.context,
        filePath: path,
        fileType: _request?.firstFile.fileType ?? FileType.other,
        openGallery: false,
      ),
    );
  }

  void _openFolder() {
    final destination = _request?.destination;
    if (destination == null || destination.isEmpty) return;
    unawaited(openFolder(folderPath: destination));
  }

  void _hide() {
    if (!mounted) return;
    _hideTimer?.cancel();
    setState(() {
      _request = null;
      _decision = null;
    });
  }

  void _scheduleHide(Duration delay, String sessionId) {
    _hideTimer?.cancel();
    _hideTimer = Timer(delay, () {
      // 旧会话的延时任务不能误关后来出现的新卡片。
      if (_request?.sessionId == sessionId) {
        _hide();
      }
    });
  }

  Map<String, dynamic> _snapshot() {
    final request = _request;
    return {
      'visible': request != null,
      if (request != null) ...{
        'sessionId': request.sessionId,
        'senderAlias': request.senderAlias,
        'destination': request.destination,
        'files': request.files
            .map(
              (file) => {
                'id': file.id,
                'fileName': file.fileName,
                'size': file.size,
                'fileType': file.fileType.name,
              },
            )
            .toList(),
        'stage': _stage.name,
        'progress': _progress,
        'currentFile': _currentFile,
        'hasError': _hasError,
        'openPath': _openPath,
      },
    };
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _WindowsReceiveCardWindowApp extends StatefulWidget {
  final WindowController controller;

  const _WindowsReceiveCardWindowApp({required this.controller});

  @override
  State<_WindowsReceiveCardWindowApp> createState() =>
      _WindowsReceiveCardWindowAppState();
}

class _WindowsReceiveCardWindowAppState
    extends State<_WindowsReceiveCardWindowApp> with WindowListener {
  static const _windowSize = Size(680, 230);

  Timer? _pollTimer;
  WindowsReceiveRequest? _request;
  _ReceiveCardStage _stage = _ReceiveCardStage.waiting;
  double _progress = 0;
  String? _currentFile;
  bool _hasError = false;
  bool _closing = false;
  Offset? _visiblePosition;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(_initializeWindow());
  }

  Future<void> _initializeWindow() async {
    // 先获取完整接收请求再显示窗口，避免默认空白背景闪现。
    while (mounted && _request == null) {
      await _loadSnapshot();
      if (_request == null) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }
    if (!mounted) return;
    await _configureWindow();
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 180),
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
    final display = await ScreenRetriever.instance.getPrimaryDisplay();
    final visibleOrigin = display.visiblePosition ?? Offset.zero;
    final visibleSize = display.visibleSize ?? display.size;
    final target = Offset(
      visibleOrigin.dx + visibleSize.width - _windowSize.width - 22,
      visibleOrigin.dy + 18,
    );
    final hidden = Offset(target.dx, target.dy - _windowSize.height - 24);
    _visiblePosition = target;

    const options = WindowOptions(
      size: _windowSize,
      backgroundColor: Color(0xFF2A2117),
      skipTaskbar: true,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.setPreventClose(true);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.setAsFrameless();
      await windowManager.setResizable(false);
      await windowManager.setHasShadow(false);
      await windowManager.setPosition(hidden);
      await _receiveCardNativeChannel.invokeMethod<void>(
          'setRoundedRegion', 30);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await windowManager.show();
      await _animateWindow(hidden, target, const Duration(milliseconds: 240));
    });
  }

  Future<void> _loadSnapshot() async {
    if (_closing) return;
    try {
      final result = await _receiveCardChannel
          .invokeMethod<Map<dynamic, dynamic>>('snapshot');
      if (!mounted || result == null) return;
      final data = result.cast<String, dynamic>();
      if (data['visible'] != true) {
        await _closeAnimated();
        return;
      }
      final files = (data['files'] as List).cast<Map>().map((raw) {
        final file = raw.cast<String, dynamic>();
        final typeName = file['fileType'] as String?;
        final fileType = FileType.values.firstWhere(
          (type) => type.name == typeName,
          orElse: () => FileType.other,
        );
        return FileDto(
          id: file['id'] as String,
          fileName: file['fileName'] as String,
          size: file['size'] as int,
          fileType: fileType,
          hash: null,
          preview: null,
          legacy: false,
          metadata: null,
        );
      }).toList();
      final stageName = data['stage'] as String?;
      setState(() {
        _request = WindowsReceiveRequest(
          sessionId: data['sessionId'] as String,
          senderAlias: data['senderAlias'] as String,
          files: files,
          destination: data['destination'] as String,
        );
        _stage = _ReceiveCardStage.values.firstWhere(
          (stage) => stage.name == stageName,
          orElse: () => _ReceiveCardStage.waiting,
        );
        _progress = (data['progress'] as num?)?.toDouble() ?? 0;
        _currentFile = data['currentFile'] as String?;
        _hasError = data['hasError'] as bool? ?? false;
      });
    } catch (_) {
      // 主引擎初始化通信期间短暂失败，下一次轮询会重试。
    }
  }

  Future<void> _invokeAction(String method) async {
    await _receiveCardChannel.invokeMethod(method);
    await _loadSnapshot();
  }

  Future<void> _closeAnimated() async {
    if (_closing) return;
    _closing = true;
    _pollTimer?.cancel();
    final start = await windowManager.getPosition();
    final target = Offset(
      start.dx,
      (_visiblePosition?.dy ?? start.dy) - _windowSize.height - 24,
    );
    await _animateWindow(start, target, const Duration(milliseconds: 190));
    try {
      await _receiveCardChannel.invokeMethod('closed');
    } finally {
      await windowManager.setPreventClose(false);
      await windowManager.close();
    }
  }

  Future<void> _animateWindow(
    Offset begin,
    Offset end,
    Duration duration,
  ) async {
    const frames = 15;
    final frameDelay = Duration(
      microseconds: duration.inMicroseconds ~/ frames,
    );
    for (var frame = 1; frame <= frames; frame++) {
      final t = Curves.easeOutCubic.transform(frame / frames);
      await windowManager.setPosition(Offset.lerp(begin, end, t)!);
      await Future<void>.delayed(frameDelay);
    }
  }

  @override
  Future<void> onWindowClose() async {
    if (!_closing) {
      await _invokeAction('decline');
      await _closeAnimated();
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = _request;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Material(
        color: const Color(0xFF2A2117),
        child: request == null
            ? const SizedBox.expand()
            : Directionality(
                textDirection: TextDirection.ltr,
                child: _WindowsReceiveCard(
                  request: request,
                  stage: _stage,
                  progress: _progress,
                  currentFile: _currentFile,
                  hasError: _hasError,
                  onAccept: () => unawaited(_invokeAction('accept')),
                  onDecline: () => unawaited(_invokeAction('decline')),
                  onOpen: () => unawaited(_invokeAction('open')),
                  onOpenFolder: () => unawaited(_invokeAction('folder')),
                ),
              ),
      ),
    );
  }
}

enum _ReceiveCardStage {
  waiting,
  receiving,
  finished,
  failed,
}

class _WindowsReceiveCard extends StatelessWidget {
  final WindowsReceiveRequest request;
  final _ReceiveCardStage stage;
  final double progress;
  final String? currentFile;
  final bool hasError;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onOpen;
  final VoidCallback onOpenFolder;

  const _WindowsReceiveCard({
    required this.request,
    required this.stage,
    required this.progress,
    required this.currentFile,
    required this.hasError,
    required this.onAccept,
    required this.onDecline,
    required this.onOpen,
    required this.onOpenFolder,
  });

  @override
  Widget build(BuildContext context) {
    final firstFile = request.firstFile;
    final progressColor = hasError ? Colors.redAccent : const Color(0xFF0A84FF);

    return Container(
      width: 680,
      constraints: const BoxConstraints(minHeight: 202, maxHeight: 230),
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: Colors.white.withOpacity(0.16)),
        color: const Color(0xE62A2117),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.28),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _AvatarBadge(stage: stage),
              const SizedBox(width: 18),
              Expanded(
                  child: _TextBlock(
                      request: request,
                      currentFile: currentFile,
                      stage: stage)),
              const SizedBox(width: 16),
              _PreviewBox(file: firstFile),
            ],
          ),
          const SizedBox(height: 18),
          Divider(height: 1, color: Colors.white.withOpacity(0.16)),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    minHeight: 14,
                    value: stage == _ReceiveCardStage.waiting ? 0 : progress,
                    color: progressColor,
                    backgroundColor: Colors.white.withOpacity(0.12),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              _TrailingAction(
                stage: stage,
                onAccept: onAccept,
                onDecline: onDecline,
                onOpen: onOpen,
                onOpenFolder: onOpenFolder,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TextBlock extends StatelessWidget {
  final WindowsReceiveRequest request;
  final String? currentFile;
  final _ReceiveCardStage stage;

  const _TextBlock({
    required this.request,
    required this.currentFile,
    required this.stage,
  });

  @override
  Widget build(BuildContext context) {
    final fileCount = request.files.length;
    final typeText = _fileTypeText(request.firstFile.fileType);
    final title = switch (stage) {
      _ReceiveCardStage.waiting => '请求投送',
      _ReceiveCardStage.receiving => '正在接收 $fileCount 个$typeText',
      _ReceiveCardStage.finished => '接收完成',
      _ReceiveCardStage.failed => '接收失败',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          request.senderAlias,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.w800,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white.withOpacity(0.92),
            fontSize: 21,
            fontWeight: FontWeight.w700,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${currentFile ?? request.firstFile.fileName} · ${request.totalSize.asReadableFileSize}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white.withOpacity(0.66),
            fontSize: 17,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _AvatarBadge extends StatelessWidget {
  final _ReceiveCardStage stage;

  const _AvatarBadge({required this.stage});

  @override
  Widget build(BuildContext context) {
    final badgeColor = switch (stage) {
      _ReceiveCardStage.finished => Colors.greenAccent,
      _ReceiveCardStage.failed => Colors.redAccent,
      _ => const Color(0xFF0A84FF),
    };
    final badgeIcon = switch (stage) {
      _ReceiveCardStage.finished => Icons.check,
      _ReceiveCardStage.failed => Icons.close,
      _ => Icons.arrow_downward_rounded,
    };

    return SizedBox(
      width: 74,
      height: 74,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          const CircleAvatar(
            radius: 37,
            backgroundColor: Color(0xFF2F5F99),
            child: Icon(Icons.person, color: Color(0xFFDDE6F3), size: 52),
          ),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: badgeColor,
                border:
                    Border.all(color: Colors.white.withOpacity(0.65), width: 2),
              ),
              child: Icon(badgeIcon, color: Colors.white, size: 16),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewBox extends StatelessWidget {
  final FileDto file;

  const _PreviewBox({required this.file});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Icon(
        _fileIcon(file.fileType),
        color: Colors.white.withOpacity(0.88),
        size: 42,
      ),
    );
  }
}

class _TrailingAction extends StatelessWidget {
  final _ReceiveCardStage stage;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final VoidCallback onOpen;
  final VoidCallback onOpenFolder;

  const _TrailingAction({
    required this.stage,
    required this.onAccept,
    required this.onDecline,
    required this.onOpen,
    required this.onOpenFolder,
  });

  @override
  Widget build(BuildContext context) {
    return switch (stage) {
      _ReceiveCardStage.waiting => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PillButton(label: '拒绝', onPressed: onDecline),
            const SizedBox(width: 10),
            _PillButton(label: '接收', primary: true, onPressed: onAccept),
          ],
        ),
      _ReceiveCardStage.finished => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PillButton(label: '打开', onPressed: onOpen),
            const SizedBox(width: 10),
            _PillButton(label: '文件夹', onPressed: onOpenFolder),
          ],
        ),
      _ReceiveCardStage.failed => IconButton.filledTonal(
          onPressed: onDecline,
          icon: const Icon(Icons.close),
          color: Colors.white,
          style: IconButton.styleFrom(
              backgroundColor: Colors.white.withOpacity(0.14)),
        ),
      _ => _PillButton(label: '取消', onPressed: onDecline),
    };
  }
}

class _PillButton extends StatelessWidget {
  final String label;
  final bool primary;
  final VoidCallback onPressed;

  const _PillButton({
    required this.label,
    required this.onPressed,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor:
            primary ? const Color(0xFF0A84FF) : Colors.white.withOpacity(0.14),
        minimumSize: const Size(82, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
      ),
      child: Text(label),
    );
  }
}

String _fileTypeText(FileType type) {
  return switch (type) {
    FileType.image => '图片',
    FileType.video => '视频',
    FileType.pdf => 'PDF',
    FileType.text => '文本',
    FileType.apk => 'APK',
    FileType.other => '项目',
  };
}

IconData _fileIcon(FileType type) {
  return switch (type) {
    FileType.image => Icons.image_rounded,
    FileType.video => Icons.movie_rounded,
    FileType.pdf => Icons.picture_as_pdf_rounded,
    FileType.text => Icons.description_rounded,
    FileType.apk => Icons.android_rounded,
    FileType.other => Icons.insert_drive_file_rounded,
  };
}
