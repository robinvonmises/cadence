import CadenceCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var navigation: Navigation

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            switch navigation.selection {
            case .live where recorder.session != nil && recorder.isBusy:
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
        .tint(Theme.accent)
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

    /// Gespräche nach „Heute“, „Gestern“, „Diese Woche“, „Früher“ gruppieren.
    private var groups: [(title: String, entries: [SessionStore.Entry])] {
        let calendar = Calendar.current
        var buckets: [(String, [SessionStore.Entry])] = [("Heute", []), ("Gestern", []), ("Diese Woche", []), ("Früher", [])]
        for entry in filtered {
            let date = entry.session.startedAt
            let index: Int
            if calendar.isDateInToday(date) { index = 0 }
            else if calendar.isDateInYesterday(date) { index = 1 }
            else if calendar.isDate(date, equalTo: Date(), toGranularity: .weekOfYear) { index = 2 }
            else { index = 3 }
            buckets[index].1.append(entry)
        }
        return buckets.filter { !$0.1.isEmpty }.map { (title: $0.0, entries: $0.1) }
    }

    var body: some View {
        List(selection: $navigation.selection) {
            Section {
                if recorder.isBusy, let session = recorder.session {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(Theme.record.opacity(0.18)).frame(width: 30, height: 30)
                            Circle().fill(Theme.record).frame(width: 10, height: 10)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.title).font(.callout.weight(.semibold)).lineLimit(1)
                            Text(recorder.isRecording ? "Aufnahme · \(TimeFormat.clock(recorder.elapsed))" : "Wird verarbeitet …")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(Navigation.Selection.live)
                } else {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.gradient).frame(width: 30, height: 30)
                            Image(systemName: "plus").font(.callout.weight(.bold)).foregroundStyle(.white)
                        }
                        Text("Neue Aufnahme").font(.callout.weight(.semibold))
                    }
                    .padding(.vertical, 4)
                    .tag(Navigation.Selection.newRecording)
                }
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
        }
        .listStyle(.sidebar)
        .overlay {
            if store.entries.isEmpty && !recorder.isBusy {
                VStack(spacing: 6) {
                    Image(systemName: "waveform").font(.title).foregroundStyle(.tertiary)
                    Text("Noch keine Gespräche").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 120)
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Gespräche durchsuchen")
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
}

private struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accent.opacity(0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: session.segments.isEmpty ? "waveform.badge.exclamationmark" : "text.bubble.fill")
                    .font(.caption)
                    .foregroundStyle(session.segments.isEmpty ? Color.orange : Theme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private var subtitle: String {
        let calendar = Calendar.current
        let recent = calendar.isDateInToday(session.startedAt) || calendar.isDateInYesterday(session.startedAt)
        let when = recent
            ? session.startedAt.formatted(date: .omitted, time: .shortened)
            : session.startedAt.formatted(.dateTime.day().month(.abbreviated))
        var parts = [when, TimeFormat.duration(session.duration)]
        let others = session.people.filter { !$0.isMicrophoneOwner }.map(\.name)
        if !others.isEmpty { parts.append(others.prefix(2).joined(separator: ", ") + (others.count > 2 ? " …" : "")) }
        return parts.joined(separator: " · ")
    }
}
