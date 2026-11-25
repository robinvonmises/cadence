import CadenceCore
import SwiftUI

/// Live: „Wer spricht gerade?“ – Personen per Klick, Hotkey oder Eintippen setzen.
struct LiveSpeakerPanel: View {
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var store: SessionStore
    @Binding var session: Session
    @State private var typedName = ""
    @State private var partyID: UUID?
    @FocusState private var nameFocused: Bool

    /// Namen aus früheren Gesprächen als Vorschläge.
    private var knownPeople: [(name: String, party: String?)] {
        var seen = Set(session.people.map { $0.name.lowercased() })
        var result: [(name: String, party: String?)] = []
        for entry in store.entries {
            for person in entry.session.people where !person.isMicrophoneOwner {
                if seen.insert(person.name.lowercased()).inserted {
                    result.append((person.name, entry.session.party(of: person)?.name))
                }
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Wer spricht gerade?", systemImage: "person.wave.2.fill")

            let people = session.hotkeyPeople
            if people.isEmpty {
                Text("Tippe unten den Namen der Person ein, die gerade spricht, und drücke ⏎.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            FlowLayout(spacing: 6) {
                ForEach(Array(people.enumerated()), id: \.element.id) { index, person in
                    Button {
                        recorder.setCurrentSpeaker(person.id)
                    } label: {
                        NameChip(
                            name: person.name,
                            color: session.color(for: person.id),
                            badge: "\(index + 1)",
                            highlighted: recorder.currentSpeakerID == person.id
                        )
                    }
                    .buttonStyle(.plain)
                    .help("\(GlobalHotkeys.modifierSymbol)\(index + 1)")
                }
                Button {
                    recorder.setCurrentSpeaker(nil)
                } label: {
                    NameChip(name: "Unbekannt", color: .gray, badge: "0", highlighted: recorder.currentSpeakerID == nil)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                TextField("Name eintippen + ⏎", text: $typedName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(submit)
                Picker("", selection: $partyID) {
                    ForEach(session.parties) { party in
                        Text(party.name).tag(Optional(party.id))
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                if !knownPeople.isEmpty {
                    Menu {
                        ForEach(knownPeople, id: \.name) { known in
                            Button(known.party.map { "\(known.name) (\($0))" } ?? known.name) {
                                typedName = known.name
                                if let match = session.parties.first(where: { $0.name == known.party }) { partyID = match.id }
                                submit()
                            }
                        }
                    } label: {
                        Image(systemName: "person.crop.circle.badge.clock")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Personen aus früheren Gesprächen")
                }
            }
        }
        .onAppear { if partyID == nil { partyID = session.parties.dropFirst().first?.id ?? session.parties.first?.id } }
        .onChange(of: recorder.focusSpeakerFieldRequest) { _, _ in nameFocused = true }
    }

    private func submit() {
        let name = typedName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        recorder.speakerTyped(name, partyID: partyID)
        typedName = ""
    }
}

/// Teilnehmer nach Parteien – umbenennen, verschieben, entfernen, Parteien anlegen.
struct PartiesPanel: View {
    @Binding var session: Session
    @State private var renaming: RenameTarget?
    @State private var renameText = ""

    private enum RenameTarget: Identifiable {
        case person(UUID), party(UUID), newParty
        var id: String {
            switch self {
            case .person(let id): return "p\(id)"
            case .party(let id): return "g\(id)"
            case .newParty: return "new"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: "Teilnehmer", systemImage: "person.2.fill")
                Spacer()
                Button {
                    renameText = ""
                    renaming = .newParty
                } label: {
                    Label("Partei", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Weitere Partei hinzufügen, z. B. einen Dienstleister")
            }

            ForEach(session.parties) { party in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(party.color.color).frame(width: 8, height: 8)
                        Text(party.name.uppercased()).font(.caption.weight(.semibold)).tracking(0.5).foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button("Umbenennen …") { renameText = party.name; renaming = .party(party.id) }
                        if session.parties.count > 1 {
                            Button("Partei entfernen", role: .destructive) { session.removeParty(party.id) }
                        }
                    }
                    let members = session.people(in: party)
                    if members.isEmpty {
                        Text("Noch niemand").font(.caption).foregroundStyle(.tertiary).padding(.leading, 4)
                    }
                    ForEach(members) { person in personRow(person) }
                }
            }
            let loose = session.peopleWithoutParty
            if !loose.isEmpty {
                Text("Ohne Partei").font(.subheadline.bold())
                ForEach(loose) { person in personRow(person) }
            }
        }
        .alert(alertTitle, isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Abbrechen", role: .cancel) { renaming = nil }
            Button("OK") { applyRename() }
        }
    }

    private var alertTitle: String {
        switch renaming {
        case .newParty: return "Neue Partei"
        case .party: return "Partei umbenennen"
        default: return "Person umbenennen"
        }
    }

    private func personRow(_ person: Person) -> some View {
        HStack(spacing: 6) {
            Avatar(name: person.name, color: session.party(of: person)?.color.color ?? .gray, size: 22, isMicrophone: person.isMicrophoneOwner)
            Text(person.name)
            if person.isMicrophoneOwner { Text("(Mikrofon)").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            let seconds = session.segments.filter { $0.personID == person.id }.reduce(0) { $0 + $1.duration }
            if seconds > 0 {
                Text(TimeFormat.clock(seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 4)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Umbenennen …") { renameText = person.name; renaming = .person(person.id) }
            Menu("Partei") {
                ForEach(session.parties) { party in
                    Button(party.name) { session.movePerson(person.id, toParty: party.id) }
                }
            }
            if !person.isMicrophoneOwner {
                Divider()
                Button("Entfernen", role: .destructive) { session.removePerson(person.id) }
            }
        }
    }

    private func applyRename() {
        let name = renameText.trimmingCharacters(in: .whitespaces)
        defer { renaming = nil }
        guard !name.isEmpty, let target = renaming else { return }
        switch target {
        case .person(let id): session.renamePerson(id, to: name)
        case .party(let id): session.renameParty(id, to: name)
        case .newParty: session.addParty(named: name)
        }
    }
}

/// Nach dem Gespräch: erkannte Stimmen („Sprecher 1, 2, …“) Personen zuordnen.
struct ClusterMappingPanel: View {
    @Binding var session: Session
    var onListen: ((Double) -> Void)?

    var body: some View {
        let clusters = session.clusterIDs
        if !clusters.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "Erkannte Stimmen", systemImage: "waveform.badge.magnifyingglass")
                Text("Cadence hat die Gegenseite automatisch in Stimmen getrennt. Ordne jede Stimme einer Person zu – das gilt dann für das ganze Gespräch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(clusters, id: \.self) { cluster in
                    let segments = session.segments.filter { $0.clusterID == cluster }
                    let seconds = segments.reduce(0) { $0 + $1.duration }
                    HStack {
                        if let onListen, let first = segments.max(by: { $0.duration < $1.duration }) {
                            Button { onListen(first.start) } label: { Image(systemName: "play.circle") }
                                .buttonStyle(.borderless)
                                .help("Probe anhören: „\(first.text.prefix(60))“")
                        }
                        Text("Sprecher \(cluster + 1)")
                        Text(TimeFormat.clock(seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { session.clusterAssignments[cluster] },
                            set: { session.assign(cluster: cluster, to: $0) }
                        )) {
                            Text("—").tag(UUID?.none)
                            ForEach(session.people) { person in
                                Text(person.name).tag(Optional(person.id))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                }
            }
        }
    }
}

/// Marker und Notizen mit Zeitstempel.
struct MarkersPanel: View {
    @Binding var session: Session
    var currentTime: () -> Double
    var onSeek: ((Double) -> Void)?
    @State private var text = ""
    @State private var kind: MarkerKind = .note

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Notizen & Marker", systemImage: "bookmark.fill")
            HStack(spacing: 6) {
                Picker("", selection: $kind) {
                    ForEach(MarkerKind.allCases.filter { $0 != .consent }, id: \.self) { kind in
                        Text("\(kind.emoji) \(kind.label)").tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                TextField("Notiz + ⏎", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let trimmed = text.trimmingCharacters(in: .whitespaces)
                        session.addMarker(kind, text: trimmed, at: currentTime())
                        text = ""
                    }
            }
            ForEach(session.markers.sorted { $0.time > $1.time }) { marker in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Button(TimeFormat.clock(marker.time)) { onSeek?(marker.time) }
                        .buttonStyle(.borderless)
                        .font(.caption.monospacedDigit())
                    Text(marker.kind.emoji)
                    Text(marker.text).lineLimit(3)
                    Spacer()
                }
                .contextMenu {
                    Button("Löschen", role: .destructive) { session.removeMarker(marker.id) }
                }
            }
        }
    }
}

/// Einfaches Umbruch-Layout für Namensschilder.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
