import AppKit
import CoreMedia
import Darwin
import Foundation
import ScreenCaptureKit

/// Which apps' sound goes to the stream.
enum AudioMode: String, CaseIterable {
    case games          // CrossOver/Wine games, Warcraft III + apps picked in the menu
    case allExceptChat  // everything except Discord, messengers, notifications
    case off

    var title: String {
        switch self {
        case .games: return L("Только игры (CrossOver, Warcraft III + отмеченные)", "Games only (CrossOver, Warcraft III + picked apps)")
        case .allExceptChat: return L("Всё, кроме Discord, мессенджеров и уведомлений", "Everything except Discord, messengers and notifications")
        case .off: return L("Выключен", "Off")
        }
    }
}

/// Captures application audio with ScreenCaptureKit in its own SCStream (so the
/// video capture keeps showing every window) and re-checks the app list every
/// 2 seconds, so a game started mid-session is picked up.
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "audio.capture", qos: .userInteractive)
    /// Called on `queue` with 48 kHz float PCM sample buffers.
    var onSamples: ((CMSampleBuffer) -> Void)?

    /// Names of the apps currently captured (main queue).
    private(set) var capturedNames: [String] = []

    private var stream: SCStream?
    private var filterKey: String?
    private var timer: Timer?
    private var running = false
    private var refreshing = false
    private var refreshStarted = CFAbsoluteTime(0)

    // MARK: Lifecycle (main queue)

    func start() {
        guard !running else { return }
        running = true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        capturedNames = []
        filterKey = nil
        if let s = stream {
            stream = nil
            Task { try? await s.stopCapture() }
            Log.info("audio capture stopped")
        }
    }

    /// Re-evaluate which apps to capture (e.g. after a menu change).
    func refresh() {
        guard running else { return }
        if refreshing {
            if CFAbsoluteTimeGetCurrent() - refreshStarted > 10 {
                Log.info("audio capture: previous refresh is stuck for >10s")
            }
            return
        }
        refreshStarted = CFAbsoluteTimeGetCurrent()
        refreshing = true
        Task { @MainActor in
            defer { refreshing = false }
            do { try await apply() } catch { Log.info("audio capture: \(error.localizedDescription)") }
        }
    }

    @MainActor
    private func apply() async throws {
        let mode = AudioMode(rawValue: Settings.shared.audioMode) ?? .games
        guard mode != .off else {
            stopStream(reason: "audio off")
            capturedNames = []
            return
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard running else { return }
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { return }
        let me = getpid()

        let filter: SCContentFilter
        let key: String
        let names: [String]
        switch mode {
        case .games:
            // SCShareableContent does not always list fullscreen games (seen with
            // Roblox), so "include only the game" can miss it. Instead: detect
            // running games via NSWorkspace and exclude every listed non-game app.
            let extra = Set(Settings.shared.audioExtraApps)
            let games = NSWorkspace.shared.runningApplications.filter {
                Self.isGame(bundle: $0.bundleIdentifier ?? "", name: $0.localizedName ?? "", pid: $0.processIdentifier)
                    || extra.contains($0.bundleIdentifier ?? "")
            }
            if games.isEmpty {
                stopStream(reason: "no game running")
                capturedNames = []
                return
            }
            let gamePIDs = Set(games.map { $0.processIdentifier })
            let excluded = content.applications.filter {
                $0.processID == me
                    || (!gamePIDs.contains($0.processID) && !extra.contains($0.bundleIdentifier) && !Self.isGame($0))
            }
            filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            key = "gx:" + excluded.map { String($0.processID) }.sorted().joined(separator: ",")
                + "|" + gamePIDs.map { String($0) }.sorted().joined(separator: ",")
            names = games.map { $0.localizedName ?? $0.bundleIdentifier ?? "pid \($0.processIdentifier)" }
        case .allExceptChat:
            let excluded = content.applications.filter { Self.isChat($0) || $0.processID == me }
            filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            key = "ex:" + excluded.map { String($0.processID) }.sorted().joined(separator: ",")
            names = [L("всё, кроме: ", "all except: ") + (excluded.isEmpty ? "—" : excluded.map { Self.displayName($0) }.joined(separator: ", "))]
        case .off:
            return
        }

        if key == filterKey, stream != nil { return }
        if let s = stream {
            try await s.updateContentFilter(filter)
        } else {
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.sampleRate = 48_000
            cfg.channelCount = 2
            cfg.excludesCurrentProcessAudio = true
            // Video is handled by the main capture; keep this stream's video minimal.
            cfg.width = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            cfg.showsCursor = false
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            stream = s
        }
        filterKey = key
        capturedNames = names
        Log.info("audio capture: \(names.joined(separator: ", "))")
    }

    @MainActor
    private func stopStream(reason: String) {
        guard let s = stream else { return }
        stream = nil
        filterKey = nil
        Task { try? await s.stopCapture() }
        Log.info("audio capture paused: \(reason)")
    }

    // MARK: SCStreamOutput / Delegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid else { return }
        onSamples?(sb)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("audio stream stopped with error: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.filterKey = nil
        }
    }

    // MARK: App classification

    static func executablePath(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }

    static func displayName(_ app: SCRunningApplication) -> String {
        app.applicationName.isEmpty ? (app.bundleIdentifier.isEmpty ? "pid \(app.processID)" : app.bundleIdentifier) : app.applicationName
    }

    static func isGame(_ app: SCRunningApplication) -> Bool {
        isGame(bundle: app.bundleIdentifier, name: app.applicationName, pid: app.processID)
    }

    /// Windows games under CrossOver/Wine and the native Warcraft III.
    static func isGame(bundle rawBundle: String, name rawName: String, pid: pid_t) -> Bool {
        let bundle = rawBundle.lowercased()
        if bundle == "com.codeweavers.crossover" { return false } // CrossOver's own UI
        let name = rawName.lowercased()
        let path = executablePath(pid).lowercased()
        if path.contains("crossover") || path.contains("/wine") || bundle.contains("winehq") || bundle.contains("codeweavers") {
            return true
        }
        if name.hasSuffix(".exe") { return true }
        if path.contains("warcraft iii") || name.contains("warcraft") || name.contains("trackmania") { return true }
        return false
    }

    static let chatBundles: Set<String> = [
        "com.hnc.discord", "com.hnc.discordptb", "com.hnc.discordcanary",
        "ru.keepcoder.telegram", "org.telegram.desktop", "com.tdesktop.telegram",
        "net.whatsapp.whatsapp", "com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams",
        "us.zoom.xos", "com.skype.skype", "com.apple.facetime", "com.apple.mobilesms",
        "com.apple.notificationcenterui", "com.apple.usernotificationcenter", "com.apple.mail",
    ]

    static func isChat(_ app: SCRunningApplication) -> Bool {
        chatBundles.contains(app.bundleIdentifier.lowercased()) || app.applicationName.lowercased().contains("discord")
    }
}
