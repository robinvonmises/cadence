import CadenceCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var recorder: RecordingController
    @EnvironmentObject private var navigation: Navigation

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
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

    var body: some View {
        List(selection: $navigation.selection) {
            Section {
                if recorder.isBusy, let session = recorder.session {
                    Label {
                        VStack(alignment: .leading) {
                            Text(session.title).lineLimit(1)
                            Text(recorder.isRecording ? TimeFormat.clock(recorder.elapsed) : "Wird verarbeitet …")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    }
                    .tag(Navigation.Selection.live)
                } else {
                    Label("Neue Aufnahme", systemImage: "plus.circle.fill")
                        .tag(Navigation.Selection.newRecording)
                }
            }

            Section("Gespräche") {
                ForEach(filtered) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.session.title).lineLimit(1)
                        Text("\(entry.session.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(TimeFormat.duration(entry.session.duration))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(Navigation.Selection.saved(entry.id))
                    .contextMenu {
                        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([entry.folder]) }
                        Divider()
                        Button("In den Papierkorb legen", role: .destructive) { pendingDelete = entry.id }
                    }
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Suchen")
        .toolbar {
            ToolbarItem {
                Button {
                    NSWorkspace.shared.open(store.rootFolder)
                } label: {
                    Label("Ordner öffnen", systemImage: "folder")
                }
                .help("Speicherort im Finder öffnen")
            }
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
}
