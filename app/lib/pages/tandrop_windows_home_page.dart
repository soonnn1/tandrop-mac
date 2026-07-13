// ignore_for_file: directives_ordering

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:common/model/device.dart';
import 'package:common/model/session_status.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:localsend_app/gen/assets.gen.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/model/persistence/receive_history_entry.dart';
import 'package:localsend_app/model/state/send/send_session_state.dart';
import 'package:localsend_app/provider/device_info_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/progress_provider.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/receive_history_provider.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/util/device_type_ext.dart';
import 'package:localsend_app/util/file_size_helper.dart';
import 'package:localsend_app/util/file_type_ext.dart';
import 'package:localsend_app/util/native/autostart_helper.dart';
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/util/native/context_menu_helper.dart';
import 'package:localsend_app/util/native/file_picker.dart';
import 'package:localsend_app/util/native/open_file.dart';
import 'package:localsend_app/util/native/open_folder.dart';
import 'package:localsend_app/util/native/pick_directory_path.dart';
import 'package:localsend_app/widget/dialogs/qr_dialog.dart';
import 'package:localsend_app/widget/file_thumbnail.dart';
import 'package:path/path.dart' as path;
import 'package:refena_flutter/refena_flutter.dart';

/// TanDrop 的 Windows 仪表盘。
///
/// 此页面只组合官方已有的 Provider 和 Action，不改变发现、发送或接收协议。
class TanDropWindowsHomePage extends StatefulWidget {
  const TanDropWindowsHomePage({super.key});

  @override
  State<TanDropWindowsHomePage> createState() => _TanDropWindowsHomePageState();
}

