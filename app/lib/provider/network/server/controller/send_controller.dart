import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:common/api_route_builder.dart';
import 'package:common/constants.dart';
import 'package:common/model/dto/file_dto.dart';
import 'package:common/model/dto/info_dto.dart';
import 'package:common/model/dto/receive_request_response_dto.dart';
import 'package:common/model/file_type.dart';
import 'package:common/util/stream.dart';
import 'package:localsend_app/gen/assets.gen.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/state/send/web/web_send_file.dart';
import 'package:localsend_app/model/state/send/web/web_send_session.dart';
import 'package:localsend_app/model/state/send/web/web_send_state.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/network/server/controller/common.dart';
import 'package:localsend_app/provider/network/server/server_utils.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/simple_server.dart';
import 'package:uri_content/uri_content.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Handles all requests for sending files.
class SendController {
  final ServerUtils server;
  String? _webUploadToken;

  SendController(this.server);

  /// Installs all routes for receiving files.
  void installRoutes({
    required SimpleServerRouteBuilder router,
    required String alias,
    required String fingerprint,
  }) {
    // 浏览器上传入口独立于网页下载状态；随机令牌避免局域网内被随意打开。
    router.get('/upload', (HttpRequest request) async {
      if (request.uri.queryParameters['token'] != _webUploadToken) {
        return await request.respondJson(403, message: 'Invalid upload link.');
      }
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write(_webUploadHtml);
      await request.response.close();
    });

    router.get('/', (HttpRequest request) async {
      final state = server.getState();
      if (state.webSendState == null) {
        // There is no web send state
        return await request.respondAsset(403, Assets.web.error403);
      }

      return await request.respondAsset(200, Assets.web.index);
    });

    router.get('/main.js', (HttpRequest request) async {
      final state = server.getState();
      if (state.webSendState == null) {
        // There is no web send state
        return await request.respondAsset(403, Assets.web.error403);
      }

      return await request.respondAsset(200, Assets.web.main, 'text/javascript; charset=utf-8');
    });

    router.get('/i18n.json', (HttpRequest request) async {
      final state = server.getState();
      if (state.webSendState == null) {
        // There is no web send state
        return await request.respondJson(403, message: 'Web send not initialized.');
      }

      return await request.respondJson(200, body: {
        'waiting': t.web.waiting,
        'enterPin': t.web.enterPin,
        'invalidPin': t.web.invalidPin,
        'tooManyAttempts': t.web.tooManyAttempts,
        'rejected': t.web.rejected,
        'files': t.web.files,
        'fileName': t.web.fileName,
        'size': t.web.size,
      });
    });

    router.post(ApiRoute.prepareDownload.v2, (HttpRequest request) async {
      final state = server.getState();
      if (state.webSendState == null) {
        // There is no web send state
        return request.respondJson(403, message: 'Web send not initialized.');
      }

      final requestSessionId = request.uri.queryParameters['sessionId'];
      if (requestSessionId != null) {
        // Check if the user already has permission
        final session = server.getState().webSendState?.sessions[requestSessionId];
        if (session != null && session.responseHandler == null && session.ip == request.ip) {
          final deviceInfo = server.ref.read(deviceInfoProvider);
          return await request.respondJson(200,
              body: ReceiveRequestResponseDto(
                info: InfoDto(
                  alias: alias,
                  version: protocolVersion,
                  deviceModel: deviceInfo.deviceModel,
                  deviceType: deviceInfo.deviceType,
                  fingerprint: fingerprint,
                  download: true,
                ),
                sessionId: session.sessionId,
                files: {
                  for (final entry in state.webSendState!.files.entries) entry.key: entry.value.file,
                },
              ).toJson());
        }
      }

      final pinCorrect = await checkPin(
        server: server,
        pin: state.webSendState!.pin,
        pinAttempts: state.webSendState!.pinAttempts,
        request: request,
      );
      if (!pinCorrect) {
        return;
      }

      final streamController = StreamController<bool>();
      final sessionId = request.ip;
      server.setState(
        (oldState) => oldState!.copyWith(
          webSendState: oldState.webSendState!.copyWith(
            sessions: {
              ...oldState.webSendState!.sessions,
              sessionId: WebSendSession(
                sessionId: sessionId,
                responseHandler: streamController,
                ip: request.ip,
                deviceInfo: request.deviceInfo,
              ),
            },
          ),
        ),
      );

      final accepted = state.webSendState?.autoAccept == true || await streamController.stream.first;
      if (!accepted) {
        // user rejected the file transfer
        server.setState(
          (oldState) => oldState!.copyWith(
            webSendState: oldState.webSendState!.copyWith(
              sessions: {
                for (final entry in oldState.webSendState!.sessions.entries)
                  if (entry.key != sessionId) entry.key: entry.value, // remove session
              },
            ),
          ),
        );
        return await request.respondJson(403, message: 'File transfer rejected.');
      }

      server.setState(
        (oldState) => oldState!.copyWith(
          webSendState: oldState.webSendState!.updateSession(
            sessionId: sessionId,
            update: (oldSession) {
              return oldSession.copyWith(
                responseHandler: null, // this indicates that the session is active
              );
            },
          ),
        ),
      );
      final deviceInfo = server.ref.read(deviceInfoProvider);
      return await request.respondJson(200,
          body: ReceiveRequestResponseDto(
            info: InfoDto(
              alias: alias,
              version: protocolVersion,
              deviceModel: deviceInfo.deviceModel,
              deviceType: deviceInfo.deviceType,
              fingerprint: fingerprint,
              download: true,
            ),
            sessionId: sessionId,
            files: {
              for (final entry in state.webSendState!.files.entries) entry.key: entry.value.file,
            },
          ).toJson());
    });

    router.get(ApiRoute.download.v2, (HttpRequest request) async {
      final sessionId = request.uri.queryParameters['sessionId'];
      if (sessionId == null) {
        return await request.respondJson(400, message: 'Missing sessionId.');
      }

      final session = server.getState().webSendState?.sessions[sessionId];
      if (session == null || session.responseHandler != null || session.ip != request.ip) {
        return await request.respondJson(403, message: 'Invalid sessionId.');
      }

      final fileId = request.uri.queryParameters['fileId'];
      if (fileId == null) {
        return await request.respondJson(400, message: 'Missing fileId.');
      }

      final file = server.getState().webSendState?.files[fileId];
      if (file == null) {
        return await request.respondJson(403, message: 'Invalid fileId.');
      }

      final fileName = file.file.fileName.replaceAll('/', '-'); // File name may be inside directories

      request.response
        ..statusCode = 200
        ..headers.set('content-type', 'application/octet-stream')
        ..headers.set('content-disposition', 'attachment; filename="${Uri.encodeComponent(fileName)}"')
        ..headers.set('content-length', '${file.file.size}');

      if (file.bytes != null) {
        final byteStream = Stream.fromIterable([file.bytes!]);
        final (streamController, subscription) = byteStream.digested();

        await request.response.addStream(streamController.stream).then((_) {
          request.response.close();
          subscription.cancel();
        });
      } else {
        final path = file.path!;
        final tmpfile = File(file.path!);
        request.response.headers.set('content-length', '${tmpfile.lengthSync()}');

        final fileStream = path.startsWith('content://') ? UriContent().getContentStream(Uri.parse(file.path!)) : tmpfile.openRead();
        final (streamController, subscription) = fileStream.digested();

        await request.response.addStream(streamController.stream).then((_) {
          request.response.close();
          subscription.cancel();
        });
      }
    });
  }

