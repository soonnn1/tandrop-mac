import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:common/api_route_builder.dart';
import 'package:common/constants.dart';
import 'package:common/isolate.dart';
import 'package:common/model/dto/file_dto.dart';
import 'package:common/model/dto/multicast_dto.dart';
import 'package:common/model/session_status.dart';
import 'package:common/util/logger.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:localsend_app/config/refena.dart';
import 'package:localsend_app/config/theme.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/pages/home_page.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/provider/animation_provider.dart';
import 'package:localsend_app/provider/app_arguments_provider.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/persistence_provider.dart';

// [FOSS_REMOVE_START]
import 'package:localsend_app/provider/purchase_provider.dart';

// [FOSS_REMOVE_END]
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/tv_provider.dart';
import 'package:localsend_app/provider/window_dimensions_provider.dart';
import 'package:localsend_app/util/file_size_helper.dart';
import 'package:localsend_app/util/i18n.dart';
import 'package:localsend_app/util/native/autostart_helper.dart';
import 'package:localsend_app/util/native/cache_helper.dart';
import 'package:localsend_app/util/native/content_uri_helper.dart';
import 'package:localsend_app/util/native/context_menu_helper.dart';
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/util/native/device_info_helper.dart';
import 'package:localsend_app/util/native/macos_channel.dart';
import 'package:localsend_app/util/native/platform_check.dart';
import 'package:localsend_app/util/native/tray_helper.dart';
import 'package:localsend_app/util/rhttp.dart';
import 'package:localsend_app/util/ui/dynamic_colors.dart';
import 'package:localsend_app/util/ui/snackbar.dart';
import 'package:logging/logging.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:rhttp/rhttp.dart';
import 'package:share_handler/share_handler.dart';
import 'package:window_manager/window_manager.dart';

final _logger = Logger('Init');

/// Will be called before the MaterialApp started
Future<RefenaContainer> preInit(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  initLogger(args.contains('-v') || args.contains('--verbose')
      ? Level.ALL
      : Level.INFO);
  MapperContainer.globals.use(const FileDtoMapper());

  await Rhttp.init();

  final dynamicColors = await getDynamicColors();

  final persistenceService = await PersistenceService.initialize(
    supportsDynamicColors: dynamicColors != null,
  );

  if (persistenceService.isFirstAppStart &&
      !persistenceService.isPortableMode()) {
    await enableContextMenu();
  }

  await initI18n();

  bool startHidden = false;
  if (checkPlatformIsDesktop()) {
    // Check if this app is already open and let it "show up".
    // If this is the case, then exit the current instance.

    final client = createRhttpClient(const Duration(milliseconds: 100),
        persistenceService.getSecurityContext());

    try {
      await client.post(
        ApiRoute.show.targetRaw(
          '127.0.0.1',
          persistenceService.getPort(),
          persistenceService.isHttps(),
          peerProtocolVersion,
        ),
        query: {
          'token': persistenceService.getShowToken(),
        },
        body: HttpBody.json({
          'args': args,
        }),
      );
      exit(0); // Another instance does exist because no error is thrown
    } catch (_) {}

    // initialize tray AFTER i18n has been initialized
    try {
      await initTray();
    } catch (e) {
      _logger.warning('Initializing tray failed: $e');
    }

    // initialize size and position
    await WindowManager.instance.ensureInitialized();
    await WindowDimensionsController(persistenceService)
        .initDimensionsConfiguration();
    if (args.contains(startHiddenFlag)) {
      // keep this app hidden
      startHidden = true;
    } else if (defaultTargetPlatform == TargetPlatform.macOS) {
      startHidden =
          await isLaunchedAsLoginItem() && await getLaunchAtLoginMinimized();
    }

    if (startHidden) {
      // Share Extension 以 --hidden 启动时，必须先完成隐藏再继续初始化，
      // 避免主窗口短暂闪现后才收起。
      await hideToTray();
    } else {
      await WindowManager.instance.show();
    }

    if (defaultTargetPlatform == TargetPlatform.macOS) {
      await setupStatusBar();
    }
  }

  setDefaultRouteTransition();

  final rawDeviceInfo = await getDeviceInfo();

  final container = RefenaContainer(
    observers: kDebugMode ? [CustomRefenaObserver()] : [],
    overrides: [
      persistenceProvider.overrideWithValue(persistenceService),
      deviceRawInfoProvider.overrideWithValue(rawDeviceInfo),
      appArgumentsProvider.overrideWithValue(args),
      tvProvider.overrideWithValue(await checkIfTv()),
      dynamicColorsProvider.overrideWithValue(dynamicColors),
      sleepProvider.overrideWithInitialState((ref) => startHidden),
    ],
    platformHint:
        RefenaScope.getPlatformHint(), // help Refena know the correct platform
  );

  // initialize multi-threading
  container.set(parentIsolateProvider.overrideWithNotifier((ref) {
    final settings = ref.read(settingsProvider);
    return IsolateController(
      initialState: ParentIsolateState.initial(
        SyncState(
          init: () async {
            await Rhttp.init();
          },
          rootIsolateToken: RootIsolateToken.instance!,
          httpClientFactory: RhttpWrapper.create,
          securityContext: persistenceService.getSecurityContext(),
          deviceInfo: ref.read(deviceInfoProvider),
          alias: settings.alias,
          port: settings.port,
          networkWhitelist: settings.networkWhitelist,
          networkBlacklist: settings.networkBlacklist,
          protocol: settings.https ? ProtocolType.https : ProtocolType.http,
          multicastGroup: settings.multicastGroup,
          discoveryTimeout: settings.discoveryTimeout,
          serverRunning: true,
          download: false,
        ),
      ),
    );
  }));

  await container.redux(parentIsolateProvider).dispatchAsync(IsolateSetupAction(
        uriContentStreamResolver: AndroidUriContentStreamResolver(),
      ));

  return container;
}

