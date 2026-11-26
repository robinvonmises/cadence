import AppKit
import CadenceCore
import SwiftUI

@main
struct CadenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: SessionStore
    @StateObject private var recorder: RecordingController
    @StateObject private var models: ModelManager
    @StateObject private var navigation = Navigation()
    @StateObject private var voices: VoiceProfileStore

    init() {
        Defaults.register()
        let voices = VoiceProfileStore()
        let store = SessionStore(voices: voices)
        _voices = StateObject(wrappedValue: voices)
        let models = ModelManager()
        _store = StateObject(wrappedValue: store)
        _models = StateObject(wrappedValue: models)
        _recorder = StateObject(wrappedValue: RecordingController(store: store, models: models))
        // Auch beim Start über `swift run` als normale App mit Dock-Symbol erscheinen.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        // Ein einziges Hauptfenster. Nach dem Schließen holt es ein Klick aufs Dock-Symbol zurück.
        Window("Cadence", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(recorder)
                .environmentObject(navigation)
                .environmentObject(models)
                .environmentObject(voices)
                .frame(minWidth: 1080, minHeight: 720)
                .onAppear {
                    store.reload()
                    configureHotkeys()
                }
                .task {
                    // Modell schon beim Start laden, damit es beim ersten Gespräch bereit ist.
                    await models.ensureReady()
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
            MenuBarLabel(isRecording: recorder.isRecording)
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(models)
                .environmentObject(voices)
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
        case people
        case saved(UUID)
    }

    @Published var selection: Selection? = .newRecording
}

/// Öffnet das Hauptfenster wieder, wenn es geschlossen wurde und man aufs Dock-Symbol klickt.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Task { @MainActor in MainWindow.show() } }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Merkt sich die `openWindow`-Aktion von SwiftUI, damit auch AppKit das Fenster öffnen kann.
@MainActor
enum MainWindow {
    static var open: (() -> Void)?

    static func show() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            open?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Symbol in der Menüleiste. Lebt immer, solange die App läuft – deshalb wird hier `openWindow` gemerkt.
private struct MenuBarLabel: View {
    let isRecording: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: isRecording ? "record.circle.fill" : "waveform")
            .onAppear { MainWindow.open = { openWindow(id: "main") } }
    }
}
