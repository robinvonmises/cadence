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
}

enum Defaults {
    static var ownerName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? "Ich"
    }

    static let consentMessage = """
    Kurzer Hinweis: Ich würde dieses Gespräch gern lokal auf meinem Rechner aufzeichnen und \
    transkribieren, damit ich ein sauberes Protokoll erstellen kann. Die Aufnahme verlässt meinen \
    Rechner nicht. Ist das für alle in Ordnung?
    """

    static func register() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.ownerName: ownerName,
            SettingsKey.ownPartyName: "Wir",
            SettingsKey.otherPartyName: "Kunde",
            SettingsKey.model: WhisperModelOption.largeTurbo.rawValue,
            SettingsKey.language: "de",
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
        case .german: return "Deutsch"
        case .english: return "Englisch"
        case .auto: return "Automatisch erkennen"
        }
    }

    /// Wert für WhisperKit (`nil` = automatische Erkennung).
    var whisperCode: String? { self == .auto ? nil : rawValue }
}