StreamSubscription? _sharedMediaSubscription;
bool _sendPanelTemporarilyUsesHttp = false;
String? _sendPanelActiveSessionId;

String _formatRemainingTime(int seconds) {
  if (seconds < 60) return '剩余 ${seconds}s';
  final minutes = seconds ~/ 60;
  final restSeconds = seconds % 60;
  return '剩余 $minutes分${restSeconds}s';
}

Future<void> _refreshSendPanelDevices(Ref ref) async {
  unawaited(ref.global.dispatchAsync(StartSmartScan(forceLegacy: true)));
  await Future<void>.delayed(const Duration(milliseconds: 900));
  await _pushSendPanelDevices(ref);
}

Future<void> _pushSendPanelDevices(Ref ref) async {
  final devices = ref.read(nearbyDevicesProvider).devices.values.map((device) {
    return {
      'ip': device.ip,
      'alias': device.alias,
      'model': device.deviceModel,
      'type': device.deviceType.name,
    };
  }).toList();

  await updateSendPanelDevices(devices: devices);
}

Future<void> _handleSendPanelAction(
  Ref ref,
  Map<String, dynamic> action,
) async {
  final type = action['type'] as String?;
  if (type == 'refresh') {
    await _refreshSendPanelDevices(ref);
    return;
  }

  if (type == 'close') {
    if (_sendPanelTemporarilyUsesHttp) {
      _sendPanelTemporarilyUsesHttp = false;
      await ref.notifier(serverProvider).restartServerFromSettings();
    }
    return;
  }

  if (type == 'cancel') {
    final sessionId = _sendPanelActiveSessionId;
    if (sessionId != null) {
      // 原生卡片只发出操作事件，真正的传输终止仍由 Dart 发送服务完成。
      ref.notifier(sendProvider).cancelSession(sessionId);
      _sendPanelActiveSessionId = null;
      await updateSendPanelStatus(status: 'failed', detail: '已终止发送');
    }
    return;
  }

  if (type == 'downloadQr') {
    final files = ref.read(selectedSendingFilesProvider);
    ServerState? server = ref.read(serverProvider);
    final localIps = ref.read(localIpProvider).localIps;
    if (files.isEmpty || server == null || localIps.isEmpty) {
      await updateSendPanelStatus(
        status: 'failed',
        detail: '无法生成二维码，请确认文件与网络可用',
      );
      return;
    }

    if (server.session != null) {
      await updateSendPanelStatus(
        status: 'failed',
        detail: '正在接收文件，暂时无法开启网页下载',
      );
      return;
    }
    if (server.https) {
      final settings = ref.read(settingsProvider);
      await ref.notifier(serverProvider).restartServer(
            alias: settings.alias,
            port: settings.port,
            https: false,
          );
      // 先保留 Provider 的可空返回值，避免 Dart 在已判空分支中错误地按非空类型推断。
      final restartedServer = ref.read(serverProvider);
      server = restartedServer;
      _sendPanelTemporarilyUsesHttp = true;
    }
    if (server == null) {
      await updateSendPanelStatus(status: 'failed', detail: '网页服务启动失败');
      return;
    }

    // 复用官方网页下载服务：手机只需浏览器，不需要安装 TanDrop。
    await ref.notifier(serverProvider).initializeWebSend(files);
    // 原网页分享默认需要 Flutter 页面手动确认；原生卡片没有该页面，
    // 因此为本次二维码生成 PIN 并自动批准持有二维码的下载请求。
    final pin = (math.Random.secure().nextInt(900000) + 100000).toString();
    ref.notifier(serverProvider).setWebSendPin(pin);
    ref.notifier(serverProvider).setWebSendAutoAccept(true);
    final url = 'http://${localIps.first}:${server.port}/?pin=$pin';
    await showSendPanelQr(url: url);
    return;
  }

  if (type != 'send') {
    return;
  }

  final ip = action['ip'] as String?;
  final target =
      ip == null ? null : ref.read(nearbyDevicesProvider).devices[ip];
  final files = ref.read(selectedSendingFilesProvider);
  if (target == null) {
    await updateSendPanelStatus(
      status: 'failed',
      detail: '设备已离线，请重新搜索',
    );
    return;
  }
  if (files.isEmpty) {
    await updateSendPanelStatus(
      status: 'failed',
      detail: '没有可发送的文件',
    );
    return;
  }

  await updateSendPanelStatus(
    status: 'sending',
    detail: '正在发送到 ${target.alias}',
  );

  final totalBytes = files.fold<int>(0, (sum, file) => sum + file.size);
  var lastSentBytes = 0;
  var lastUpdate = DateTime.now();

  try {
    final result = await ref
        .notifier(sendProvider)
        .startSession(
          target: target,
          files: files,
          background: true,
          onSessionCreated: (sessionId) {
            _sendPanelActiveSessionId = sessionId;
          },
          onProgress: (progress) {
            final sentBytes = (totalBytes * progress).round();
            final now = DateTime.now();
            final elapsedMilliseconds = now.difference(lastUpdate).inMilliseconds;
            // 上传底层会高频回调；限制原生 UI 刷新频率，同时计算瞬时速度。
            if (elapsedMilliseconds < 180 && progress < 1) return;
            final speed = elapsedMilliseconds <= 0
                ? 0
                : ((sentBytes - lastSentBytes) * 1000 / elapsedMilliseconds)
                    .round();
            final remainingSeconds = speed <= 0
                ? null
                : ((totalBytes - sentBytes) / speed)
                    .ceil()
                    .clamp(0, 999999)
                    .toInt();
            lastSentBytes = sentBytes;
            lastUpdate = now;
            // 原生卡片只接收事件，不创建第二个 Flutter 窗口。
            unawaited(updateSendPanelStatus(
              status: 'sending',
              detail: speed <= 0
                  ? '正在发送到 ${target.alias} · 正在计算速度'
                  : '${speed.asReadableFileSize}/s · '
                      '${_formatRemainingTime(remainingSeconds!)}',
              progress: progress,
            ));
          },
        );
    switch (result) {
      case SessionStatus.finished:
        await updateSendPanelStatus(
          status: 'completed',
          detail: '已发送到 ${target.alias}',
        );
      case SessionStatus.declined:
        await updateSendPanelStatus(
          status: 'failed',
          detail: '对方已拒绝接收',
        );
      case SessionStatus.recipientBusy:
        await updateSendPanelStatus(
          status: 'failed',
          detail: '对方正在处理其他传输',
        );
      case SessionStatus.tooManyAttempts:
        await updateSendPanelStatus(
          status: 'failed',
          detail: '请求次数过多，请稍后重试',
        );
      case SessionStatus.canceledBySender:
        await updateSendPanelStatus(status: 'failed', detail: '已取消发送');
      default:
        await updateSendPanelStatus(status: 'failed', detail: '传输失败，请重试');
    }
  } catch (e) {
    await updateSendPanelStatus(
      status: 'failed',
      detail: e.toString(),
    );
  } finally {
    _sendPanelActiveSessionId = null;
  }
}

