import AppKit
import CadenceCore
import SwiftUI

@main
struct CadenceApp: App {
    @StateObject private var store: SessionStore
    @StateObject private var recorder: RecordingController
    @StateObject private var navigation = Navigation()

    init() {
        Defaults.register()
        let store = SessionStore()
        _store = StateObject(wrappedValue: store)
        _recorder = StateObject(wrappedValue: RecordingController(store: store))
        // Auch beim Start über `swift run` als normale App mit Dock-Symbol erscheinen.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Cadence", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(recorder)
                .environmentObject(navigation)
                .frame(minWidth: 980, minHeight: 620)
                .onAppear {
                    store.reload()
                    configureHotkeys()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Neue Aufnahme") { navigation.selection = .newRecording }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(recorder.isBusy)
            }
            CommandMenu("Aufnahme") {
                Button("Aufnahme beenden") { Task { await recorder.stop() } }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!recorder.isRecording)
                Divider()
                Button("Wichtige Stelle markieren") { recorder.addMarker(.highlight) }
                    .keyboardShortcut("m", modifiers: .command)
                    .disabled(!recorder.isRecording)
                Button("Aufgabe markieren") { recorder.addMarker(.todo) }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(!recorder.isRecording)
                Button("Entscheidung markieren") { recorder.addMarker(.decision) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!recorder.isRecording)
                Divider()
                Button("Sprecher: unbekannt") { recorder.setSpeaker(hotkeyIndex: 0) }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(!recorder.isRecording)
                ForEach(1..<10) { index in
                    Button("Sprecher \(index)") { recorder.setSpeaker(hotkeyIndex: index) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                        .disabled(!recorder.isRecording)
                }
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(recorder)
                .environmentObject(navigation)
        } label: {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "waveform")
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }

    private func configureHotkeys() {
        let hotkeys = GlobalHotkeys.shared
        hotkeys.onAction = { [weak recorder] action in
            recorder?.handle(action)
            if action == .focusSpeakerField {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        if UserDefaults.standard.bool(forKey: SettingsKey.globalHotkeys) {
            hotkeys.register()
        }
    }
}

/// Auswahl in der Seitenleiste.
@MainActor
final class Navigation: ObservableObject {
    enum Selection: Hashable {
        case newRecording
        case live
        case saved(UUID)
    }

    @Published var selection: Selection? = .newRecording
}
