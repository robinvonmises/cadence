import CadenceCore
import SwiftUI

extension PartyColor {
    var color: Color {
        switch self {
        case .blue: return .blue
        case .orange: return .orange
        case .green: return .green
        case .purple: return .purple
        case .pink: return .pink
        case .teal: return .teal
        case .gray: return .gray
        }
    }
}

extension Session {
    func color(for personID: UUID?) -> Color {
        party(of: person(personID))?.color.color ?? .secondary
    }
}

/// Kleines farbiges Namensschild.
struct NameChip: View {
    let name: String
    let color: Color
    var badge: String?
    var highlighted = false

    var body: some View {
        HStack(spacing: 4) {
            if let badge {
                Text(badge)
                    .font(.caption2.monospacedDigit().bold())
                    .padding(.horizontal, 4)
                    .background(color.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
            }
            Text(name).lineLimit(1)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(highlighted ? 0.35 : 0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(highlighted ? 0.9 : 0.3), lineWidth: highlighted ? 2 : 1))
        .foregroundStyle(.primary)
    }
}

/// Einfache Pegelanzeige.
struct LevelMeter: View {
    let label: String
    let systemImage: String
    let level: Float

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).frame(width: 16)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(level > 0.85 ? Color.red : Color.green)
                        .frame(width: max(2, geo.size.width * CGFloat(level)))
                        .animation(.linear(duration: 0.1), value: level)
                }
            }
            .frame(width: 80, height: 6)
        }
        .help(label)
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
