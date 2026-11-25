import CadenceCore
import SwiftUI

/// Leiste unter dem Live-Transkript: Wer spricht gerade? + schnelle Marker.
struct SpeakerDock: View {
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var voices: VoiceProfileStore
    @Binding var session: Session
    @State private var typedName = ""
    @State private var partyID: UUID?
    @State private var note = ""
    @FocusState private var nameFocused: Bool

    /// Namen aus früheren Gesprächen als Vorschläge.
    private var knownPeople: [(name: String, party: String?)] {
        var seen = Set(session.people.map { $0.name.lowercased() })
        var result: [(name: String, party: String?)] = []
        for profile in voices.profiles where seen.insert(profile.name.lowercased()).inserted {
            result.append((name: profile.name, party: profile.partyName))
        }
        for entry in store.entries {
            for person in entry.session.people where !person.isMicrophoneOwner {
                if seen.insert(person.name.lowercased()).inserted {
                    result.append((name: person.name, party: entry.session.party(of: person)?.name))
                }
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    private var suggestions: [(name: String, party: String?)] {
        let query = typedName.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return Array(knownPeople.filter { $0.name.localizedCaseInsensitiveContains(query) }.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 6) {
                Text("Wer spricht gerade?").sectionTitle()
                Spacer()
                Text("⌃⌥ + Zahl").font(.caption2).foregroundStyle(.tertiary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(session.hotkeyPeople.enumerated()), id: \.element.id) { index, person in
                        SpeakerButton(
                            name: person.name,
                            color: session.color(for: person.id),
                            badge: "\(index + 1)",
                            isActive: recorder.currentSpeakerID == person.id
                        ) {
                            recorder.setCurrentSpeaker(person.id)
                        }
                    }
                    SpeakerButton(name: "Unbekannt", color: .gray, badge: "0", isActive: recorder.currentSpeakerID == nil) {
                        recorder.setCurrentSpeaker(nil)
                    }
                    newPersonField
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }

            HStack(spacing: 8) {
                MarkerButton(kind: .highlight, shortcut: "M") { recorder.addMarker(.highlight) }
                MarkerButton(kind: .todo, shortcut: "A") { recorder.addMarker(.todo) }
                MarkerButton(kind: .decision, shortcut: "E") { recorder.addMarker(.decision) }
                TextField("Notiz mit Zeitstempel + ⏎", text: $note)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let text = note.trimmingCharacters(in: .whitespaces)
                        guard !text.isEmpty else { return }
                        recorder.addMarker(.note, text: text)
                        note = ""
                    }
            }
        }
        .padding(16)
        .background(.bar)
        .onAppear { if partyID == nil { partyID = session.parties.dropFirst().first?.id ?? session.parties.first?.id } }
        .onChange(of: recorder.focusSpeakerFieldRequest) { _, _ in nameFocused = true }
    }

    private var newPersonField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.plus").foregroundStyle(Theme.accent)
                TextField("Name + ⏎", text: $typedName)
                    .textFieldStyle(.plain)
                    .focusEffectDisabled()
                    .frame(width: 130)
                    .focused($nameFocused)
                    .onSubmit { submit(typedName) }
                Menu {
                    ForEach(session.parties) { party in
                        Button {
                            partyID = party.id
                        } label: {
                            if partyID == party.id { Label(party.name, systemImage: "checkmark") } else { Text(party.name) }
                        }
                    }
                } label: {
                    NameChip(name: session.party(partyID)?.name ?? "Partei", color: session.party(partyID)?.color.color ?? .gray)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(nameFocused ? Theme.accent : Color.secondary.opacity(0.3), lineWidth: 1))

            ForEach(suggestions, id: \.name) { known in
                Button {
                    if let match = session.parties.first(where: { $0.name == known.party }) { partyID = match.id }
                    submit(known.name)
                } label: {
                    Text(known.party.map { "\(known.name) · \($0)" } ?? known.name)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.top, 4)
    }

    private func submit(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        recorder.speakerTyped(name, partyID: partyID)
        typedName = ""
    }
}

private struct MarkerButton: View {
    let kind: MarkerKind
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(kind.emoji) \(kind.label)").font(.callout)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .help("\(kind.label) markieren (⌃⌥\(shortcut))")
    }
}

/// Teilnehmer nach Parteien – umbenennen, verschieben, entfernen, Parteien anlegen.
struct PartiesPanel: View {
    @Binding var session: Session
    @State private var renaming: RenameTarget?
    @State private var renameText = ""

