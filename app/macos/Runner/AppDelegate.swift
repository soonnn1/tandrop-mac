import Cocoa
import CoreImage
import FlutterMacOS
import QuickLookThumbnailing
import Defaults
import DockProgress
import LaunchAtLogin

enum DockIcon: CaseIterable {
    case regular
    case error
    case success
}

extension LaunchAtLogin {
    /**
     Whether the app was launched at login (i.e. as login items).
     - Important: This property must only be checked in `NSApplicationDelegate#applicationDidFinishLaunching` method, otherwise the `NSAppleEventManager.shared().currentAppleEvent` will be `nil`.
     - Source: https://stackoverflow.com/a/19890943
     - Note: When we drop macOS 12 support and move to LaunchAtLogin-Modern package, this extension should be removed as it's already included - https://github.com/sindresorhus/LaunchAtLogin-Modern/blob/a04ec1c363be3627734f6dad757d82f5d4fa8fcc/Sources/LaunchAtLogin/LaunchAtLogin.swift#L34-L44
     */
    public static var wasLaunchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return (event.eventID == kAEOpenApplication)
        && (event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem)
    }
}

@main
class AppDelegate: FlutterAppDelegate {
    private var statusItem: NSStatusItem?
    private var channel: FlutterMethodChannel?
    private var sendPanelController: SendPanelController?
    private var receivePanelController: ReceivePanelController?
    private var pendingFilesObservation: Defaults.Observation?
    private var pendingStringsObservation: Defaults.Observation?
    private var isLaunchedAsLoginItem: Bool?
    
