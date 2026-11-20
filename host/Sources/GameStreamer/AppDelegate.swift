import AppKit
import CoreGraphics
import Darwin
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let bridge = HelperBridge()
    private lazy var controller = StreamController(bridge: bridge)
    private let input = InputInjector()

    private var clientConnected = false
    private var clientAddress = ""
    private var lastStats: [String: Any] = [:]

    private let bitrateChoices = [5, 10, 15, 20, 25, 30, 40, 50] // Mbit/s

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        Log.info("GameStreamer starting (pid \(getpid()))")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        controller.useTestPattern = CommandLine.arguments.contains("--test-pattern")
        controller.onStats = { [weak self] st in self?.lastStats = st }

        bridge.onEvent = { [weak self] ev in self?.handle(ev) }
        bridge.onInput = { [input] data in input.handle(data) }
        input.onCursorCaptured = { [weak self] captured in
            self?.bridge.sendToClient(["t": "cursor", "captured": captured])
        }
        input.onModeChange = { [weak self] mode in
            Log.info("client mouse mode: \(mode == 1 ? "camera (relative)" : "menu (absolute)")")
            self?.controller.setShowsCursor(mode == 1)
        }
        bridge.start()

        if !InputInjector.hasPermission {
            Log.info("no Device Control (Accessibility) permission yet, requesting")
            InputInjector.requestPermission()
        }

        if !controller.useTestPattern && !CGPreflightScreenCaptureAccess() {
            Log.info("no Screen Recording permission yet, requesting")
            CGRequestScreenCaptureAccess()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stopSession()
        bridge.stop()
    }

    // MARK: Helper events

    private func handle(_ ev: [String: Any]) {
        guard let t = ev["t"] as? String else { return }
        switch t {
        case "ready":
            Log.info("helper ready: \(ev["listen"] ?? "")")
        case "connected":
            clientConnected = true
            clientAddress = (ev["remote"] as? String) ?? ""
            Log.info("client connected \(clientAddress)")
            input.releaseAll()
            controller.startSession()
        case "disconnected":
            if clientConnected { Log.info("client disconnected") }
            clientConnected = false
            input.releaseAll()
            controller.stopSession()
        case "keyframe":
            controller.requestKeyframe()
        case "bitrate":
            if let kbps = ev["kbps"] as? Int { controller.setBitrate(kbps: kbps) }
        default:
            Log.info("helper event: \(ev)")
        }
        updateIcon()
    }

    private func updateIcon() {
        let name = clientConnected ? "gamecontroller.fill" : "gamecontroller"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "GameStreamer")
        img?.isTemplate = true
        statusItem.button?.image = img
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status: String
        if clientConnected {
            let fps = lastStats["encFps"] as? Int ?? 0
            let kbps = lastStats["kbps"] as? Int ?? 0
            status = String(format: L("Подключена · %d fps · %.1f Мбит/с", "Connected · %d fps · %.1f Mbit/s"), fps, Double(kbps) / 1000)
        } else {
            status = L("Ожидание подключения", "Waiting for a viewer")
        }
        menu.addItem(disabled(status))
        if let err = lastStats["err"] as? String { menu.addItem(disabled("⚠︎ \(err)")) }
        if controller.useTestPattern { menu.addItem(disabled(L("Режим тестовой картинки", "Test pattern mode"))) }
        menu.addItem(.separator())

        menu.addItem(disabled("PIN: \(Settings.shared.pin)"))
        menu.addItem(item(L("Новый PIN", "New PIN"), #selector(newPIN)))

        let br = NSMenuItem(title: L("Битрейт", "Bitrate") + ": \(Settings.shared.bitrateKbps / 1000) " + L("Мбит/с", "Mbit/s"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for mbps in bitrateChoices {
            let it = item("\(mbps) " + L("Мбит/с", "Mbit/s"), #selector(pickBitrate(_:)))
            it.tag = mbps * 1000
            it.state = Settings.shared.bitrateKbps == mbps * 1000 ? .on : .off
            sub.addItem(it)
        }
        br.submenu = sub
        menu.addItem(br)
        let fpsItem = NSMenuItem(title: L("Частота", "Frame rate") + ": \(Settings.shared.fps) fps", action: nil, keyEquivalent: "")
        let fpsMenu = NSMenu()
        for f in [60, 120] {
            let it = item(f == 120 ? L("120 — свежее кадр, больше трафика", "120 — fresher frames, more bandwidth") : "60", #selector(pickFPS(_:)))
            it.tag = f
            it.state = Settings.shared.fps == f ? .on : .off
            fpsMenu.addItem(it)
        }
        fpsItem.submenu = fpsMenu
        menu.addItem(fpsItem)
        menu.addItem(audioMenuItem())
        menu.addItem(.separator())

        menu.addItem(item(L("Открыть клиент на этом Маке", "Open the client on this Mac"), #selector(openLocal)))
        let ts = tailscaleIPv4()
        let remote = item(ts.map { L("Скопировать адрес", "Copy address") + ": http://\($0):\(Settings.shared.port)" } ?? L("Tailscale не найден", "Tailscale not found"),
                          #selector(copyRemoteURL))
        remote.isEnabled = ts != nil
        menu.addItem(remote)
        menu.addItem(.separator())

        let screenOK = CGPreflightScreenCaptureAccess()
        menu.addItem(item(screenOK ? L("✓ Запись экрана разрешена", "✓ Screen Recording allowed") : L("✗ Запись экрана: выдать разрешение…", "✗ Screen Recording: grant permission…"),
                          #selector(openScreenRecordingSettings)))
        let inputOK = InputInjector.hasPermission
        menu.addItem(item(inputOK ? L("✓ Управление мышью и клавиатурой разрешено", "✓ Mouse & keyboard control allowed") : L("✗ Управление мышью и клавиатурой: выдать разрешение…", "✗ Mouse & keyboard control: grant permission…"),
                          #selector(openAccessibilitySettings)))
        let login = item(L("Запускать при входе в систему", "Launch at login"), #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item(L("Показать лог", "Show log"), #selector(showLog)))
        menu.addItem(.separator())
        menu.addItem(item(L("Выйти", "Quit"), #selector(quit), key: "q"))
    }

    private func audioMenuItem() -> NSMenuItem {
        let mode = AudioMode(rawValue: Settings.shared.audioMode) ?? .games
        let root = NSMenuItem(title: L("Звук", "Audio") + ": " + (mode == .off ? L("выключен", "off") : mode == .games ? L("только игры", "games only") : L("всё, кроме чатов", "all but chats")),
                              action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for m in AudioMode.allCases {
            let it = item(m.title, #selector(pickAudioMode(_:)))
            it.representedObject = m.rawValue
            it.state = m == mode ? .on : .off
            sub.addItem(it)
        }
        sub.addItem(.separator())
        if clientConnected {
            let names = controller.audioCapture.capturedNames
            sub.addItem(disabled(L("Сейчас", "Now") + ": " + (names.isEmpty ? L("ничего (игра не запущена)", "nothing (no game running)") : names.joined(separator: ", "))))
        } else {
            sub.addItem(disabled(L("Захват звука включится при подключении", "Audio capture starts when a viewer connects")))
        }
        sub.addItem(.separator())
        sub.addItem(disabled(L("Добавить к играм:", "Also treat as games:")))
        let extra = Set(Settings.shared.audioExtraApps)
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.processIdentifier != getpid() }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        var seen = Set<String>()
        for app in apps {
            guard let bid = app.bundleIdentifier, seen.insert(bid).inserted else { continue }
            let it = item("    " + (app.localizedName ?? bid), #selector(toggleAudioApp(_:)))
            it.representedObject = bid
            it.state = extra.contains(bid) ? .on : .off
            sub.addItem(it)
        }
        // Keep apps that were picked earlier but are not running now.
        for bid in extra.subtracting(seen).sorted() {
            let it = item("    " + bid, #selector(toggleAudioApp(_:)))
            it.representedObject = bid
            it.state = .on
            sub.addItem(it)
        }
        root.submenu = sub
        return root
    }

    @objc private func pickAudioMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        Settings.shared.audioMode = raw
        Log.info("audio mode -> \(raw)")
        controller.audioCapture.refresh()
    }

    @objc private func toggleAudioApp(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        var extra = Settings.shared.audioExtraApps
        if let i = extra.firstIndex(of: bid) { extra.remove(at: i) } else { extra.append(bid) }
        Settings.shared.audioExtraApps = extra
        Log.info("audio extra apps -> \(extra)")
        controller.audioCapture.refresh()
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    @objc private func newPIN() {
        Settings.shared.pin = Settings.newPIN()
        bridge.sendConfig()
        Log.info("PIN regenerated")
    }

    @objc private func pickFPS(_ sender: NSMenuItem) {
        controller.setFPS(sender.tag)
    }

    @objc private func pickBitrate(_ sender: NSMenuItem) {
        controller.setBitrate(kbps: sender.tag)
    }

    @objc private func openLocal() {
        NSWorkspace.shared.open(URL(string: "http://localhost:\(Settings.shared.port)/")!)
    }

    @objc private func copyRemoteURL() {
        guard let ip = tailscaleIPv4() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://\(ip):\(Settings.shared.port)/", forType: .string)
    }

    @objc private func openScreenRecordingSettings() {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func openAccessibilitySettings() {
        InputInjector.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLoginItem() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
                Log.info("login item disabled")
            } else {
                try svc.register()
                Log.info("login item enabled (status \(svc.status.rawValue))")
                if svc.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            Log.info("login item change failed: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = L("Не удалось изменить автозапуск", "Could not change launch at login")
            alert.informativeText = "\(error.localizedDescription)\n\n" + L("Приложение должно лежать в папке «Программы».", "The app must be in the Applications folder.")
            alert.runModal()
        }
    }

    @objc private func showLog() {
        NSWorkspace.shared.open(Log.url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// First IPv4 address in Tailscale's 100.64.0.0/10 range, if any.
func tailscaleIPv4() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    var p: UnsafeMutablePointer<ifaddrs>? = first
    while let cur = p {
        defer { p = cur.pointee.ifa_next }
        guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
        let host = UInt32(bigEndian: addr)
        if host & 0xFFC0_0000 == 0x6440_0000 { // 100.64.0.0/10
            return "\(host >> 24).\((host >> 16) & 0xFF).\((host >> 8) & 0xFF).\(host & 0xFF)"
        }
    }
    return nil
}
