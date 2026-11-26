import Foundation

enum SettingsKey {
    static let ownerName = "ownerName"
    static let ownPartyName = "ownPartyName"
    static let otherPartyName = "otherPartyName"
    static let model = "whisperModel"
    static let language = "language"
    static let storagePath = "storagePath"
    static let saveAudio = "saveAudio"
    static let voiceProcessing = "voiceProcessing"
    static let consentReminder = "consentReminder"
    static let runDiarization = "runDiarization"
    static let globalHotkeys = "globalHotkeys"
    static let consentMessage = "consentMessage"
    static let voiceRecognition = "voiceRecognition"
    static let autoSummary = "autoSummary"
    static let liveDiarization = "liveDiarization"
    static let interfaceLanguage = "interfaceLanguage"
    static let recordMicrophone = "recordMicrophone"
    /// Nach dem Gespräch die ganzen Aufnahmen noch einmal sorgfältig transkribieren.
    static let finalPass = "finalPass"
    /// UID des Eingangsgeräts; leer = Systemstandard.
    static let microphoneDevice = "microphoneDevice"
}

enum Defaults {
    static var ownerName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? String(localized: "Ich")
    }

    static var consentMessage: String {
        String(localized: "Kurzer Hinweis: Ich würde dieses Gespräch gern lokal auf meinem Rechner aufzeichnen und transkribieren, damit ich ein sauberes Protokoll erstellen kann. Die Aufnahme verlässt meinen Rechner nicht. Ist das für alle in Ordnung?")
    }

    static func register() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.ownerName: ownerName,
            SettingsKey.ownPartyName: String(localized: "Wir"),
            SettingsKey.otherPartyName: String(localized: "Kunde"),
            SettingsKey.model: WhisperModelOption.largeTurbo.rawValue,
            SettingsKey.language: "de",
            SettingsKey.recordMicrophone: true,
            SettingsKey.finalPass: true,
            SettingsKey.microphoneDevice: "",
            SettingsKey.storagePath: "",
            SettingsKey.saveAudio: true,
            SettingsKey.voiceProcessing: false,
            SettingsKey.consentReminder: true,
            SettingsKey.runDiarization: true,
            SettingsKey.globalHotkeys: true,
            SettingsKey.consentMessage: consentMessage,
            SettingsKey.voiceRecognition: true,
            SettingsKey.autoSummary: true,
            SettingsKey.liveDiarization: true
        ])
    }
}

enum LanguageOption: String, CaseIterable, Identifiable {
    case german = "de"
    case english = "en"
    case auto = "auto"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .german: return String(localized: "Deutsch")
        case .english: return String(localized: "Englisch")
        case .auto: return String(localized: "Automatisch erkennen")
        }
    }

    /// Wert für WhisperKit (`nil` = automatische Erkennung).
    var whisperCode: String? { self == .auto ? nil : rawValue }
}

/// Sprache der Oberfläche. „System“ folgt den macOS-Einstellungen; sonst setzt Cadence
/// `AppleLanguages` nur für sich selbst. Wirkt nach einem Neustart der App.
enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system, german, english

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return String(localized: "Wie das System")
        case .german: return "Deutsch"
        case .english: return "English"
        }
    }

    static var current: InterfaceLanguage {
        InterfaceLanguage(rawValue: UserDefaults.standard.string(forKey: SettingsKey.interfaceLanguage) ?? "") ?? .system
    }

    func apply() {
        let defaults = UserDefaults.standard
        defaults.set(rawValue, forKey: SettingsKey.interfaceLanguage)
        switch self {
        case .system: defaults.removeObject(forKey: "AppleLanguages")
        case .german: defaults.set(["de"], forKey: "AppleLanguages")
        case .english: defaults.set(["en"], forKey: "AppleLanguages")
        }
    }

    /// Sprache, in der die App gerade tatsächlich läuft.
    static var running: String { Bundle.main.preferredLocalizations.first ?? "de" }
}