    override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // LocalSend handles the close event manually
        return false
    }
    
    override func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = mainFlutterWindow?.contentViewController as! FlutterViewController
        channel = FlutterMethodChannel(name: "main-delegate-channel", binaryMessenger: controller.engine.binaryMessenger)
        channel?.setMethodCallHandler(handleFlutterCall)
        
        self.setupDockIconTextDropEventListener()
        
        let localsendBrandColor = NSColor(red: 0, green: 0.392, blue: 0.353, alpha: 0.8) // #00645a
        DockProgress.style = .squircle(color: localsendBrandColor)
        
        isLaunchedAsLoginItem = LaunchAtLogin.wasLaunchedAtLogin
        
        restoreDestinationFolderAccess()
    }
    
    override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLocalSendFromMenuBar()
        return false
    }
    
    private func setupPendingItemsObservation() {
        self.pendingFilesObservation = Defaults.observe(.pendingFiles) { change in
            guard !Defaults[.pendingFiles].isEmpty else { return }
            self.sendPendingItemsToFlutter()
        }
        
        self.pendingStringsObservation = Defaults.observe(.pendingStrings) { change in
            guard !Defaults[.pendingStrings].isEmpty else { return }
            self.sendPendingItemsToFlutter()
        }
    }
    
    private func setDockIcon(icon: DockIcon) {
        switch icon {
        case .regular:
            NSApplication.shared.applicationIconImage = NSImage(named: NSImage.applicationIconName)
        case .error:
            NSApplication.shared.applicationIconImage = NSImage(named: "AppIconWithErrorMark")!
        case .success:
            NSApplication.shared.applicationIconImage = NSImage(named: "AppIconWithSuccessMark")!
        }
    }
    
    private func setupDockIconTextDropEventListener() {
        let appleEventManager = NSAppleEventManager.shared()
        
        appleEventManager.setEventHandler(
            self,
            andSelector: #selector(handleOpenContentsEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenContents)
        )
    }
    
    private func setupStatusBarItem(i18n: [String: String]) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            // 菜单栏使用系统单色传输符号，避免沿用 LocalSend 的旧资源图标。
            let image = NSImage(
                systemSymbolName: "arrow.left.arrow.right.circle",
                accessibilityDescription: "TanDrop"
            )
            image?.size = NSSize(width: 18, height: 18)
            image?.isTemplate = true
            button.image = image
            
            let menu = NSMenu()
            
            let openString = i18n["open"]!
            let openItem = NSMenuItem(title: openString, action: #selector(showLocalSendFromMenuBar), keyEquivalent: "o")
            menu.addItem(openItem)
            
            let quitString = i18n["quit"]!
            let quitItem = NSMenuItem(title: quitString, action: #selector(quitApp), keyEquivalent: "q")
            menu.addItem(quitItem)
            
            statusItem?.menu = menu
            
            let dragView = ContentDropView(frame: button.bounds)
            button.addSubview(dragView)
            
            dragView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dragView.topAnchor.constraint(equalTo: button.topAnchor),
                dragView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                dragView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                dragView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
        }
    }
    
    @objc func showLocalSendFromMenuBar() {
        channel?.invokeMethod("showLocalSendFromMenuBar", arguments: nil)
    }
    
    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
    
    func sendPendingItemsToFlutter() {
        let pendingFileBookmarks = Defaults[.pendingFiles]
        let pendingStrings = Defaults[.pendingStrings]
        var filePaths: [String] = []
        
        for bookmark in pendingFileBookmarks {
            if let url = SecurityScopedResourceManager.shared.startAccessing(bookmark: bookmark) {
                filePaths.append(url.path)
            }
        }
        
        if !filePaths.isEmpty {
            channel?.invokeMethod("onPendingFiles", arguments: filePaths)
        }
        if !pendingStrings.isEmpty {
            channel?.invokeMethod("onPendingStrings", arguments: pendingStrings)
        }
        
        showSendPanel(filePaths: filePaths, strings: pendingStrings)
        
        Defaults[.pendingFiles] = []
        Defaults[.pendingStrings] = []
    }
    
    private func showSendPanel(filePaths: [String], strings: [String]) {
        if sendPanelController == nil {
            sendPanelController = SendPanelController()
        }
        sendPanelController?.onAction = { [weak self] action in
            self?.channel?.invokeMethod("sendPanelAction", arguments: action)
        }
        sendPanelController?.show(filePaths: filePaths, strings: strings)
    }
    
    // START: handle opened files
    @MainActor private func handleFlutterCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "methodChannelInitialized":
            /// Any call to the channel is dropped until methodChannelInitialized is called from Flutter
            setupPendingItemsObservation()
            if !Defaults[.pendingFiles].isEmpty || !Defaults[.pendingStrings].isEmpty {
                sendPendingItemsToFlutter()
            }
            result(nil)
        case "setupStatusBar":
            let i18n = call.arguments as! [String: String]
            setupStatusBarItem(i18n: i18n)
            result(nil)
        case "removeDestinationFolderAccess":
            removeExistingDestinationAccess()
            result(nil)
        case "persistDestinationFolderAccess":
            let folderPath = call.arguments as! String
            do {
                try saveDestinationFolderAccess(folderPath)
                result(nil)
            } catch {
                result(FlutterError(code: "REQUEST_FOLDER_ACCESS_FAILED", message: "An error occurred while requesting folder access", details: nil))
            }
        case "updateDockProgress":
            let progress = call.arguments as! Double
            DockProgress.progress = progress
            result(nil)
        case "setDockIcon":
            let newIconIndex = call.arguments as! Int
            let newIcon = DockIcon.allCases[newIconIndex]
            setDockIcon(icon: newIcon)
        case "showReceivePanel":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Expected receive panel arguments", details: nil))
                return
            }
            showReceivePanel(args: args)
            result(nil)
        case "updateReceivePanel":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Expected receive panel update arguments", details: nil))
                return
            }
            receivePanelController?.update(args: args)
            result(nil)
        case "hideReceivePanel":
            receivePanelController?.close()
            result(nil)
        case "updateSendPanelDevices":
            guard let args = call.arguments as? [String: Any],
                  let devices = args["devices"] as? [[String: Any]] else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Expected send panel devices", details: nil))
                return
            }
            sendPanelController?.onAction = { [weak self] action in
                self?.channel?.invokeMethod("sendPanelAction", arguments: action)
            }
            sendPanelController?.updateDevices(devices)
            result(nil)
        case "updateSendPanelStatus":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Expected send panel status", details: nil))
                return
            }
            sendPanelController?.updateStatus(args: args)
            result(nil)
        case "showSendPanelQr":
            guard let args = call.arguments as? [String: Any],
                  let url = args["url"] as? String else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Expected send panel QR URL", details: nil))
                return
            }
            sendPanelController?.showQr(url: url)
            result(nil)
        case "getLaunchAtLogin":
            result(LaunchAtLogin.isEnabled)
        case "setLaunchAtLogin":
            if let launchAtLogin = call.arguments as? Bool {
                LaunchAtLogin.isEnabled = launchAtLogin
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Expected a boolean value", details: nil))
            }
        case "getLaunchAtLoginMinimized":
            result(UserDefaults.standard.bool(forKey: "launchAtLoginMinimized"))
        case "setLaunchAtLoginMinimized":
            if let launchAtLoginMinimized = call.arguments as? Bool {
                UserDefaults.standard.set(launchAtLoginMinimized, forKey: "launchAtLoginMinimized")
                result(nil)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENT", message: "Expected a boolean value", details: nil))
            }
        case "isLaunchedAsLoginItem":
            result(isLaunchedAsLoginItem)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func showReceivePanel(args: [String: Any]) {
        if receivePanelController == nil {
            receivePanelController = ReceivePanelController()
        }
        receivePanelController?.onAction = { [weak self] action in
            self?.channel?.invokeMethod("receivePanelAction", arguments: action)
        }
        receivePanelController?.show(args: args)
    }
    
    private func saveDestinationFolderAccess(_ folderPath: String) throws {
        let folderURL = URL(fileURLWithPath: folderPath)
        let bookmarkData = try folderURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        Defaults[.destinationFolderBookmark] = bookmarkData
    }
    
    private func removeExistingDestinationAccess() {
        guard let existingBookmarkData = Defaults[.destinationFolderBookmark] else { return }
        if let url = SecurityScopedResourceManager.shared.startAccessing(bookmark: existingBookmarkData) {
            SecurityScopedResourceManager.shared.stopAccessing(url: url)
            Defaults[.destinationFolderBookmark] = nil
        }
    }
    
    private func restoreDestinationFolderAccess() {
        guard let bookmarkData = Defaults[.destinationFolderBookmark] else { return }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
            if !isStale {
                let _ = url.startAccessingSecurityScopedResource()
            }
        } catch {
            print("Failed to restore folder access: \(error)")
        }
    }
    
    override func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        /**
         Although file URLs shared via the dock icon or the "open with" file menu item already contain access permission, we pass this through the bookmark mechanism for uniformity and readability of the code with URLs shared from the share extension.
         - SeeAlso: [Enabling App Sandbox#Enabling User-Selected File Access](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html#//apple_ref/doc/uid/TP40011195-CH4-SW6)
         - SeeAlso: [``Shared/createBookmarkForFile(at:)``](x-source-tag://create-bookmark-func)
         */
        if let fileBookmark = createBookmarkForFile(at: URL(fileURLWithPath: filename)) {
            Defaults[.pendingFiles].append(fileBookmark)
        }
        return true
    }
    
    override func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames {
            if let fileBookmark = createBookmarkForFile(at: URL(fileURLWithPath: filename)) {
                Defaults[.pendingFiles].append(fileBookmark)
            }
        }
    }
    // END: handle opened files
    
    /// Handle **text** dropped onto the Dock icon
    @objc func handleOpenContentsEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        if let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue {
            Defaults[.pendingStrings].append(string)
        }
    }
}