    private enum RenameTarget: Identifiable {
        case person(UUID), party(UUID), newParty, newPerson(UUID)
        var id: String {
            switch self {
            case .person(let id): return "p\(id)"
            case .party(let id): return "g\(id)"
            case .newParty: return "new"
            case .newPerson(let id): return "np\(id)"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Teilnehmer").sectionTitle()
                Spacer()
                Button {
                    renameText = ""
                    renaming = .newParty
                } label: {
                    Label("Partei", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Weitere Partei hinzufügen, z. B. einen Dienstleister")
            }

            ForEach(session.parties) { party in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().fill(party.color.color).frame(width: 8, height: 8)
                        Text(party.name).font(.callout.weight(.semibold))
                        Spacer()
                        Menu {
                            Button("Person hinzufügen …") { renameText = ""; renaming = .newPerson(party.id) }
                            Button("Umbenennen …") { renameText = party.name; renaming = .party(party.id) }
                            if session.parties.count > 1 {
                                Divider()
                                Button("Partei entfernen", role: .destructive) { session.removeParty(party.id) }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                    let members = session.people(in: party)
                    if members.isEmpty {
                        Text("Noch niemand").font(.caption).foregroundStyle(.tertiary).padding(.leading, 14)
                    }
                    ForEach(members) { person in personRow(person) }
                }
                .padding(10)
                .background(party.color.color.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            let loose = session.peopleWithoutParty
            if !loose.isEmpty {
                Text("Ohne Partei").font(.callout.weight(.semibold))
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
        case .newPerson: return "Person hinzufügen"
        default: return "Person umbenennen"
        }
    }

    private func personRow(_ person: Person) -> some View {
        HStack(spacing: 8) {
            Avatar(name: person.name, color: session.color(for: person.id), size: 22)
            Text(person.name).lineLimit(1)
            if person.isMicrophoneOwner {
                Image(systemName: "mic.fill").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            let seconds = session.segments.filter { $0.personID == person.id }.reduce(0) { $0 + $1.duration }
            if seconds > 0 {
                Text(TimeFormat.clock(seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
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
        case .newPerson(let partyID): session.addPerson(named: name, partyID: partyID)
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
            VStack(alignment: .leading, spacing: 10) {
                Text("Erkannte Stimmen").sectionTitle()
                Text("Jede Stimme einmal zuordnen – das gilt dann fürs ganze Gespräch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(clusters, id: \.self) { cluster in
                    let segments = session.segments.filter { $0.clusterID == cluster }
                    let seconds = segments.reduce(0) { $0 + $1.duration }
                    let assigned = session.clusterAssignments[cluster]
                    HStack(spacing: 8) {
                        if let onListen, let sample = segments.max(by: { $0.duration < $1.duration }) {
                            Button { onListen(sample.start) } label: {
                                Image(systemName: "play.circle.fill").font(.title3).foregroundStyle(Theme.accent)
                            }
                            .buttonStyle(.plain)
                            .help("Probe anhören: „\(sample.text.prefix(60))“")
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Stimme \(cluster + 1)").font(.callout.weight(.medium))
                            Text(TimeFormat.clock(seconds)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { assigned },
                            set: { session.assign(cluster: cluster, to: $0) }
                        )) {
                            Text("Wer ist das?").tag(UUID?.none)
                            ForEach(session.people) { person in
                                Text(person.name).tag(Optional(person.id))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                    .padding(8)
                    .background((assigned == nil ? Color.orange : session.color(for: assigned)).opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Notizen & Marker").sectionTitle()
            HStack(spacing: 6) {
                Menu {
                    ForEach(MarkerKind.allCases.filter { $0 != .consent }, id: \.self) { option in
                        Button("\(option.emoji) \(option.label)") { kind = option }
                    }
                } label: {
                    Text(kind.emoji)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                TextField("\(kind.label) + ⏎", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let trimmed = text.trimmingCharacters(in: .whitespaces)
                        session.addMarker(kind, text: trimmed, at: currentTime())
                        text = ""
                    }
            }
            if session.markers.isEmpty {
                Text("Noch keine Marker.").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(session.markers.sorted { $0.time > $1.time }) { marker in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker.kind.emoji)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(marker.text).lineLimit(3)
                        Button(TimeFormat.clock(marker.time)) { onSeek?(marker.time) }
                            .buttonStyle(.plain)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contextMenu {
                    Button("Löschen", role: .destructive) { session.removeMarker(marker.id) }
                }
            }
        }
    }
}

/// Einfaches Umbruch-Layout für Chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // Bei Breite 0 (Mindestgrößen-Abfrage) nicht jedes Element in eine eigene Zeile stapeln.
        let proposed = proposal.width ?? .infinity
        let width = proposed < 1 ? .infinity : proposed
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
        let usedWidth = width.isFinite ? width : max(0, x - spacing)
        return CGSize(width: usedWidth, height: y + rowHeight)
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
