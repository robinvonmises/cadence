import AppKit
import CadenceCore
import SwiftUI

// MARK: - Theme

enum Theme {
    static let indigo = Color(red: 0.31, green: 0.27, blue: 0.90)
    static let violet = Color(red: 0.55, green: 0.36, blue: 0.96)
    static let pink = Color(red: 0.93, green: 0.28, blue: 0.60)
    static let accent = violet
    static let record = Color(red: 0.96, green: 0.26, blue: 0.36)

    static let gradient = LinearGradient(colors: [indigo, violet, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let recordGradient = LinearGradient(colors: [Color(red: 1, green: 0.42, blue: 0.42), record], startPoint: .top, endPoint: .bottom)

    static let corner: CGFloat = 14
}

extension View {
    /// Weiche Karte mit dezenter Kontur.
    func card(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }

    func sectionTitle() -> some View {
        self.font(.system(.subheadline, design: .rounded).weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }
}

extension PartyColor {
    var color: Color {
        switch self {
        case .blue: return Color(red: 0.25, green: 0.52, blue: 0.96)
        case .orange: return Color(red: 0.98, green: 0.55, blue: 0.20)
        case .green: return Color(red: 0.20, green: 0.74, blue: 0.48)
        case .purple: return Theme.violet
        case .pink: return Theme.pink
        case .teal: return Color(red: 0.10, green: 0.70, blue: 0.75)
        case .gray: return .gray
        }
    }
}

extension Session {
    func color(for personID: UUID?) -> Color {
        party(of: person(personID))?.color.color ?? .gray
    }
}

// MARK: - Bausteine

/// Rundes Avatar mit Initialen.
struct Avatar: View {
    let name: String
    let color: Color
    var size: CGFloat = 32

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }
}

/// Avatar-Knopf für „Wer spricht gerade?“
struct SpeakerButton: View {
    let name: String
    let color: Color
    let badge: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Avatar(name: name, color: color, size: 40)
                        .overlay(Circle().strokeBorder(isActive ? Theme.accent : .clear, lineWidth: 3).padding(-4))
                        .scaleEffect(isActive ? 1.06 : 1)
                    Text(badge)
                        .font(.system(size: 9, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.background, in: Capsule())
                        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
                        .offset(x: 6, y: -4)
                }
                Text(name)
                    .font(.caption.weight(isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: 70)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .animation(.spring(duration: 0.25), value: isActive)
        }
        .buttonStyle(.plain)
    }
}

/// Kleines farbiges Namensschild (für Menüs und Listen).
struct NameChip: View {
    let name: String
    let color: Color
    var badge: String?
    var highlighted = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).lineLimit(1)
            if let badge {
                Text(badge).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(highlighted ? 0.25 : 0.1), in: Capsule())
    }
}

/// Animierte Pegelanzeige aus fünf Balken.
struct LevelBars: View {
    let level: Float
    var color: Color = Theme.accent

    private let weights: [CGFloat] = [0.55, 0.8, 1.0, 0.75, 0.5]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .fill(color.opacity(level > 0.02 ? 1 : 0.35))
                    .frame(width: 3.5, height: 4 + 18 * CGFloat(min(1, level * 1.3)) * weights[index])
            }
        }
        .frame(height: 24)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

/// Hinweisleiste (Info, Warnung, Fehler).
struct Banner<Actions: View>: View {
    enum Kind { case info, warning, error }

    let kind: Kind
    let title: String
    var message: String?
    var progress: Double?
    @ViewBuilder var actions: () -> Actions

    private var color: Color {
        switch kind {
        case .info: return Theme.accent
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var icon: String {
        switch kind {
        case .info: return "arrow.down.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let progress {
                    ProgressView(value: progress).tint(color).frame(maxWidth: 260)
                }
            }
            Spacer(minLength: 8)
            actions()
        }
        .padding(12)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension Banner where Actions == EmptyView {
    init(kind: Kind, title: String, message: String? = nil, progress: Double? = nil) {
        self.init(kind: kind, title: title, message: message, progress: progress, actions: { EmptyView() })
    }
}

/// Zeigt den Zustand des Sprachmodells als Banner (oder nichts, wenn alles bereit ist).
struct ModelStatusBanner: View {
    @EnvironmentObject private var models: ModelManager
    var duringRecording = false

    var body: some View {
        switch models.status {
        case .downloading(let progress):
            Banner(
                kind: .info,
                title: "Sprachmodell wird geladen – \(Int(progress * 100)) %",
                message: duringRecording
                    ? "Einmaliger Download. Die Aufnahme läuft schon, das Transkript erscheint, sobald das Modell bereit ist."
                    : "Einmaliger Download von \(models.modelLabel). Danach funktioniert alles offline.",
                progress: progress
            )
        case .loading:
            Banner(kind: .info, title: "Sprachmodell wird vorbereitet …", message: "Beim ersten Start optimiert macOS das Modell für deinen Mac. Das kann ein paar Minuten dauern.", progress: nil)
        case .failed(let message):
            Banner(
                kind: .error,
                title: message,
                message: duringRecording
                    ? "Keine Sorge: Die Aufnahme läuft weiter und wird nach dem Beenden transkribiert."
                    : "Prüfe deine Internetverbindung und versuche es noch einmal."
            ) {
                HStack {
                    if let details = models.errorDetails {
                        Button("Details") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(details, forType: .string)
                        }
                        .help("Fehlerdetails in die Zwischenablage kopieren")
                    }
                    Button("Erneut versuchen") { models.reload() }
                        .buttonStyle(.borderedProminent)
                }
            }
        case .idle, .ready:
            EmptyView()
        }
    }
}

/// Öffnet die passenden Bereiche der Systemeinstellungen.
enum PrivacyPane {
    static func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    static func microphone() { open("Privacy_Microphone") }
    static func systemAudio() { open("Privacy_ScreenCapture") }
}
