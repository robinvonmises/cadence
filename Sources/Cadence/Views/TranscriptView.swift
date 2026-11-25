import CadenceCore
import SwiftUI

/// Transkript als Chatverlauf: deine Beiträge rechts, alle anderen links – farbig nach Partei.
struct TranscriptView: View {
    @Binding var session: Session
    var isLive: Bool
    var filter: String = ""
    var onSeek: ((Double) -> Void)?
    var playingTime: Double?

    @State private var autoScroll = true
    @State private var editing: TranscriptSegment?

    struct Turn: Identifiable {
        var id: UUID { segments[0].id }
        var segments: [TranscriptSegment]
        var name: String
        var personID: UUID?
        var isOwner: Bool
        var start: Double { segments[0].start }
    }

    private enum Item: Identifiable {
        case turn(Turn)
        case marker(Marker)

        var id: UUID {
            switch self {
            case .turn(let t): return t.id
            case .marker(let m): return m.id
            }
        }
    }

    private var items: [Item] {
        let owner = session.microphoneOwner?.id
        let segments = session.sortedSegments.filter {
            filter.isEmpty || $0.text.localizedCaseInsensitiveContains(filter)
                || session.displayName(for: $0).localizedCaseInsensitiveContains(filter)
        }
        var markers = filter.isEmpty ? session.markers.sorted { $0.time < $1.time } : []
        var result: [Item] = []
        var current: Turn?

        func flush() {
            if let turn = current { result.append(.turn(turn)) }
            current = nil
        }

        for segment in segments {
            while let marker = markers.first, marker.time <= segment.start {
                flush()
                result.append(.marker(marker))
                markers.removeFirst()
            }
            let name = session.displayName(for: segment)
            if var turn = current, turn.name == name, segment.start - (turn.segments.last?.end ?? 0) < 8 {
                turn.segments.append(segment)
                current = turn
            } else {
                flush()
                let isOwner = segment.source == .microphone && (segment.personID == nil || segment.personID == owner)
                current = Turn(segments: [segment], name: name, personID: segment.personID, isOwner: isOwner)
            }
        }
        flush()
        result += markers.map { .marker($0) }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if session.segments.isEmpty {
                        emptyState
                    }
                    ForEach(items) { item in
                        switch item {
                        case .turn(let turn):
                            TurnView(
                                session: $session,
                                turn: turn,
                                playingTime: playingTime,
                                onSeek: onSeek,
                                onEdit: { editing = $0 }
                            )
                            .id(item.id)
                        case .marker(let marker):
                            MarkerRow(marker: marker, onSeek: onSeek) { session.removeMarker(marker.id) }
                                .id(item.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            .onChange(of: session.segments.count) { _, _ in
                guard isLive, autoScroll else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if isLive && !session.segments.isEmpty {
                    Button {
                        autoScroll.toggle()
                        if autoScroll { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Image(systemName: autoScroll ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .font(.title2)
                            .foregroundStyle(autoScroll ? Theme.accent : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(autoScroll ? "Automatisch mitscrollen (an)" : "Automatisch mitscrollen (aus)")
                    .padding(14)
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

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: isLive ? "waveform" : "text.bubble")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.gradient)
                .symbolEffect(.variableColor.iterative, isActive: isLive)
            Text(isLive ? "Ich höre zu …" : "Noch kein Transkript")
                .font(.system(.title3, design: .rounded).weight(.semibold))
            Text(isLive ? "Sobald jemand spricht, erscheint hier der Text." : "")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }
}

private struct TurnView: View {
    @Binding var session: Session
    let turn: TranscriptView.Turn
    let playingTime: Double?
    let onSeek: ((Double) -> Void)?
    let onEdit: (TranscriptSegment) -> Void

    private var color: Color { session.color(for: turn.personID) }
    private var unassigned: Bool { turn.personID == nil && !turn.isOwner }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if turn.isOwner { Spacer(minLength: 80) } else { avatar }

            VStack(alignment: turn.isOwner ? .trailing : .leading, spacing: 4) {
                header
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(turn.segments) { segment in
                        SegmentText(session: $session, segment: segment,
                                    isPlaying: isPlaying(segment), onSeek: onSeek, onEdit: onEdit)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleBackground, in: BubbleShape(isOwner: turn.isOwner))
            }

            if turn.isOwner { avatar } else { Spacer(minLength: 80) }
        }
    }

    private var bubbleBackground: Color {
        if turn.isOwner { return Theme.accent.opacity(0.14) }
        if unassigned { return Color.primary.opacity(0.05) }
        return color.opacity(0.12)
    }

    private var avatar: some View {
        Menu {
            SpeakerAssignmentMenu(session: $session, segment: turn.segments[0])
        } label: {
            Avatar(name: turn.name, color: unassigned ? .gray : color, size: 30)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sprecher zuordnen")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(turn.name).font(.caption.weight(.semibold))
            if let party = session.party(of: session.person(turn.personID)) {
                Text(party.name).font(.caption2).foregroundStyle(party.color.color)
            }
            if unassigned {
                Text("Wer war das?").font(.caption2).foregroundStyle(.orange)
            }
            Button(TimeFormat.clock(turn.start)) { onSeek?(turn.start) }
                .buttonStyle(.plain)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .disabled(onSeek == nil)
        }
    }

    private func isPlaying(_ segment: TranscriptSegment) -> Bool {
        guard let playingTime else { return false }
        return playingTime >= segment.start && playingTime < segment.end
    }
}

private struct BubbleShape: Shape {
    let isOwner: Bool

    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 14
        return Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(
            topLeading: isOwner ? r : 4,
            bottomLeading: r,
            bottomTrailing: r,
            topTrailing: isOwner ? 4 : r
        ), style: .continuous)
    }
}

private struct SegmentText: View {
    @Binding var session: Session
    let segment: TranscriptSegment
    let isPlaying: Bool
    let onSeek: ((Double) -> Void)?
    let onEdit: (TranscriptSegment) -> Void

    var body: some View {
        Text(segment.text)
            .font(.body)
            .lineSpacing(2)
            .textSelection(.enabled)
            .padding(.horizontal, isPlaying ? 4 : 0)
            .background(isPlaying ? Theme.accent.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .onTapGesture(count: 2) { onSeek?(segment.start) }
            .contextMenu {
                if let onSeek {
                    Button("Ab hier abspielen") { onSeek(segment.start) }
                }
                Button("Text bearbeiten …") { onEdit(segment) }
                Button("Text kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(segment.text, forType: .string)
                }
                Menu("Sprecher zuordnen") { SpeakerAssignmentMenu(session: $session, segment: segment) }
                Divider()
                Button("⭐️ Als wichtig markieren") { session.addMarker(.highlight, text: segment.text, at: segment.start) }
                Button("✅ Als Aufgabe markieren") { session.addMarker(.todo, text: segment.text, at: segment.start) }
                Button("⚖️ Als Entscheidung markieren") { session.addMarker(.decision, text: segment.text, at: segment.start) }
                Divider()
                Button("Abschnitt löschen", role: .destructive) { session.deleteSegment(segment.id) }
            }
    }
}

/// Menüeinträge zum Zuordnen eines Abschnitts, einer Stimme oder „ab hier“.
struct SpeakerAssignmentMenu: View {
    @Binding var session: Session
    let segment: TranscriptSegment

    var body: some View {
        if let cluster = segment.clusterID {
            Section("Ganze Stimme „Sprecher \(cluster + 1)“") {
                ForEach(session.people) { person in
                    Button(person.name) { session.assign(cluster: cluster, to: person.id) }
                }
            }
        }
        Section("Nur dieser Satz") {
            ForEach(session.people) { person in
                Button(person.name) { session.assign(segment: segment.id, to: person.id) }
            }
            if segment.manualPersonID != nil {
                Button("Zurücksetzen") { session.assign(segment: segment.id, to: nil) }
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
}

private struct MarkerRow: View {
    let marker: Marker
    let onSeek: ((Double) -> Void)?
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(.separator).frame(height: 0.5)
            HStack(spacing: 6) {
                Text(marker.kind.emoji)
                Text(marker.text).font(.caption.weight(.semibold)).lineLimit(2)
                Text(TimeFormat.clock(marker.time)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.yellow.opacity(0.14), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(.separator).frame(height: 0.5)
        }
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
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(width: 480, height: 160)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Spacer()
                Button("Abbrechen") { completion(nil) }.keyboardShortcut(.cancelAction)
                Button("Sichern") { completion(text) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }
}
