import CadenceCore
import SwiftUI

/// Zeitleiste aus Transkript-Abschnitten und Markern.
struct TranscriptView: View {
    @Binding var session: Session
    var isLive: Bool
    var filter: String = ""
    var onSeek: ((Double) -> Void)?
    var playingTime: Double?

    @State private var autoScroll = true
    @State private var editing: TranscriptSegment?

    private enum Item: Identifiable {
        case segment(TranscriptSegment, showHeader: Bool)
        case marker(Marker)

        var id: UUID {
            switch self {
            case .segment(let s, _): return s.id
            case .marker(let m): return m.id
            }
        }

        var time: Double {
            switch self {
            case .segment(let s, _): return s.start
            case .marker(let m): return m.time
            }
        }
    }

    private var items: [Item] {
        var result: [Item] = []
        var lastName: String?
        let segments = session.sortedSegments.filter {
            filter.isEmpty || $0.text.localizedCaseInsensitiveContains(filter) || session.displayName(for: $0).localizedCaseInsensitiveContains(filter)
        }
        var markers = filter.isEmpty ? session.markers.sorted { $0.time < $1.time } : []
        for segment in segments {
            while let marker = markers.first, marker.time <= segment.start {
                result.append(.marker(marker))
                markers.removeFirst()
                lastName = nil
            }
            let name = session.displayName(for: segment)
            result.append(.segment(segment, showHeader: name != lastName))
            lastName = name
        }
        result += markers.map { .marker($0) }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if session.segments.isEmpty {
                        emptyState
                    }
                    ForEach(items) { item in
                        switch item {
                        case .segment(let segment, let showHeader):
                            SegmentRow(
                                session: $session,
                                segment: segment,
                                showHeader: showHeader,
                                isPlaying: isPlaying(segment),
                                onSeek: onSeek,
                                onEdit: { editing = segment }
                            )
                            .id(item.id)
                        case .marker(let marker):
                            MarkerRow(marker: marker, onSeek: onSeek) {
                                session.removeMarker(marker.id)
                            }
                            .id(item.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .onChange(of: session.segments.count) { _, _ in
                guard isLive, autoScroll else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if isLive {
                    Toggle(isOn: $autoScroll) { Label("Mitscrollen", systemImage: "arrow.down.to.line") }
                        .toggleStyle(.button)
                        .padding(10)
                }
            }
        }
        .sheet(item: $editing) { segment in
            EditSegmentSheet(text: segment.text) { newText in
                if let newText { session.updateText(segment: segment.id, text: newText) }
                editing = nil
            }
        }
    }

    private func isPlaying(_ segment: TranscriptSegment) -> Bool {
        guard let playingTime else { return false }
        return playingTime >= segment.start && playingTime < segment.end
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble").font(.largeTitle).foregroundStyle(.tertiary)
            Text(isLive ? "Sobald jemand spricht, erscheint hier das Transkript." : "Kein Transkript vorhanden.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

private struct SegmentRow: View {
    @Binding var session: Session
    let segment: TranscriptSegment
    let showHeader: Bool
    let isPlaying: Bool
    let onSeek: ((Double) -> Void)?
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showHeader {
                HStack(spacing: 8) {
                    speakerMenu
                    Text(TimeFormat.clock(segment.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if segment.origin == .none && segment.source == .system {
                        Text("nicht zugeordnet").font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.top, 10)
            }
            Text(segment.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)
                .padding(.vertical, 2)
                .background(isPlaying ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onSeek?(segment.start) }
                .contextMenu { contextMenu }
        }
    }

    private var speakerMenu: some View {
        Menu {
            assignmentButtons
        } label: {
            NameChip(name: session.displayName(for: segment), color: session.color(for: segment.personID))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var assignmentButtons: some View {
        Section("Nur dieser Abschnitt") {
            ForEach(session.people) { person in
                Button(person.name) { session.assign(segment: segment.id, to: person.id) }
            }
            if segment.manualPersonID != nil {
                Button("Zuordnung zurücksetzen") { session.assign(segment: segment.id, to: nil) }
            }
        }
        if let cluster = segment.clusterID {
            Section("Alle Abschnitte von „Sprecher \(cluster + 1)“") {
                ForEach(session.people) { person in
                    Button(person.name) { session.assign(cluster: cluster, to: person.id) }
                }
            }
        }
        if segment.source == .system {
            Section("Ab hier spricht …") {
                ForEach(session.people) { person in
                    Button(person.name) { session.tagSpeaker(person.id, at: segment.start) }
                }
            }
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if let onSeek {
            Button("Ab hier abspielen") { onSeek(segment.start) }
        }
        Button("Text bearbeiten …", action: onEdit)
        Button("Text kopieren") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(segment.text, forType: .string)
        }
        Menu("Sprecher zuordnen") { assignmentButtons }
        Divider()
        Button("Als Aufgabe markieren") { session.addMarker(.todo, text: segment.text, at: segment.start) }
        Button("Als Entscheidung markieren") { session.addMarker(.decision, text: segment.text, at: segment.start) }
        Button("Als wichtig markieren") { session.addMarker(.highlight, text: segment.text, at: segment.start) }
        Divider()
        Button("Abschnitt löschen", role: .destructive) { session.deleteSegment(segment.id) }
    }
}

private struct MarkerRow: View {
    let marker: Marker
    let onSeek: ((Double) -> Void)?
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(marker.kind.emoji)
            Text(marker.text).bold()
            Text(TimeFormat.clock(marker.time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .padding(.vertical, 6)
        .contextMenu {
            if let onSeek { Button("Ab hier abspielen") { onSeek(marker.time) } }
            Button("Marker löschen", role: .destructive, action: onDelete)
        }
    }
}

private struct EditSegmentSheet: View {
    @State var text: String
    let completion: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Text bearbeiten").font(.headline)
            TextEditor(text: $text)
                .frame(width: 480, height: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                Spacer()
                Button("Abbrechen") { completion(nil) }.keyboardShortcut(.cancelAction)
                Button("Sichern") { completion(text) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
