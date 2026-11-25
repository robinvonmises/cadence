import CadenceCore
import SwiftUI

// MARK: - Marke

enum Brand {
    static let indigo = Color(red: 0.31, green: 0.27, blue: 0.90)
    static let violet = Color(red: 0.55, green: 0.36, blue: 0.96)
    static let coral = Color(red: 0.98, green: 0.42, blue: 0.45)
    static let record = Color(red: 0.96, green: 0.25, blue: 0.33)

    static let gradient = LinearGradient(colors: [indigo, violet, coral], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let soft = LinearGradient(
        colors: [indigo.opacity(0.10), violet.opacity(0.06), coral.opacity(0.08)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let recordGradient = LinearGradient(colors: [Color(red: 1, green: 0.45, blue: 0.45), record], startPoint: .top, endPoint: .bottom)
}

/// Das Cadence-Logo: Sprechblase mit Klangwelle auf Marken-Verlauf (wie das App-Icon).
struct CadenceLogo: View {
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.235, style: .continuous)
                .fill(Brand.gradient)
            RoundedRectangle(cornerRadius: size * 0.235, style: .continuous)
                .fill(LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: .center))
            LogoMark()
                .padding(size * 0.2)
        }
        .frame(width: size, height: size)
        .shadow(color: Brand.violet.opacity(0.35), radius: size * 0.12, y: size * 0.05)
    }
}

/// Sprechblase mit fünf Wellen-Balken – Weiß auf Verlauf.
struct LogoMark: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                BubbleShape()
                    .foregroundStyle(.white)
                HStack(alignment: .center, spacing: w * 0.06) {
                    ForEach(Array([0.32, 0.62, 0.92, 0.55, 0.38].enumerated()), id: \.offset) { _, height in
                        Capsule()
                            .fill(Brand.gradient)
                            .frame(width: w * 0.085, height: h * 0.62 * height)
                    }
                }
                .offset(y: -h * 0.06)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Abgerundete Sprechblase mit kleinem Zipfel unten links (Körper und Zipfel getrennt gefüllt,
/// damit sich die Flächen nicht gegenseitig auslöschen).
struct BubbleShape: View {
    var body: some View {
        ZStack {
            BubbleBody()
            BubbleTail()
        }
    }
}

private struct BubbleBody: Shape {
    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.84)
        return Path(roundedRect: body, cornerRadius: rect.width * 0.26, style: .continuous)
    }
}

private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        let bodyMaxY = rect.minY + rect.height * 0.84
        var tail = Path()
        tail.move(to: CGPoint(x: rect.minX + rect.width * 0.20, y: bodyMaxY - rect.height * 0.10))
        tail.addLine(to: CGPoint(x: rect.minX + rect.width * 0.10, y: rect.maxY))
        tail.addQuadCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.46, y: bodyMaxY - rect.height * 0.04),
            control: CGPoint(x: rect.minX + rect.width * 0.30, y: rect.maxY - rect.height * 0.02)
        )
        tail.closeSubpath()
        return tail
    }
}

// MARK: - Bausteine

/// Ruhige Karte als Grundbaustein der Oberfläche.
struct CardModifier: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.07)))
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardModifier(padding: padding)) }
}

/// Abschnittsüberschrift in Karten.
struct SectionTitle: View {
    let title: String
    var systemImage: String?
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).foregroundStyle(Brand.violet)
                }
                Text(title).font(.headline)
            }
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Hintergrund der Hauptbereiche: leicht getönt, damit Karten sich abheben.
struct CanvasBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Brand.soft.opacity(0.6)
        }
        .ignoresSafeArea()
    }
}

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

/// Rundes Initialen-Symbol einer Person.
struct Avatar: View {
    let name: String
    let color: Color
    var size: CGFloat = 26
    var isMicrophone = false

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(color.gradient)
            if isMicrophone {
                Image(systemName: "mic.fill").font(.system(size: size * 0.42, weight: .semibold))
            } else {
                Text(initials).font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
    }
}

/// Namensschild mit Initialen; hervorgehoben = spricht gerade.
struct NameChip: View {
    let name: String
    let color: Color
    var badge: String?
    var highlighted = false

    var body: some View {
        HStack(spacing: 6) {
            Avatar(name: name, color: color, size: 20)
            Text(name).lineLimit(1)
            if let badge {
                Text(badge)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .font(.callout.weight(.medium))
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(color.opacity(highlighted ? 0.22 : 0.08), in: Capsule())
        .overlay(Capsule().strokeBorder(highlighted ? color : color.opacity(0.18), lineWidth: highlighted ? 2 : 1))
        .scaleEffect(highlighted ? 1.03 : 1)
        .animation(.spring(duration: 0.25), value: highlighted)
        .foregroundStyle(.primary)
    }
}

/// Live-Pegel als kleine Balken-Welle.
struct LevelMeter: View {
    let label: String
    let systemImage: String
    let level: Float
    var tint: Color = Brand.violet

    private let weights: [Float] = [0.45, 0.75, 1.0, 0.85, 0.6, 0.9, 0.5]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(weights.indices, id: \.self) { index in
                    let value = CGFloat(min(1, max(0.08, level * 1.6 * weights[index])))
                    Capsule()
                        .fill(level > 0.85 ? AnyShapeStyle(Color.red) : AnyShapeStyle(tint.gradient))
                        .frame(width: 3, height: 4 + 16 * value)
                }
            }
            .frame(height: 20)
            .animation(.easeOut(duration: 0.12), value: level)
        }
        .help(label)
    }
}

/// Kompakter Hinweis mit Symbol – für Status und Fehler.
struct StatusPill: View {
    let text: String
    let systemImage: String
    var tint: Color = .secondary
    var progress: Double?

    var body: some View {
        HStack(spacing: 6) {
            if let progress {
                Group {
                    if progress > 0 {
                        ProgressView(value: progress).progressViewStyle(.circular)
                    } else {
                        ProgressView().progressViewStyle(.circular)
                    }
                }
                .controlSize(.mini)
            } else {
                Image(systemName: systemImage)
            }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Zustand des Sprachmodells – mit Fortschritt, Fehlerdetails und „Erneut versuchen“.
struct ModelStatusView: View {
    @EnvironmentObject private var models: ModelManager
    var compact = false
    @State private var showDetails = false

    var body: some View {
        switch models.status {
        case .ready:
            StatusPill(text: models.statusText, systemImage: "checkmark.circle.fill", tint: .green)
        case .downloading(let progress):
            if compact {
                StatusPill(text: models.statusText, systemImage: "arrow.down.circle", tint: Brand.indigo, progress: progress)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label(models.statusText, systemImage: "arrow.down.circle")
                        Spacer()
                    }
                    .font(.callout.weight(.medium))
                    ProgressView(value: progress > 0 ? progress : nil)
                        .tint(Brand.indigo)
                    Text("Einmaliger Download – danach läuft alles offline auf diesem Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .loading, .idle:
            StatusPill(text: models.statusText, systemImage: "hourglass", tint: Brand.indigo, progress: 0)
        case .failed(let message):
            HStack(spacing: 8) {
                StatusPill(text: models.statusText, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                Button("Details") { showDetails = true }
                    .buttonStyle(.link)
                    .font(.caption)
                    .popover(isPresented: $showDetails) {
                        ScrollView {
                            Text(message)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .padding(12)
                        }
                        .frame(width: 420, height: 200)
                    }
                Button("Erneut versuchen") { models.retry() }
                    .controlSize(.small)
            }
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