  /// 生成新的浏览器上传链接；再次调用会使旧二维码失效。
  String enableWebUpload() {
    _webUploadToken = _uuid.v4();
    return _webUploadToken!;
  }

  Future<void> initializeWebSend({required List<CrossFile> files}) async {
    final webSendState = WebSendState(
      sessions: {},
      files: Map.fromEntries(await Future.wait(files.map((file) async {
        final id = _uuid.v4();
        return MapEntry(
          id,
          WebSendFile(
            file: FileDto(
              id: id,
              fileName: file.name,
              size: file.size,
              fileType: file.fileType,
              hash: null,
              preview: files.first.fileType == FileType.text && files.first.bytes != null
                  ? utf8.decode(files.first.bytes!) // send simple message by embedding it into the preview
                  : null,
              metadata: file.lastModified != null || file.lastAccessed != null
                  ? FileMetadata(
                      lastModified: file.lastModified,
                      lastAccessed: file.lastAccessed,
                    )
                  : null,
              legacy: false,
            ),
            asset: file.asset,
            path: file.path,
            bytes: file.bytes,
          ),
        );
      }))),
      autoAccept: server.ref.read(settingsProvider).shareViaLinkAutoAccept,
      pin: null,
      pinAttempts: {},
    );

    server.setState(
      (oldState) => oldState?.copyWith(
        webSendState: webSendState,
      ),
    );
  }

