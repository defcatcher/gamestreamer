import Foundation

/// Persistent settings (UserDefaults, domain local.gamestreamer.host).
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var pin: String {
        get {
            if let p = d.string(forKey: "pin"), p.count == 6 { return p }
            let p = Settings.newPIN()
            d.set(p, forKey: "pin")
            return p
        }
        set { d.set(newValue, forKey: "pin") }
    }

    var bitrateKbps: Int {
        get { let v = d.integer(forKey: "bitrateKbps"); return v > 0 ? v : 25_000 }
        set { d.set(newValue, forKey: "bitrateKbps") }
    }

    var port: Int {
        let v = d.integer(forKey: "port")
        return v > 0 ? v : 8765
    }

    /// Capture/encode frame rate: 60 or 120.
    var fps: Int {
        get { let v = d.integer(forKey: "fps"); return v > 0 ? v : 60 }
        set { d.set(newValue, forKey: "fps") }
    }

    /// AudioMode raw value.
    var audioMode: String {
        get { d.string(forKey: "audioMode") ?? AudioMode.games.rawValue }
        set { d.set(newValue, forKey: "audioMode") }
    }

    /// Extra bundle IDs whose sound is captured in "games" mode.
    var audioExtraApps: [String] {
        get { d.stringArray(forKey: "audioExtraApps") ?? [] }
        set { d.set(newValue, forKey: "audioExtraApps") }
    }

    static func newPIN() -> String {
        String(format: "%06d", Int.random(in: 0..<1_000_000))
    }
}

/// UI language: Russian if it is the user's preferred language, English otherwise.
let uiIsRussian = Locale.preferredLanguages.first?.hasPrefix("ru") ?? false
func L(_ ru: String, _ en: String) -> String { uiIsRussian ? ru : en }
