import CadenceCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var navigation: Navigation

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
        } detail: {
            Group {
                switch navigation.selection {
                case .live where recorder.session != nil:
                    LiveSessionView()
                case .saved(let id):
                    if let entry = store.entries.first(where: { $0.id == id }) {
                        SavedSessionView(entry: entry)
                            .id(entry.id)
                    } else {
                        ContentUnavailableView("Gespräch nicht gefunden", systemImage: "questionmark.folder")
                    }
                default:
                    NewRecordingView()
                }
            }
            .background(CanvasBackground())
        }
        .tint(Brand.violet)
        .onChange(of: recorder.phase) { oldPhase, newPhase in
            if newPhase == .recording { navigation.selection = .live }
            if newPhase == .idle, oldPhase != .idle, oldPhase != .preparing, let id = recorder.session?.id {
                navigation.selection = .saved(id)
            }
        }
        .alert("Hinweis", isPresented: Binding(
            get: { recorder.errorMessage != nil },
            set: { if !$0 { recorder.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recorder.errorMessage ?? "")
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var navigation: Navigation
    @State private var search = ""
    @State private var pendingDelete: UUID?

    private var filtered: [SessionStore.Entry] {
        guard !search.isEmpty else { return store.entries }
        return store.entries.filter { entry in
            entry.session.title.localizedCaseInsensitiveContains(search)
                || entry.session.people.contains { $0.name.localizedCaseInsensitiveContains(search) }
                || entry.session.segments.contains { $0.text.localizedCaseInsensitiveContains(search) }
        }
    }

    /// Gespräche nach Zeitraum gruppiert („Heute“, „Gestern“, …).
    private var groups: [(title: String, entries: [SessionStore.Entry])] {
        let calendar = Calendar.current
        let now = Date()
        var buckets: [(String, [SessionStore.Entry])] = [("Heute", []), ("Gestern", []), ("Diese Woche", []), ("Früher", [])]
        for entry in filtered.sorted(by: { $0.session.startedAt > $1.session.startedAt }) {
            let date = entry.session.startedAt
            let index: Int
            if calendar.isDateInToday(date) { index = 0 }
            else if calendar.isDateInYesterday(date) { index = 1 }
            else if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 { index = 2 }
            else { index = 3 }
            buckets[index].1.append(entry)
        }
        return buckets.filter { !$0.1.isEmpty }.map { (title: $0.0, entries: $0.1) }
    }

    var body: some View {
        List(selection: $navigation.selection) {
            if recorder.isBusy, let session = recorder.session {
                LiveSidebarRow(title: session.title)
                    .tag(Navigation.Selection.live)
            }

            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.entries) { entry in
                        SessionRow(session: entry.session)
                            .tag(Navigation.Selection.saved(entry.id))
                            .contextMenu {
                                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([entry.folder]) }
                                Divider()
                                Button("In den Papierkorb legen", role: .destructive) { pendingDelete = entry.id }
                            }
                    }
                }
            }

            if store.entries.isEmpty {
                Text("Noch keine Gespräche – deine Aufnahmen erscheinen hier.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .selectionDisabled()
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Gespräche durchsuchen")
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                ModelStatusView(compact: true)
                Spacer(minLength: 0)
                Button {
                    NSWorkspace.shared.open(store.rootFolder)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Speicherort im Finder öffnen")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .confirmationDialog("Gespräch in den Papierkorb legen?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("In den Papierkorb", role: .destructive) {
                if let id = pendingDelete {
                    if navigation.selection == .saved(id) { navigation.selection = .newRecording }
                    store.delete(id)
                }
                pendingDelete = nil
            }
        } message: {
            Text("Transkript und Audio werden in den Papierkorb verschoben.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                CadenceLogo(size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Cadence").font(.title3.weight(.bold))
                    Text("Meetings, lokal transkribiert").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button {
                navigation.selection = recorder.isBusy ? .live : .newRecording
            } label: {
                Label(recorder.isBusy ? "Zur laufenden Aufnahme" : "Neue Aufnahme", systemImage: recorder.isBusy ? "waveform" : "plus")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .background(recorder.isBusy ? AnyShapeStyle(Brand.recordGradient) : AnyShapeStyle(Brand.gradient),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Neue Aufnahme (⌘N)")
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

/// Laufende Aufnahme oben in der Seitenleiste.
private struct LiveSidebarRow: View {
    @EnvironmentObject private var recorder: RecordingController
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Brand.record.opacity(0.15)).frame(width: 28, height: 28)
                Circle().fill(Brand.record).frame(width: 10, height: 10)
                    .symbolEffect(.pulse, isActive: recorder.isRecording)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.semibold).lineLimit(1)
                Text(recorder.isRecording ? "Aufnahme · \(TimeFormat.clock(recorder.elapsed))" : "Wird verarbeitet …")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Brand.record)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Eintrag eines gespeicherten Gesprächs.
private struct SessionRow: View {
    let session: Session

    private var others: [Person] { session.people.filter { !$0.isMicrophoneOwner } }

    private var dateText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(session.startedAt) || calendar.isDateInYesterday(session.startedAt) {
            return session.startedAt.formatted(date: .omitted, time: .shortened)
        }
        return session.startedAt.formatted(.dateTime.day().month(.abbreviated))
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Brand.soft)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Brand.violet.opacity(0.2)))
                Image(systemName: session.segments.isEmpty ? "waveform" : "text.bubble.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.gradient)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).lineLimit(1)
                HStack(spacing: 4) {
                    Text(dateText)
                    Text("·")
                    Text(TimeFormat.duration(session.duration))
                    if !others.isEmpty {
                        Text("·")
                        Text(others.count == 1 ? others[0].name : "\(others.count) Personen").lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