final class SendPanelController {
    var onAction: (([String: Any]) -> Void)?
    
    private var panel: NSPanel?
    private let titleLabel = NSTextField(labelWithString: "TanDrop")
    private let detailLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let avatarView = NSImageView()
    private let previewView = NSImageView()
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let refreshButton = NSButton(title: "刷新设备", target: nil, action: nil)
    private let qrButton = NSButton(title: "二维码", target: nil, action: nil)
    private let deviceStack = NSStackView()
    private let progressIndicator = NSProgressIndicator()
    private let qrImageView = NSImageView()
    private let qrHintLabel = NSTextField(labelWithString: "扫码下载文件")
    private var filePaths: [String] = []
    
    func show(filePaths: [String], strings: [String]) {
        guard !filePaths.isEmpty || !strings.isEmpty else { return }
        self.filePaths = filePaths
        buildPanelIfNeeded()
        
        let itemCount = filePaths.count + strings.count
        let firstName = filePaths.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? strings.first ?? "文本"
        let totalSize = filePaths.reduce(Int64(0)) { partial, path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return partial + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        
        titleLabel.stringValue = "TanDrop"
        detailLabel.stringValue = itemCount == 1 ? "准备发送 1 个项目" : "准备发送 \(itemCount) 个项目"
        statusLabel.stringValue = filePaths.isEmpty ? firstName : "\(firstName) · \(Self.formatBytes(totalSize))"
        updatePreview(path: filePaths.first)
        showSearchingState()
        cancelButton.title = "取消"
        
        positionPanel()
        panel?.orderFrontRegardless()
    }
    
    func updateDevices(_ devices: [[String: Any]]) {
        buildPanelIfNeeded()
        deviceStack.arrangedSubviews.forEach { view in
            deviceStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        
        if devices.isEmpty {
            deviceStack.addArrangedSubview(makeHintLabel("正在搜索附近设备"))
        } else {
            for device in devices.prefix(4) {
                let alias = device["alias"] as? String ?? "未知设备"
                let ip = device["ip"] as? String ?? ""
                let model = device["model"] as? String ?? ""
                let row = NSButton(title: "\(alias)\n\(model)", target: self, action: #selector(selectDevice(_:)))
                row.identifier = NSUserInterfaceItemIdentifier(ip)
                row.bezelStyle = .shadowlessSquare
                row.isBordered = false
                row.font = .systemFont(ofSize: 12, weight: .medium)
                row.alignment = .center
                row.image = Self.deviceImage(model: model)
                row.imagePosition = .imageAbove
                row.toolTip = ip
                deviceStack.addArrangedSubview(row)
            }
        }
        
        positionPanel()
        panel?.orderFrontRegardless()
    }
    
    func updateStatus(args: [String: Any]) {
        let status = args["status"] as? String ?? ""
        let detail = args["detail"] as? String
        let progress = args["progress"] as? Double
        switch status {
        case "sending":
            titleLabel.stringValue = "TanDrop"
            detailLabel.stringValue = "正在发送"
            statusLabel.stringValue = detail ?? "正在建立连接"
            progressIndicator.isHidden = false
            progressIndicator.doubleValue = (progress ?? 0) * 100
            refreshButton.isHidden = true
            qrButton.isHidden = true
        case "completed":
            titleLabel.stringValue = "TanDrop 已完成"
            detailLabel.stringValue = "发送完成"
            statusLabel.stringValue = detail ?? "文件已发送"
            progressIndicator.isHidden = true
            cancelButton.title = "完成"
            refreshButton.isHidden = true
            qrButton.isHidden = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard self?.panel?.isVisible == true,
                      self?.cancelButton.title == "完成" else { return }
                self?.close()
            }
        case "failed":
            titleLabel.stringValue = "TanDrop 发送失败"
            detailLabel.stringValue = "发送失败"
            statusLabel.stringValue = detail ?? "请重试"
            progressIndicator.isHidden = true
            cancelButton.title = "关闭"
            refreshButton.isHidden = false
            qrButton.isHidden = false
        default:
            statusLabel.stringValue = detail ?? statusLabel.stringValue
        }
        panel?.orderFrontRegardless()
    }
    
    func close() {
        panel?.orderOut(nil)
        onAction?(["type": "close"])
    }
    
    private func buildPanelIfNeeded() {
        guard panel == nil else { return }
        
        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 258))
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        
        let content = NSVisualEffectView(frame: rootView.bounds)
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 18
        content.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(content)
        
        titleLabel.font = .systemFont(ofSize: 18, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        
        avatarView.image = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
        avatarView.contentTintColor = NSColor.systemBlue.withAlphaComponent(0.35)
        avatarView.imageScaling = .scaleProportionallyUpOrDown
        
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.wantsLayer = true
        previewView.layer?.cornerRadius = 7
        previewView.layer?.masksToBounds = true
        previewView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.28).cgColor
        
        closeButton.target = self
        closeButton.action = #selector(closePanel)
        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 13, weight: .bold)
        
