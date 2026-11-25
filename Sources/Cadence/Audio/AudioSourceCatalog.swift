import AppKit
import CoreAudio
import Foundation

/// Was als „Gegenseite“ aufgenommen wird.
enum SystemAudioTarget: Hashable, Codable {
    /// Gesamter Systemton (außer Cadence selbst). Funktioniert mit jeder App.
    case allSystemAudio
    /// Nur eine bestimmte App inkl. ihrer Hilfsprozesse (z. B. Teams-WebView, Chrome-Renderer).
    case app(bundleID: String, name: String)

    var label: String {
        switch self {
        case .allSystemAudio: return "Gesamter Systemton"
        case .app(_, let name): return name
        }
    }
}

struct MeetingApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let icon: NSImage?
    let isKnownMeetingApp: Bool
    var id: String { bundleID }
}

enum AudioSourceCatalog {
    /// Bekannte Meeting-Apps werden oben einsortiert.
    static let knownMeetingBundlePrefixes: [String: String] = [
        "com.microsoft.teams": "Microsoft Teams",
        "com.microsoft.teams2": "Microsoft Teams",
        "us.zoom.xos": "Zoom",
        "com.cisco.webexmeetingsapp": "Webex",
        "Cisco-Systems.Spark": "Webex",
        "com.google.Chrome": "Google Chrome (Meet)",
        "com.apple.Safari": "Safari",
        "org.mozilla.firefox": "Firefox",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.apple.FaceTime": "FaceTime",
        "com.hnc.Discord": "Discord",
        "com.tinyspeck.slackmacgap": "Slack",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.skype.skype": "Skype",
        "com.gotomeeting.GoToMeeting": "GoTo Meeting"
    ]

    /// Laufende Apps mit Fenster, Meeting-Apps zuerst.
    static func runningApps() -> [MeetingApp] {
        let ownBundle = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> MeetingApp? in
                guard let bundleID = app.bundleIdentifier, bundleID != ownBundle else { return nil }
                let known = knownMeetingBundlePrefixes.keys.contains { bundleID.hasPrefix($0) }
                return MeetingApp(
                    bundleID: bundleID,
                    name: app.localizedName ?? bundleID,
                    icon: app.icon,
                    isKnownMeetingApp: known
                )
            }
        let unique = Dictionary(apps.map { ($0.bundleID, $0) }, uniquingKeysWith: { a, _ in a }).values
        return unique.sorted {
            if $0.isKnownMeetingApp != $1.isKnownMeetingApp { return $0.isKnownMeetingApp }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Alle Core-Audio-Prozessobjekte, deren Bundle-ID mit der App beginnt (inkl. Helfer).
    static func audioProcessObjects(forBundlePrefix prefix: String) -> [AudioObjectID] {
        guard let objects = try? AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList) else { return [] }
        var result: [AudioObjectID] = []
        for object in objects {
            if let bundleID = try? object.readString(kAudioProcessPropertyBundleID), bundleID.hasPrefix(prefix) {
                result.append(object)
            }
        }
        // Rückfall: Haupt-PID übersetzen, falls die Bundle-ID-Abfrage nichts liefert.
        if result.isEmpty {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: prefix) {
                if let object = AudioObjectID.processObject(for: app.processIdentifier) { result.append(object) }
            }
        }
        return result
    }

    /// Prozessobjekt von Cadence selbst, damit eigene Töne nie mitgeschnitten werden.
    static func ownProcessObject() -> AudioObjectID? {
        AudioObjectID.processObject(for: ProcessInfo.processInfo.processIdentifier)
    }
}
