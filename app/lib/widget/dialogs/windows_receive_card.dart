import 'dart:async';
import 'package:common/model/dto/file_dto.dart';
import 'package:common/model/file_type.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/util/file_size_helper.dart';
import 'package:localsend_app/util/native/open_folder.dart';
import 'package:localsend_app/widget/dialogs/open_file_dialog.dart';
import 'package:routerino/routerino.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

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
  _WindowSnapshot? _windowSnapshot;

  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform != TargetPlatform.windows) {
      return;
    }
    _subscription =
        WindowsReceiveCardController._events.stream.listen(_handleEvent);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    unawaited(_subscription?.cancel());
    if (_decision != null && !_decision!.isCompleted) {
      _decision!.complete(false);
    }
    super.dispose();
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
    unawaited(_enterCardWindow());
  }

  Widget _buildCard(BuildContext context) {
    final request = _request;
    if (request == null) return const SizedBox.shrink();

    return Positioned(
      top: 18,
      right: 22,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Material(
          color: Colors.transparent,
          child: _WindowsReceiveCard(
            request: request,
            stage: _stage,
            progress: _progress,
            currentFile: _currentFile,
            hasError: _hasError,
            onAccept: _accept,
            onDecline: _decline,
            onOpen: _openFile,
            onOpenFolder: _openFolder,
          ),
        ),
      ),
    );
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
    unawaited(_restoreMainWindow());
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

  Future<void> _enterCardWindow() async {
    if (_windowSnapshot == null) {
      final snapshot = _WindowSnapshot(
        position: await windowManager.getPosition(),
        size: await windowManager.getSize(),
        visible: await windowManager.isVisible(),
        minimized: await windowManager.isMinimized(),
        maximized: await windowManager.isMaximized(),
        resizable: await windowManager.isResizable(),
        alwaysOnTop: await windowManager.isAlwaysOnTop(),
        skipTaskbar: await windowManager.isSkipTaskbar(),
      );
      if (!mounted || _request == null) return;
      setState(() => _windowSnapshot ??= snapshot);
    }

    WindowsReceiveCardController.isWindowCardMode = true;
    const cardWindowSize = Size(724, 266);
    final display = await ScreenRetriever.instance.getPrimaryDisplay();
    final visiblePosition = display.visiblePosition ?? Offset.zero;
    final visibleSize = display.visibleSize ?? display.size;
    final position = Offset(
      visiblePosition.dx + visibleSize.width - cardWindowSize.width - 22,
      visiblePosition.dy + 18,
    );

    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    }
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.setMinimumSize(const Size(400, 200));
    await windowManager.setResizable(false);
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setSkipTaskbar(true);
    await windowManager.setSize(cardWindowSize);
    await windowManager.setPosition(position);
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _restoreMainWindow() async {
    final snapshot = _windowSnapshot;
    if (snapshot == null) return;
    _windowSnapshot = null;

    await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    await windowManager.setMinimumSize(const Size(400, 500));
    await windowManager.setResizable(snapshot.resizable);
    await windowManager.setSize(snapshot.size);
    await windowManager.setPosition(snapshot.position);
    if (snapshot.maximized) {
      await windowManager.maximize();
    }
    await windowManager.setAlwaysOnTop(snapshot.alwaysOnTop);
    await windowManager.setSkipTaskbar(snapshot.skipTaskbar);
    if (!snapshot.visible) {
      await windowManager.hide();
    } else if (snapshot.minimized) {
      await windowManager.minimize();
    } else {
      await windowManager.show();
    }
    WindowsReceiveCardController.isWindowCardMode = false;
  }

  @override
  Widget build(BuildContext context) {
    final mainWindowSize = _windowSnapshot?.size;
    return Stack(
      children: [
        Offstage(
          offstage: _request != null,
          child: mainWindowSize == null
              ? widget.child
              : OverflowBox(
                  alignment: Alignment.topLeft,
                  minWidth: mainWindowSize.width,
                  maxWidth: mainWindowSize.width,
                  minHeight: mainWindowSize.height,
                  maxHeight: mainWindowSize.height,
                  child: widget.child,
                ),
        ),
        if (_request != null)
          const Positioned.fill(child: ColoredBox(color: Color(0xFF151413))),
        if (_request != null) _buildCard(context),
      ],
    );
  }
}

class _WindowSnapshot {
  final Offset position;
  final Size size;
  final bool visible;
  final bool minimized;
  final bool maximized;
  final bool resizable;
  final bool alwaysOnTop;
  final bool skipTaskbar;

  const _WindowSnapshot({
    required this.position,
    required this.size,
    required this.visible,
    required this.minimized,
    required this.maximized,
    required this.resizable,
    required this.alwaysOnTop,
    required this.skipTaskbar,
  });
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

    return TweenAnimationBuilder<Offset>(
      tween: Tween(begin: const Offset(28, 0), end: Offset.zero),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (context, offset, child) {
        return Transform.translate(
          offset: offset,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 160),
            opacity: 1,
            child: child,
          ),
        );
      },
      child: Container(
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