        cancelButton.target = self
        cancelButton.action = #selector(closePanel)
        cancelButton.bezelStyle = .rounded
        cancelButton.font = .systemFont(ofSize: 13, weight: .semibold)

        refreshButton.target = self
        refreshButton.action = #selector(refreshDevices)
        refreshButton.bezelStyle = .rounded
        refreshButton.font = .systemFont(ofSize: 11, weight: .medium)

        qrButton.target = self
        qrButton.action = #selector(showDownloadQr)
        qrButton.bezelStyle = .rounded
        qrButton.font = .systemFont(ofSize: 11, weight: .medium)

        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.isIndeterminate = false
        progressIndicator.controlSize = .small
        progressIndicator.style = .bar
        progressIndicator.isHidden = true
        
        deviceStack.orientation = .horizontal
        deviceStack.alignment = .top
        deviceStack.distribution = .fillEqually
        deviceStack.spacing = 18

        qrImageView.imageScaling = .scaleProportionallyUpOrDown
        qrImageView.isHidden = true
        qrHintLabel.font = .systemFont(ofSize: 11, weight: .medium)
        qrHintLabel.textColor = .secondaryLabelColor
        qrHintLabel.alignment = .center
        qrHintLabel.isHidden = true
        
        let topSeparator = NSBox()
        topSeparator.boxType = .separator
        topSeparator.translatesAutoresizingMaskIntoConstraints = false
        let bottomSeparator = NSBox()
        bottomSeparator.boxType = .separator
        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false
        