class _TanDropWindowsHomePageState extends State<TanDropWindowsHomePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        // 仪表盘没有复用旧 SendTab，因此在页面出现时触发官方发现流程。
        // ignore: discarded_futures
        context.global.dispatchAsync(StartSmartScan(forceLegacy: false));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = _TanDropColors.of(context);
    final selectedFiles = context.watch(selectedSendingFilesProvider);
    final nearbyDevices =
        context.watch(nearbyDevicesProvider).devices.values.toList();
    final receiveHistory = context.watch(receiveHistoryProvider);
    final localDevice = context.watch(deviceFullInfoProvider);
    final localNetwork = context.watch(localIpProvider);
    final serverState = context.watch(serverProvider);
    final settings = context.watch(settingsProvider);

    return ColoredBox(
      color: colors.canvas,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final contentWidth = math.max(constraints.maxWidth, 1120.0);
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: contentWidth,
              child: SingleChildScrollView(
                // 默认窗口不放大，通过压缩页面内部留白让首屏内容尽量完整显示。
                padding: const EdgeInsets.fromLTRB(28, 18, 28, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Header(
                      localIp: localNetwork.localIps.isEmpty
                          ? null
                          : localNetwork.localIps.first,
                      onToggleTheme: () => unawaited(
                        context.ref.notifier(settingsProvider).setTheme(
                              settings.theme == ThemeMode.dark
                                  ? ThemeMode.light
                                  : ThemeMode.dark,
                            ),
                      ),
                      onShowAbout: () => _showAboutDialog(context),
                    ),
                    const SizedBox(height: 18),
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            flex: 11,
                            child: Column(
                              children: [
                                _QuickSendCard(
                                  selectedFiles: selectedFiles,
                                ),
                                const SizedBox(height: 16),
                                _DropReceiveCard(files: selectedFiles),
                              ],
                            ),
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            flex: 9,
                            child: _NearbyDevicesCard(
                              localDevice: localDevice,
                              devices: nearbyDevices,
                              hasSelectedFiles: selectedFiles.isNotEmpty,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            flex: 12,
                            child: _TransferActivityCard(
                              history: receiveHistory,
                              quickSave: settings.quickSave,
                              onQuickSaveChanged: (value) => unawaited(
                                context.ref
                                    .notifier(settingsProvider)
                                    .setQuickSave(value),
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            flex: 7,
                            child: _ConnectionCard(
                              ip: localNetwork.localIps.isEmpty
                                  ? '-'
                                  : localNetwork.localIps.first,
                              port: serverState?.port,
                              minimizeToTray: settings.minimizeToTray,
                              onToggleConnection: () => unawaited(
                                serverState == null
                                    ? context.ref
                                        .notifier(serverProvider)
                                        .startServerFromSettings()
                                    : context.ref
                                        .notifier(serverProvider)
                                        .stopServer(),
                              ),
                              onMinimizeToTrayChanged: (value) => unawaited(
                                context.ref
                                    .notifier(settingsProvider)
                                    .setMinimizeToTray(value),
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            flex: 9,
                            child: _DeviceInfoCard(
                              device: localDevice,
                              destination: settings.destination,
                              onAliasTap: () => unawaited(
                                _editAlias(
                                  context,
                                  currentAlias: localDevice.alias,
                                  serverRunning: serverState != null,
                                ),
                              ),
                              onDestinationTap: () async {
                                final selected = await pickDirectoryPath();
                                if (selected != null && context.mounted) {
                                  await context.ref
                                      .notifier(settingsProvider)
                                      .setDestination(selected);
                                }
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    const _Footer(),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _editAlias(
    BuildContext context, {
    required String currentAlias,
    required bool serverRunning,
  }) async {
    final controller = TextEditingController(text: currentAlias);
    final nextAlias = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('设备名称'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: '输入设备名称'),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
    controller.dispose();

    final trimmed = nextAlias?.trim();
    if (trimmed == null || trimmed.isEmpty || !context.mounted) {
      return;
    }

    await context.ref.notifier(settingsProvider).setAlias(trimmed);
    if (serverRunning && context.mounted) {
      await context.ref.notifier(serverProvider).restartServerFromSettings();
    }
  }

  void _showAboutDialog(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: 'TanDrop',
      applicationVersion: '1.0.0',
      children: const [
        Text('本地网络文件传输工具。'),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final String? localIp;
  final VoidCallback onToggleTheme;
  final VoidCallback onShowAbout;

  const _Header({
    required this.localIp,
    required this.onToggleTheme,
    required this.onShowAbout,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _TanDropColors.of(context);
    return Row(
      children: [
        ClipOval(
          child: SizedBox(
            width: 34,
            height: 34,
            child: Assets.img.logo512.image(
              fit: BoxFit.cover,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          'TanDrop',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
              ),
        ),
        const Spacer(),
        Icon(Icons.wifi_rounded, color: colors.primary, size: 25),
        const SizedBox(width: 10),
        Text(
          '当前网络：',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: colors.muted),
        ),
        Text(
          localIp == null ? '正在连接 Wi‑Fi' : 'Wi‑Fi · $localIp',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const Spacer(),
        _HeaderIcon(
          icon: Icons.dark_mode_outlined,
          tooltip: '切换深色模式',
          onPressed: onToggleTheme,
        ),
        const SizedBox(width: 8),
        _HeaderIcon(
          icon: Icons.help_outline_rounded,
          tooltip: '帮助',
          onPressed: () => _showHelp(context),
        ),
        Container(
          width: 1,
          height: 28,
          color: colors.divider,
          margin: const EdgeInsets.symmetric(horizontal: 17),
        ),
        _HeaderIcon(
          icon: Icons.account_circle_outlined,
          tooltip: '关于 TanDrop',
          onPressed: onShowAbout,
        ),
      ],
    );
  }

  void _showHelp(BuildContext context) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('TanDrop：在本地网络中安全地传输文件。')));
  }
}

class _HeaderIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const _HeaderIcon({
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _TanDropColors.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(22),
          child: Ink(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: colors.headerButton,
              shape: BoxShape.circle,
              border: Border.all(color: colors.divider),
            ),
            child: Icon(icon, size: 20, color: colors.muted),
          ),
        ),
      ),
    );
  }
}

class _QuickSendCard extends StatelessWidget {
  final List<CrossFile> selectedFiles;

  const _QuickSendCard({required this.selectedFiles});

  @override
  Widget build(BuildContext context) {
    final totalSize = selectedFiles.fold<int>(
      0,
      (sum, file) => sum + file.size,
    );
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle(title: '快速发送'),
          const SizedBox(height: 14),
          Row(
            children: const [
              Expanded(
                child: _QuickAction(
                  option: FilePickerOption.file,
                  title: '文件',
                  subtitle: '发送文件',
                ),
              ),
              SizedBox(width: 14),
              Expanded(
                child: _QuickAction(
                  option: FilePickerOption.folder,
                  title: '文件夹',
                  subtitle: '发送文件夹',
                ),
              ),
              SizedBox(width: 14),
              Expanded(
                child: _QuickAction(
                  option: FilePickerOption.media,
                  title: '照片',
                  subtitle: '发送照片',
                ),
              ),
              SizedBox(width: 14),
              Expanded(
                child: _QuickAction(
                  option: FilePickerOption.text,
                  title: '文本',
                  subtitle: '发送文本内容',
                ),
              ),
              SizedBox(width: 14),
              Expanded(
                child: _QuickAction(
                  option: FilePickerOption.clipboard,
                  title: '剪贴板',
                  subtitle: '发送剪贴板',
                ),
              ),
            ],
          ),
          if (selectedFiles.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: _TanDropColors.of(context).primarySoft,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '已选择 ${selectedFiles.length} 个项目 · ${totalSize.asReadableFileSize}，请在右侧选择设备发送。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: _TanDropColors.of(context).primary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  final FilePickerOption option;
  final String title;
  final String subtitle;

  const _QuickAction({
    required this.option,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _TanDropColors.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () async {
          await context.global.dispatchAsync(
            PickFileAction(option: option, context: context),
          );
        },
        borderRadius: BorderRadius.circular(17),
        child: Ink(
          height: 122,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          decoration: BoxDecoration(
            color: colors.subtleSurface,
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: colors.divider),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(option.icon, color: colors.primary, size: 32),
              const SizedBox(height: 8),
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: colors.primary,
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.muted,
                      fontSize: 11,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContextMenuToggle extends StatefulWidget {
  const _ContextMenuToggle();

  @override
  State<_ContextMenuToggle> createState() => _ContextMenuToggleState();
}

class _ContextMenuToggleState extends State<_ContextMenuToggle> {
  bool? _enabled;
  bool _updating = false;

  @override
  void initState() {
    super.initState();
    unawaited(isContextMenuEnabled().then((value) {
      if (mounted) setState(() => _enabled = value);
    }));
  }

  @override
  Widget build(BuildContext context) {
    return _InlineSwitch(
      label: _updating ? '右键菜单…' : '右键菜单',
      width: 132,
      value: _enabled ?? false,
      onChanged: _enabled == null || _updating
          ? null
          : (value) => unawaited(_toggle(context, value)),
    );
  }

  Future<void> _toggle(BuildContext context, bool value) async {
    final previousValue = _enabled!;
    // 先更新界面，PowerShell 在后台创建快捷方式，避免开关卡顿。
    setState(() {
      _enabled = value;
      _updating = true;
    });
    final success =
        value ? await enableContextMenu() : await disableContextMenu();
    if (!context.mounted) return;
    setState(() {
      _updating = false;
      if (!success) _enabled = previousValue;
    });
    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('更新 Windows 右键菜单失败。')),
      );
    }
  }
}

class _DropReceiveCard extends StatelessWidget {
  final List<CrossFile> files;

  const _DropReceiveCard({required this.files});

  @override
  Widget build(BuildContext context) {
    final colors = _TanDropColors.of(context);
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(
            title: '发送文件',
            action: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _ContextMenuToggle(),
                if (files.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => context.ref
                        .redux(selectedSendingFilesProvider)
                        .dispatch(ClearSelectionAction()),
                    icon: const Icon(Icons.clear_all_rounded, size: 17),
                    label: const Text('全部清除'),
                    style: TextButton.styleFrom(
                      foregroundColor: colors.muted,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          DropTarget(
            onDragDone: (event) async {
              if (event.files.length == 1 &&
                  Directory(event.files.first.path).existsSync()) {
                await context.ref
                    .redux(selectedSendingFilesProvider)
                    .dispatchAsync(AddDirectoryAction(event.files.first.path));
              } else {
                await context.ref
                    .redux(selectedSendingFilesProvider)
                    .dispatchAsync(
                      AddFilesAction(
                        files: event.files,
                        converter: CrossFileConverters.convertXFile,
                      ),
                    );
              }
            },
            child: SizedBox(
              width: double.infinity,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () async {
                    await context.global.dispatchAsync(
                      PickFileAction(
                        option: FilePickerOption.file,
                        context: context,
                      ),
                    );
                  },
                  borderRadius: BorderRadius.circular(15),
                  child: Ink(
                    height: files.isEmpty ? 126 : 148,
                    decoration: BoxDecoration(
                      color: colors.subtleSurface,
                      borderRadius: BorderRadius.circular(15),
                      border: Border.all(color: colors.divider, width: 1.2),
                    ),
                    child: files.isEmpty
                        ? _EmptySendPrompt(colors: colors)
                        : ListView.separated(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            itemCount: files.length,
                            separatorBuilder: (_, __) => Divider(
                              height: 1,
                              color: colors.divider,
                            ),
                            itemBuilder: (context, index) {
                              final file = files[index];
                              return Row(
                                children: [
                                  Icon(file.fileType.icon,
                                      size: 28, color: colors.primary),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(file.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w600)),
                                        const SizedBox(height: 3),
                                        Text(file.size.asReadableFileSize,
                                            style: TextStyle(
                                                color: colors.muted,
                                                fontSize: 12)),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: '移除',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: () => context.ref
                                        .redux(selectedSendingFilesProvider)
                                        .dispatch(
                                            RemoveSelectedFileAction(index)),
                                    icon: Icon(Icons.close_rounded,
                                        size: 18, color: colors.muted),
                                  ),
                                ],
                              );
                            },
                          ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptySendPrompt extends StatelessWidget {
  final _TanDropColors colors;

  const _EmptySendPrompt({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.file_download_outlined, size: 34, color: colors.primary),
        const SizedBox(height: 8),
        Text('拖拽文件到此处发送',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: colors.primary,
                  fontWeight: FontWeight.w700,
                )),
        const SizedBox(height: 4),
        Text('或点击选择文件',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: colors.primary)),
      ],
    );
  }
}

class _NearbyDevicesCard extends StatelessWidget {
  final Device localDevice;
  final List<Device> devices;
  final bool hasSelectedFiles;

  const _NearbyDevicesCard({
    required this.localDevice,
    required this.devices,
    required this.hasSelectedFiles,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _TanDropColors.of(context);
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(
            title: '附近的设备',
            action: TextButton.icon(
              onPressed: () => _refresh(context),
              icon: const Icon(Icons.refresh_rounded, size: 17),
              label: const Text('刷新'),
              style: TextButton.styleFrom(
                foregroundColor: colors.muted,
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
            ),
          ),
          const SizedBox(height: 14),
          _DeviceRow(
            key: ValueKey('local-${localDevice.fingerprint}'),
            device: localDevice,
            isLocal: true,
            enabled: false,
          ),
          const SizedBox(height: 9),
          if (devices.isEmpty)
            _EmptyDevices(
              onRefresh: () => _refresh(context),
            )
          else
            ...devices.take(4).map(
                  (device) => Padding(
                    padding: const EdgeInsets.only(bottom: 9),
                    child: _DeviceRow(
                      key: ValueKey(device.fingerprint),
                      device: device,
                      isLocal: false,
                      enabled: hasSelectedFiles,
                    ),
                  ),
                ),
          const Spacer(),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    text: '未找到设备？尝试',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(
                          color: colors.muted,
                          decoration: TextDecoration.none,
                        ),
                    children: [
                      TextSpan(
                        text: '检查网络',
                        style: TextStyle(
                          color: colors.primary,
                          fontWeight: FontWeight.w600,
                          decoration: TextDecoration.none,
                        ),
                      ),
                      const TextSpan(text: '或刷新列表。'),
                    ],
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () => unawaited(_showUploadQr(context)),
                icon: const Icon(Icons.qr_code_rounded, size: 16),
                label: const Text('扫码上传'),
                style: TextButton.styleFrom(
                  foregroundColor: colors.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _refresh(BuildContext context) {
    context.ref
        .redux(nearbyDevicesProvider)
        .dispatch(ClearFoundDevicesAction());
    unawaited(
      context.global.dispatchAsync(StartSmartScan(forceLegacy: true)),
    );
  }

  Future<void> _showUploadQr(BuildContext context) async {
    final ref = context.ref;
    var server = ref.read(serverProvider);
    if (server == null) {
      await ref.notifier(serverProvider).startServerFromSettings();
      if (!context.mounted) return;
      server = ref.read(serverProvider);
    }
    if (server?.session != null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('正在传输文件，暂时不能开启网页上传。')),
        );
      }
      return;
    }

    // 手机浏览器直接打开 HTTP，避免自签名 HTTPS 证书阻断扫码页面。
    final restoreHttps = server?.https == true;
    if (restoreHttps) {
      final settings = ref.read(settingsProvider);
      await ref.notifier(serverProvider).restartServer(
            alias: settings.alias,
            port: settings.port,
            https: false,
          );
      if (!context.mounted) return;
      server = ref.read(serverProvider);
    }
    final ips = ref.read(localIpProvider).localIps;
    if (!context.mounted) {
      if (restoreHttps) {
        await ref.notifier(serverProvider).restartServerFromSettings();
      }
      return;
    }
    if (server == null || ips.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未检测到可用于扫码的局域网地址。')),
      );
      if (restoreHttps) {
        await ref.notifier(serverProvider).restartServerFromSettings();
      }
      return;
    }

    final token = ref.notifier(serverProvider).enableWebUpload();
    final url = 'http://${ips.first}:${server.port}/upload?token=$token';
    try {
      await showDialog<void>(
        context: context,
        builder: (_) => QrDialog(data: url, label: '扫码上传到此电脑'),
      );
    } finally {
      if (restoreHttps) {
        await ref.notifier(serverProvider).restartServerFromSettings();
      }
    }
  }
}

class _DeviceRow extends StatefulWidget {
  final Device device;
  final bool isLocal;
  final bool enabled;

  const _DeviceRow({
    super.key,
    required this.device,
    required this.isLocal,
    required this.enabled,
  });

  @override
  State<_DeviceRow> createState() => _DeviceRowState();
}

class _DeviceRowState extends State<_DeviceRow> with Refena {
  String? _activeSessionId;
  SessionStatus? _terminalStatus;
  Timer? _terminalTimer;

  @override
  void dispose() {
    _terminalTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(sendProvider);
    final session =
        _activeSessionId == null ? null : sessions[_activeSessionId];
    final sessionStatus = session?.status;
    final isTransferring = sessionStatus == SessionStatus.waiting ||
        sessionStatus == SessionStatus.sending;
    final terminalStatus = isTransferring ? null : _terminalStatus;
    final progressNotifier = ref.watch(progressProvider);
    final progress = isTransferring && session != null
        ? _sendProgress(session, progressNotifier)
        : null;
    final colors = _TanDropColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      decoration: BoxDecoration(
        color: colors.subtleSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider),
      ),
      child: Row(
        children: [
          Icon(widget.device.deviceType.icon, size: 30, color: colors.text),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        widget.device.alias,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                    if (widget.isLocal) ...[
                      const SizedBox(width: 8),
                      _Tag(text: '本机'),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${widget.device.ip}  ·  ${widget.device.deviceModel}',
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.muted),
                ),
                if (progress != null) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 5,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (widget.isLocal)
            Text(
              '本机',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.muted),
            )
          else ...[
            if (terminalStatus != null) ...[
              Icon(
                terminalStatus == SessionStatus.finished
                    ? Icons.check_circle_rounded
                    : Icons.cancel_rounded,
                color: terminalStatus == SessionStatus.finished
                    ? Colors.green
                    : Colors.red,
              ),
              const SizedBox(width: 8),
            ],
            OutlinedButton(
              onPressed: isTransferring
                  ? _cancelTransfer
                  : widget.enabled
                      ? () => unawaited(_sendToDevice(widget.device))
                      : null,
              style: OutlinedButton.styleFrom(
                foregroundColor: isTransferring ? Colors.red : colors.primary,
                side: BorderSide(
                  color: isTransferring ? Colors.red : colors.primary,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Text(isTransferring ? '终止' : '发送'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _sendToDevice(Device target) async {
    final files = ref.read(selectedSendingFilesProvider);
    if (files.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先在左侧选择要发送的文件。')));
      return;
    }
    _terminalTimer?.cancel();
    String? createdSessionId;
    setState(() {
      _terminalStatus = null;
      _activeSessionId = null;
    });
    final result = await ref.notifier(sendProvider).startSession(
          target: target,
          files: files,
          background: true,
          onSessionCreated: (sessionId) {
            createdSessionId = sessionId;
            if (mounted) {
              setState(() => _activeSessionId = sessionId);
            }
          },
        );
    if (result == SessionStatus.finished) {
      ref.redux(selectedSendingFilesProvider).dispatch(ClearSelectionAction());
    }
    if (!mounted || _activeSessionId != createdSessionId) return;
    final sessionId = createdSessionId;
    if (sessionId != null) {
      ref.notifier(sendProvider).closeSession(sessionId);
    }
    setState(() {
      _activeSessionId = null;
      _terminalStatus = result;
    });
    _scheduleTerminalReset();
  }

  void _cancelTransfer() {
    final sessionId = _activeSessionId;
    if (sessionId == null) return;
    // 取消真实发送会话，同时通知接收端中止。
    ref.notifier(sendProvider).cancelSession(sessionId);
    setState(() {
      _activeSessionId = null;
      _terminalStatus = SessionStatus.canceledBySender;
    });
    _scheduleTerminalReset();
  }

  void _scheduleTerminalReset() {
    _terminalTimer?.cancel();
    _terminalTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _terminalStatus = null);
    });
  }
}

double _sendProgress(SendSessionState session, ProgressNotifier notifier) {
  final files = session.files.values.where((file) => file.token != null);
  final total = files.fold<int>(0, (sum, file) => sum + file.file.size);
  if (total == 0) return 0;
  final current = files.fold<int>(
      0,
      (sum, file) =>
          sum +
          (notifier.getProgress(
                      sessionId: session.sessionId, fileId: file.file.id) *
                  file.file.size)
              .round());
  return current / total;
}

class _EmptyDevices extends StatelessWidget {
  final VoidCallback onRefresh;

  const _EmptyDevices({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final colors = _TanDropColors.of(context);
    return Container(
      width: double.infinity,
      height: 128,
      decoration: BoxDecoration(
        color: colors.subtleSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider),
      ),
      child: Center(
        child: TextButton.icon(
          onPressed: onRefresh,
          icon: Icon(Icons.radar_rounded, color: colors.primary),
          label: Text('正在搜索附近设备', style: TextStyle(color: colors.primary)),
        ),
      ),
    );
  }
}

class _TransferActivityCard extends StatelessWidget {
  final List<ReceiveHistoryEntry> history;
  final bool quickSave;
  final ValueChanged<bool> onQuickSaveChanged;

  const _TransferActivityCard({
    required this.history,
    required this.quickSave,
    required this.onQuickSaveChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _TanDropColors.of(context);
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionTitle(
            title: '接受文件',
            action: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _InlineSwitch(
                  label: '自动接收',
                  width: 132,
                  value: quickSave,
                  onChanged: onQuickSaveChanged,
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: history.isEmpty
                      ? null
                      : () => unawaited(
                            context.ref
                                .redux(receiveHistoryProvider)
                                .dispatchAsync(RemoveAllHistoryEntriesAction()),
                          ),
                  icon: const Icon(Icons.clear_all_rounded, size: 17),
                  label: const Text('全部清除'),
                  style: TextButton.styleFrom(
                    foregroundColor: colors.muted,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (history.isEmpty)
            SizedBox(
              height: 128,
              child: Center(
                child: Text(
                  '暂无接收文件',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: colors.muted),
                ),
              ),
            )
          else
            SizedBox(
              height: 150,
              child: ListView.separated(
                padding: EdgeInsets.zero,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: math.min(history.length, 3),
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (context, index) {
                  return _TransferRow(entry: history[index]);
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _TransferRow extends StatelessWidget {
  final ReceiveHistoryEntry entry;

  const _TransferRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final colors = _TanDropColors.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(11),
        onTap: () => unawaited(_openFile(context)),
        onSecondaryTap: () => unawaited(_showActions(context)),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: colors.subtleSurface,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: colors.divider),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: FilePathThumbnail(
                    path: entry.path,
                    fileType: entry.fileType,
                  ),
                ),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(
                        context,
                      )
                          .textTheme
                          .bodySmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${entry.fileSize.asReadableFileSize}  ·  来自 ${entry.senderAlias}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: colors.muted,
                            fontSize: 11,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.check_circle_rounded, color: colors.success, size: 17),
              IconButton(
                tooltip: '移除记录',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 28,
                  height: 28,
                ),
                onPressed: () => unawaited(
                  context.ref
                      .redux(receiveHistoryProvider)
                      .dispatchAsync(RemoveHistoryEntryAction(entry.id)),
                ),
                icon: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: colors.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openFile(BuildContext context) async {
    if (entry.path == null) return;
    await openFile(
      context,
      entry.fileType,
      entry.path!,
      onDeleteTap: () => unawaited(
        context.ref
            .redux(receiveHistoryProvider)
            .dispatchAsync(RemoveHistoryEntryAction(entry.id)),
      ),
    );
  }

  Future<void> _showActions(BuildContext context) async {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox) return;
    final overlay = Navigator.of(context).overlay?.context.findRenderObject();
    if (overlay is! RenderBox) return;

    final origin = renderObject.localToGlobal(Offset.zero);
    final size = renderObject.size;
    final menuAnchor = Rect.fromLTWH(
      origin.dx + size.width - 12,
      origin.dy + size.height - 10,
      1,
      1,
    );
    final action = await showMenu<_ReceiveFileAction>(
      context: context,
      position: RelativeRect.fromRect(menuAnchor, Offset.zero & overlay.size),
      items: [
        PopupMenuItem(
          value: _ReceiveFileAction.open,
          enabled: entry.path != null,
          child: const Row(
            children: [
              Icon(Icons.open_in_new_rounded, size: 18),
              SizedBox(width: 9),
              Text('打开文件'),
            ],
          ),
        ),
        PopupMenuItem(
          value: _ReceiveFileAction.reveal,
          enabled: entry.path != null,
          child: const Row(
            children: [
              Icon(Icons.folder_open_rounded, size: 18),
              SizedBox(width: 9),
              Text('在 Finder 中显示'),
            ],
          ),
        ),
      ],
    );

    if (entry.path == null || action == null || !context.mounted) {
      return;
    }

    switch (action) {
      case _ReceiveFileAction.open:
        await openFile(
          context,
          entry.fileType,
          entry.path!,
          onDeleteTap: () => unawaited(
            context.ref
                .redux(receiveHistoryProvider)
                .dispatchAsync(RemoveHistoryEntryAction(entry.id)),
          ),
        );
      case _ReceiveFileAction.reveal:
        await openFolder(
          folderPath: File(entry.path!).parent.path,
          fileName: path.basename(entry.path!),
        );
    }
  }
}

enum _ReceiveFileAction { open, reveal }

class _ConnectionCard extends StatelessWidget {
  final String ip;
  final int? port;
  final bool minimizeToTray;
  final VoidCallback onToggleConnection;
  final ValueChanged<bool> onMinimizeToTrayChanged;

  const _ConnectionCard({
    required this.ip,
    required this.port,
    required this.minimizeToTray,
    required this.onToggleConnection,
    required this.onMinimizeToTrayChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _TanDropColors.of(context);
    final connected = port != null;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle(title: '连接状态'),
          const SizedBox(height: 20),
          Row(
            children: [
              Container(
                width: 59,
                height: 59,
                decoration: BoxDecoration(
                  color: colors.primarySoft,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.wifi_rounded,
                  color: colors.primary,
                  size: 35,
                ),
              ),
              const SizedBox(width: 13),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    connected ? '已连接' : '已断开',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: connected ? colors.primary : colors.muted,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    connected ? 'Wi‑Fi 网络可用' : '接收服务已停止',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: colors.muted),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _InlineSwitch(
                  label: '后台运行',
                  value: minimizeToTray,
                  onChanged: onMinimizeToTrayChanged,
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(child: _AutoStartSwitch()),
            ],
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onToggleConnection,
              icon: Icon(
                connected ? Icons.link_off_rounded : Icons.link_rounded,
              ),
              label: Text(connected ? '断开连接' : '重新连接'),
              style: OutlinedButton.styleFrom(
                foregroundColor: connected ? colors.danger : colors.primary,
                side: BorderSide(
                  color: (connected ? colors.danger : colors.primary)
                      .withOpacity(0.55),
                ),
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineSwitch extends StatelessWidget {
  final String label;
  final double? width;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const _InlineSwitch({
    required this.label,
    this.width,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _TanDropColors.of(context);
    final switchContent = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 38,
        padding: const EdgeInsets.only(left: 10, right: 3),
        decoration: BoxDecoration(
          color: colors.subtleSurface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colors.divider),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
            Transform.scale(
              scale: 0.72,
              alignment: Alignment.centerRight,
              child: Switch(value: value, onChanged: onChanged),
            ),
          ],
        ),
      ),
    );
    return width == null
        ? switchContent
        : SizedBox(width: width, child: switchContent);
  }
}

class _AutoStartSwitch extends StatefulWidget {
  const _AutoStartSwitch();

  @override
  State<_AutoStartSwitch> createState() => _AutoStartSwitchState();
}

class _AutoStartSwitchState extends State<_AutoStartSwitch> {
  late Future<bool> _enabledFuture = isAutoStartEnabled();
  bool _updating = false;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _enabledFuture,
      builder: (context, snapshot) {
        final enabled = snapshot.data ?? false;
        return _InlineSwitch(
          label: '开机启动',
          value: enabled,
          onChanged:
              snapshot.connectionState == ConnectionState.waiting || _updating
                  ? null
                  : (value) => unawaited(_toggle(context, value)),
        );
      },
    );
  }

  Future<void> _toggle(BuildContext context, bool value) async {
    setState(() {
      _updating = true;
    });

    final success = value
        ? await enableAutoStart(startHidden: true)
        : await disableAutoStart();

    if (!mounted) {
      return;
    }

    if (!success) {
      ScaffoldMessenger.of(
        this.context,
      ).showSnackBar(const SnackBar(content: Text('开机启动设置失败。')));
    }

    setState(() {
      _enabledFuture = isAutoStartEnabled();
      _updating = false;
    });
  }
}

class _DeviceInfoCard extends StatelessWidget {
  final Device device;
  final String? destination;
  final VoidCallback onAliasTap;
  final VoidCallback onDestinationTap;

  const _DeviceInfoCard({
    required this.device,
    required this.destination,
    required this.onAliasTap,
    required this.onDestinationTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _TanDropColors.of(context);
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle(title: '设备信息'),
          const SizedBox(height: 18),
          Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              onTap: onAliasTap,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Container(
                      width: 58,
                      height: 44,
                      decoration: BoxDecoration(
                        color: colors.primarySoft,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(
                        device.deviceType.icon,
                        color: colors.primary,
                        size: 29,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            device.alias,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            device.deviceModel ?? '桌面设备',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: colors.muted),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.edit_rounded, size: 17, color: colors.muted),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 19),
          _DeviceDetail(label: 'IP 地址', value: device.ip),
          const SizedBox(height: 12),
          _DeviceDetail(
            label: '端口',
            value: device.port < 0 ? '-' : '${device.port}',
          ),
          const SizedBox(height: 12),
          _DeviceDetail(
            label: '保存位置',
            value: destination ?? '默认下载文件夹',
            icon: Icons.folder_outlined,
            onTap: onDestinationTap,
          ),
        ],
      ),
    );
  }
}

class _DeviceDetail extends StatelessWidget {
  final String label;
  final String value;
  final IconData? icon;
  final VoidCallback? onTap;

  const _DeviceDetail({
    required this.label,
    required this.value,
    this.icon,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = _TanDropColors.of(context);
    final content = Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.muted),
          ),
        ),
        if (icon != null) ...[
          Icon(icon, color: colors.primary, size: 17),
          const SizedBox(width: 4),
        ],
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
    if (onTap == null) {
      return content;
    }

    // InkWell 需要 Material 祖先，否则桌面端运行时会出现 No Material widget found。
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: content,
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    final colors = _TanDropColors.of(context);
    return Center(
      child: Text.rich(
        TextSpan(
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(
                color: colors.muted,
                decoration: TextDecoration.none,
              ),
          children: const [
            WidgetSpan(
              child: Padding(
                padding: EdgeInsets.only(right: 7),
                child: Icon(Icons.lock_outline_rounded, size: 15),
              ),
            ),
            TextSpan(text: '安全传输端到端加密   ·   TanDrop v1.0.0'),
          ],
        ),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  final Widget child;

  const _Panel({required this.child});

  @override
  Widget build(BuildContext context) {
    final colors = _TanDropColors.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: colors.divider),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.018),
            blurRadius: 20,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final Widget? action;

  const _SectionTitle({required this.title, this.action});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const Spacer(),
        if (action != null) action!,
      ],
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;

  const _Tag({required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = _TanDropColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: colors.successSoft,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: colors.success,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _TanDropColors {
  final Color canvas;
  final Color surface;
  final Color subtleSurface;
  final Color headerButton;
  final Color divider;
  final Color primary;
  final Color primarySoft;
  final Color success;
  final Color successSoft;
  final Color danger;
  final Color text;
  final Color muted;

  const _TanDropColors({
    required this.canvas,
    required this.surface,
    required this.subtleSurface,
    required this.headerButton,
    required this.divider,
    required this.primary,
    required this.primarySoft,
    required this.success,
    required this.successSoft,
    required this.danger,
    required this.text,
    required this.muted,
  });

  factory _TanDropColors.of(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final primary = dark ? const Color(0xff54c4bd) : const Color(0xff007d77);
    return _TanDropColors(
      canvas: dark ? const Color(0xff171a1a) : const Color(0xfff8f9f8),
      surface: dark ? const Color(0xff202524) : Colors.white,
      subtleSurface: dark ? const Color(0xff1b201f) : const Color(0xfffcfdfc),
      headerButton: dark ? const Color(0xff242a29) : const Color(0xfffbfbfb),
      divider: dark ? Colors.white.withOpacity(0.10) : const Color(0xffe7eae9),
      primary: primary,
      primarySoft: primary.withOpacity(dark ? 0.17 : 0.10),
      success: const Color(0xff24a348),
      successSoft: const Color(0xff24a348).withOpacity(dark ? 0.20 : 0.12),
      danger: const Color(0xffe95353),
      text: colorScheme.onSurface,
      muted: dark ? const Color(0xffa6adaa) : const Color(0xff777d7b),
    );
  }
}