/// Will be called when home page has been initialized
Future<void> postInit(BuildContext context, Ref ref, bool appStart) async {
  await updateSystemOverlayStyle(context);

  if (checkPlatform([TargetPlatform.android])) {
    try {
      await FlutterDisplayMode.setHighRefreshRate();
    } catch (e) {
      _logger.warning('Setting high refresh rate failed', e);
    }
  }

  try {
    await ref.notifier(serverProvider).startServerFromSettings();
  } catch (e) {
    if (context.mounted) {
      context.showSnackBar(e.toString());
    }
  }

  try {
    unawaited(
      ref.redux(nearbyDevicesProvider).dispatchAsync(StartMulticastListener()),
    );
  } catch (e) {
    _logger.warning('Starting multicast listener failed', e);
  }

  if (appStart) {
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      // handle dropped files
      pendingFilesStream.listen((files) async {
        // 系统分享是一次新的发送任务，不能把主窗口中残留的待发送文件一起传出。
        ref
            .redux(selectedSendingFilesProvider)
            .dispatch(ResetSelectionForSystemShareAction());
        await ref.global.dispatchAsync(_HandleAppStartArgumentsAction(
          args: files,
        ));
        await _refreshSendPanelDevices(ref);
      });

      // handle dropped strings
      pendingStringsStream.listen((pendingStrings) async {
        for (final string in pendingStrings) {
          ref
              .redux(selectedSendingFilesProvider)
              .dispatch(AddMessageAction(message: string));
        }
        ref
            .redux(homePageControllerProvider)
            .dispatch(ChangeTabAction(HomeTab.send));
        await _refreshSendPanelDevices(ref);
      });

      sendPanelActionStream.listen((action) async {
        await _handleSendPanelAction(ref, action);
      });

      await setupMethodCallHandler();
    } else {
      final args = ref.read(appArgumentsProvider);
      await ref.global.dispatchAsync(_HandleAppStartArgumentsAction(
        args: args,
      ));
    }
  }

  bool hasInitialShare = false;

  if (checkPlatformCanReceiveShareIntent()) {
    final shareHandler = ShareHandlerPlatform.instance;

    if (appStart) {
      final initialSharedPayload = await shareHandler.getInitialSharedMedia();
      if (initialSharedPayload != null) {
        hasInitialShare = true;
        // ignore: unawaited_futures
        ref.global.dispatchAsync(_HandleShareIntentAction(
          payload: initialSharedPayload,
        ));
      }
    }

    _sharedMediaSubscription?.cancel(); // ignore: unawaited_futures
    _sharedMediaSubscription =
        shareHandler.sharedMediaStream.listen((SharedMedia payload) {
      ref.global.dispatchAsync(_HandleShareIntentAction(
        payload: payload,
      ));
    });
  }

  if (appStart &&
      !hasInitialShare &&
      (checkPlatformWithGallery() || checkPlatformCanReceiveShareIntent())) {
    // Clear cache on every app start.
    // If we received a share intent, then don't clear it, otherwise the shared file will be lost.
    ref.global.dispatchAsync(ClearCacheAction()); // ignore: unawaited_futures
  }

  // [FOSS_REMOVE_START]
  if (checkPlatformSupportPayment()) {
    // ignore: unawaited_futures
    ref.redux(purchaseProvider).dispatchAsync(InitPurchaseStream());
  }
  // [FOSS_REMOVE_END]
}