        for view in [avatarView, previewView, titleLabel, detailLabel, statusLabel, closeButton, deviceStack, qrImageView, qrHintLabel, progressIndicator, refreshButton, qrButton, cancelButton, topSeparator, bottomSeparator] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            content.topAnchor.constraint(equalTo: rootView.topAnchor),
            content.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            
            closeButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            closeButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            closeButton.widthAnchor.constraint(equalToConstant: 17),
            closeButton.heightAnchor.constraint(equalToConstant: 17),
            
            avatarView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            avatarView.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            avatarView.widthAnchor.constraint(equalToConstant: 46),
            avatarView.heightAnchor.constraint(equalToConstant: 46),
            
            previewView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            previewView.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            previewView.widthAnchor.constraint(equalToConstant: 46),
            previewView.heightAnchor.constraint(equalToConstant: 46),
            
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 27),
            titleLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: previewView.leadingAnchor, constant: -12),
            
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            
            statusLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 3),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            
            topSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            topSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            topSeparator.topAnchor.constraint(equalTo: content.topAnchor, constant: 90),
            
            deviceStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            deviceStack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -26),
            deviceStack.topAnchor.constraint(equalTo: topSeparator.bottomAnchor, constant: 22),
            deviceStack.heightAnchor.constraint(equalToConstant: 88),

            qrImageView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            qrImageView.topAnchor.constraint(equalTo: topSeparator.bottomAnchor, constant: 6),
            qrImageView.widthAnchor.constraint(equalToConstant: 76),
            qrImageView.heightAnchor.constraint(equalToConstant: 76),
            qrHintLabel.topAnchor.constraint(equalTo: qrImageView.bottomAnchor, constant: 1),
            qrHintLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            
            bottomSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -54),

            progressIndicator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            progressIndicator.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -14),
            progressIndicator.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
            progressIndicator.heightAnchor.constraint(equalToConstant: 6),

            refreshButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            refreshButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            refreshButton.heightAnchor.constraint(equalToConstant: 26),
            qrButton.leadingAnchor.constraint(equalTo: refreshButton.trailingAnchor, constant: 6),
            qrButton.bottomAnchor.constraint(equalTo: refreshButton.bottomAnchor),
            qrButton.heightAnchor.constraint(equalToConstant: 26),
            
            cancelButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            cancelButton.widthAnchor.constraint(equalToConstant: 64),
            cancelButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        
        let panel = NSPanel(
            contentRect: rootView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = rootView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.isMovableByWindowBackground = true
        self.panel = panel
    }
    
    private func updatePreview(path: String?) {
        guard let path else {
            previewView.image = NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil)
            previewView.contentTintColor = .secondaryLabelColor
            previewView.imageScaling = .scaleProportionallyUpOrDown
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: 92, height: 92),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let thumbnail {
                    self.previewView.image = thumbnail.nsImage
                    self.previewView.contentTintColor = nil
                    self.previewView.imageScaling = .scaleAxesIndependently
                } else {
                    self.previewView.image = NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil)
                    self.previewView.contentTintColor = .secondaryLabelColor
                    self.previewView.imageScaling = .scaleProportionallyUpOrDown
                }
            }
        }
    }
    
    private func positionPanel() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let frame = NSRect(
            x: visible.midX - panel.frame.width / 2,
            y: visible.midY - panel.frame.height / 2,
            width: panel.frame.width,
            height: panel.frame.height
        )
        panel.setFrame(frame, display: true)
    }
    
    @objc private func closePanel() {
        close()
    }

    @objc private func refreshDevices() {
        showSearchingState()
        onAction?(["type": "refresh"])
    }

    @objc private func showDownloadQr() {
        onAction?(["type": "downloadQr"])
    }
    
    @objc private func selectDevice(_ sender: NSButton) {
        guard let ip = sender.identifier?.rawValue else { return }
        updateStatus(args: ["status": "sending", "detail": "发送到 \(sender.title)"])
        onAction?(["type": "send", "ip": ip])
    }
    
    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    
    private func showSearchingState() {
        progressIndicator.isHidden = true
        progressIndicator.doubleValue = 0
        refreshButton.isHidden = false
        qrButton.isHidden = false
        deviceStack.isHidden = false
        qrImageView.isHidden = true
        qrHintLabel.isHidden = true
        deviceStack.arrangedSubviews.forEach { view in
            deviceStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        deviceStack.addArrangedSubview(makeHintLabel("正在搜索附近设备"))
    }

    func showQr(url: String) {
        guard let data = url.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let representation = NSCIImageRep(ciImage: scaled)
        let qrImage = NSImage(size: representation.size)
        qrImage.addRepresentation(representation)
        qrImageView.image = qrImage
        deviceStack.isHidden = true
        qrImageView.isHidden = false
        qrHintLabel.isHidden = false
        detailLabel.stringValue = "扫码下载"
        statusLabel.stringValue = "同一 Wi‑Fi 下可直接在浏览器下载"
        panel?.orderFrontRegardless()
    }
    
    private func makeHintLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        return label
    }
    
    private static func deviceImage(model: String) -> NSImage? {
        let lower = model.lowercased()
        let symbol = lower.contains("iphone") || lower.contains("android") || lower.contains("phone")
            ? "iphone"
            : "desktopcomputer"
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }
}