  void acceptRequest(String sessionId) {
    _respondRequest(sessionId, true);
  }

  void declineRequest(String sessionId) {
    _respondRequest(sessionId, false);
  }

  void _respondRequest(String sessionId, bool accepted) {
    final controller = server.getState().webSendState?.sessions[sessionId]?.responseHandler;
    if (controller == null) {
      return;
    }

    controller.add(accepted);
    controller.close(); // ignore: discarded_futures
  }
}

/// 该页面只负责把浏览器选择的文件转成 LocalSend v2 上传协议。
/// 文件落盘、接收确认、进度和历史仍完全由 ReceiveController 处理。
const _webUploadHtml = r'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>上传到 TanDrop</title><style>
body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#f5f7f6;color:#17201e;display:grid;min-height:100vh;place-items:center}
main{width:min(420px,calc(100% - 36px));padding:30px;border-radius:22px;background:#fff;box-shadow:0 14px 42px #0b24151c}
h1{font-size:23px;margin:0 0 8px}p{color:#68726e;line-height:1.55}input{width:100%;margin:20px 0}button{width:100%;border:0;border-radius:12px;background:#008b80;color:#fff;font-size:16px;font-weight:700;padding:14px}button:disabled{opacity:.5}#status{min-height:24px;margin-top:16px;color:#008b80}
</style></head><body><main><h1>上传到此 Mac</h1><p>选择文件后，TanDrop 会在 Mac 上请求确认。</p><input id="files" type="file" multiple><button id="send">开始上传</button><div id="status"></div></main>
<script>
const base='/api/localsend/v2', status=document.getElementById('status'), button=document.getElementById('send');
const id=()=>Date.now().toString(36)+Math.random().toString(36).slice(2);
const type=f=>f.type||'application/octet-stream';
button.onclick=async()=>{const files=[...document.getElementById('files').files];if(!files.length){status.textContent='请先选择文件';return}button.disabled=true;status.textContent='正在请求 Mac 确认…';
const mapped={};for(const f of files){const key=id();mapped[key]={id:key,fileName:f.name,size:f.size,fileType:type(f)};f._tanId=key}
const body={info:{alias:'浏览器上传',version:'2.1',deviceModel:navigator.platform||'Browser',deviceType:'web',fingerprint:'web-'+id(),port:0,protocol:'http',download:false},files:mapped};
try{const prepared=await fetch(base+'/prepare-upload',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)});if(!prepared.ok)throw new Error(prepared.status===403?'Mac 拒绝了本次传输':'无法开始上传（'+prepared.status+'）');const session=await prepared.json();let done=0;for(const f of files){const token=session.files[f._tanId];if(!token)continue;status.textContent='上传中 '+(++done)+' / '+files.length+'：'+f.name;const response=await fetch(base+'/upload?sessionId='+encodeURIComponent(session.sessionId)+'&fileId='+encodeURIComponent(f._tanId)+'&token='+encodeURIComponent(token),{method:'POST',body:f});if(!response.ok)throw new Error('上传失败（'+response.status+'）')}status.textContent='上传完成';}catch(error){status.textContent=error.message||'上传失败';button.disabled=false}}
</script></body></html>''';

extension on WebSendState {
  WebSendState updateSession({
    required String sessionId,
    required WebSendSession Function(WebSendSession oldSession) update,
  }) {
    return copyWith(
      sessions: {...sessions}..update(
          sessionId,
          (session) => update(session),
        ),
    );
  }
}