class _HandleShareIntentAction extends AsyncGlobalAction {
  final SharedMedia payload;

  _HandleShareIntentAction({
    required this.payload,
  });

  @override
  Future<void> reduce() async {
    final message = payload.content;
    if (message != null && message.trim().isNotEmpty) {
      ref
          .redux(selectedSendingFilesProvider)
          .dispatch(AddMessageAction(message: message));
    }
    await ref.redux(selectedSendingFilesProvider).dispatchAsync(AddFilesAction(
          files: payload.attachments
                  ?.where((a) => a != null)
                  .cast<SharedAttachment>() ??
              <SharedAttachment>[],
          converter: CrossFileConverters.convertSharedAttachment,
        ));

    ref
        .redux(homePageControllerProvider)
        .dispatch(ChangeTabAction(HomeTab.send));
  }
}

class _HandleAppStartArgumentsAction extends AsyncGlobalAction {
  final List<String> args;

  _HandleAppStartArgumentsAction({
    required this.args,
  });

  @override
  Future<void> reduce() async {
    final filesAdded = await ref
        .redux(selectedSendingFilesProvider)
        .dispatchAsyncTakeResult(LoadSelectionFromArgsAction(args));
    if (filesAdded) {
      ref
          .redux(homePageControllerProvider)
          .dispatch(ChangeTabAction(HomeTab.send));
    }
  }
}