final class ReceivePanelController {
    var onAction: ((String) -> Void)?
    
    private var panel: NSPanel?
    private let titleLabel = NSTextField(labelWithString: "接收文件")
    private let detailLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let avatarView = NSImageView()
    private let previewView = NSImageView()
    private let closeButton = NSButton(title: "×", target: nil, action: nil)
    private let acceptButton = NSButton(title: "接收", target: nil, action: nil)
    private let declineButton = NSButton(title: "拒绝", target: nil, action: nil)
    private let openButton = NSButton(title: "打开", target: nil, action: nil)
    private let revealButton = NSButton(title: "在访达中显示", target: nil, action: nil)
    private var openPath: String?
    private var folderPath: String?
    private var didFinish = false
    
    func show(args: [String: Any]) {
        let senderAlias = args["senderAlias"] as? String ?? "未知设备"
        let fileName = args["fileName"] as? String ?? "文件"
        let fileCount = args["fileCount"] as? Int ?? 1
        let totalSize = args["totalSize"] as? Int ?? 0
        
        buildPanelIfNeeded()
        titleLabel.stringValue = senderAlias
        detailLabel.stringValue = "想发送 \(fileCount) 个项目"
        statusLabel.stringValue = "\(fileName) · \(Self.formatBytes(totalSize))"
        progress.doubleValue = 0
        progress.isHidden = true
        closeButton.isHidden = false
        didFinish = false
        previewView.image = NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil)
        previewView.contentTintColor = .secondaryLabelColor
        previewView.imageScaling = .scaleProportionallyUpOrDown
        acceptButton.isHidden = false
        declineButton.isHidden = false
        openButton.isHidden = true
        revealButton.isHidden = true
        
        positionPanel()
        panel?.orderFrontRegardless()
    }
    
    func update(args: [String: Any]) {
        buildPanelIfNeeded()
        let status = args["status"] as? String ?? "progress"
        let value = args["progress"] as? Double ?? 0
        let currentFile = args["currentFile"] as? String
        
        progress.isHidden = false
        closeButton.isHidden = false
        progress.doubleValue = max(0, min(1, value)) * 100
        acceptButton.isHidden = true
        declineButton.isHidden = true
        
        switch status {
        case "receiving":
            titleLabel.stringValue = "正在接收"
            statusLabel.stringValue = "\(Int(progress.doubleValue))%"
            if let currentFile {
                detailLabel.stringValue = currentFile
            }
        case "completed":
            titleLabel.stringValue = "接收完成"
            detailLabel.stringValue = "文件已保存"
            statusLabel.stringValue = ""
            progress.doubleValue = 100
            progress.isHidden = true
            closeButton.isHidden = false
            didFinish = true
            openPath = args["openPath"] as? String
            folderPath = args["folderPath"] as? String
            if let openPath, let image = NSImage(contentsOfFile: openPath) {
                previewView.image = image
                previewView.contentTintColor = nil
                previewView.imageScaling = .scaleAxesIndependently
            }
            openButton.isHidden = openPath == nil
            revealButton.isHidden = folderPath == nil
        case "failed":
            titleLabel.stringValue = "接收失败"
            statusLabel.stringValue = "请检查发送方或保存位置"
        default:
            break
        }
        
        positionPanel()
        panel?.orderFrontRegardless()
    }
    
    func close() {
        panel?.orderOut(nil)
    }
    
    private func buildPanelIfNeeded() {
        guard panel == nil else { return }
        
        let rootView = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 98))
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        
        let content = NSVisualEffectView(frame: rootView.bounds)
        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 17
        content.layer?.masksToBounds = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(content)
        
        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        detailLabel.textColor = .labelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = .systemFont(ofSize: 9)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        
        progress.minValue = 0
        progress.maxValue = 100
        progress.isIndeterminate = false
        progress.controlSize = .small
        progress.style = .bar
        
        avatarView.image = NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil)
        avatarView.contentTintColor = NSColor.systemBlue.withAlphaComponent(0.35)
        avatarView.imageScaling = .scaleProportionallyUpOrDown
        
        previewView.image = NSImage(systemSymbolName: "doc.fill", accessibilityDescription: nil)
        previewView.contentTintColor = .secondaryLabelColor
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.wantsLayer = true
        previewView.layer?.cornerRadius = 9
        previewView.layer?.masksToBounds = true
        previewView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.28).cgColor
        
        closeButton.target = self
        closeButton.action = #selector(closePanel)
        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 13, weight: .bold)
        
        acceptButton.target = self
        acceptButton.action = #selector(accept)
        acceptButton.bezelStyle = .regularSquare
        acceptButton.font = .systemFont(ofSize: 10, weight: .semibold)
        declineButton.target = self
        declineButton.action = #selector(decline)
        declineButton.bezelStyle = .regularSquare
        declineButton.font = .systemFont(ofSize: 10, weight: .semibold)
        openButton.target = self
        openButton.action = #selector(openFile)
        openButton.bezelStyle = .regularSquare
        openButton.font = .systemFont(ofSize: 10, weight: .semibold)
        revealButton.target = self
        revealButton.action = #selector(openFolder)
        revealButton.bezelStyle = .regularSquare
        revealButton.font = .systemFont(ofSize: 10, weight: .semibold)
        
        for view in [avatarView, previewView, titleLabel, detailLabel, statusLabel, progress, closeButton, acceptButton, declineButton, openButton, revealButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            content.topAnchor.constraint(equalTo: rootView.topAnchor),
            content.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            
            avatarView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 15),
            avatarView.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            avatarView.widthAnchor.constraint(equalToConstant: 36),
            avatarView.heightAnchor.constraint(equalToConstant: 36),
            
            previewView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -21),
            previewView.topAnchor.constraint(equalTo: content.topAnchor, constant: 17),
            previewView.widthAnchor.constraint(equalToConstant: 36),
            previewView.heightAnchor.constraint(equalToConstant: 36),
            
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 11),
            titleLabel.trailingAnchor.constraint(equalTo: previewView.leadingAnchor, constant: -11),
            
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            
            statusLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 3),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            
            progress.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 15),
            progress.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -15),
            progress.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            
            closeButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            closeButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            closeButton.widthAnchor.constraint(equalToConstant: 17),
            closeButton.heightAnchor.constraint(equalToConstant: 17),
            
            declineButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 82),
            declineButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -9),
            declineButton.widthAnchor.constraint(equalToConstant: 80),
            declineButton.heightAnchor.constraint(equalToConstant: 22),
            acceptButton.leadingAnchor.constraint(equalTo: declineButton.trailingAnchor, constant: 36),
            acceptButton.bottomAnchor.constraint(equalTo: declineButton.bottomAnchor),
            acceptButton.widthAnchor.constraint(equalTo: declineButton.widthAnchor),
            acceptButton.heightAnchor.constraint(equalTo: declineButton.heightAnchor),
            
            revealButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 82),
            revealButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -9),
            revealButton.widthAnchor.constraint(equalToConstant: 80),
            revealButton.heightAnchor.constraint(equalToConstant: 22),
            openButton.leadingAnchor.constraint(equalTo: revealButton.trailingAnchor, constant: 36),
            openButton.bottomAnchor.constraint(equalTo: revealButton.bottomAnchor),
            openButton.widthAnchor.constraint(equalTo: revealButton.widthAnchor),
            openButton.heightAnchor.constraint(equalTo: revealButton.heightAnchor),
        ])
        
        let panel = NSPanel(
            contentRect: rootView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = rootView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        self.panel = panel
    }
    
    private func positionPanel() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let frame = NSRect(
            x: visible.maxX - panel.frame.width - 18,
            y: visible.maxY - panel.frame.height - 18,
            width: panel.frame.width,
            height: panel.frame.height
        )
        panel.setFrame(frame, display: true)
    }
    
    @objc private func accept() {
        onAction?("accept")
    }
    
    @objc private func decline() {
        onAction?("decline")
        close()
    }
    
    @objc private func closePanel() {
        if !didFinish {
            onAction?("cancel")
        }
        close()
    }
    
    @objc private func openFile() {
        if let openPath {
            NSWorkspace.shared.open(URL(fileURLWithPath: openPath))
        }
    }
    
    @objc private func openFolder() {
        if let folderPath {
            NSWorkspace.shared.open(URL(fileURLWithPath: folderPath))
        }
    }
    
    private static func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
