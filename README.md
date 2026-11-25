# Cadence

**Meetings lokal mitschreiben – mit Sprecherzuordnung.**
Cadence ist eine native macOS-App, die den Ton deiner Meeting-App (Teams, Zoom, Google Meet, Webex, Browser, …) und dein Mikrofon als **getrennte Spuren** aufnimmt, beides **lokal auf deinem Mac** transkribiert und jedem Satz die richtige Person und Partei zuordnet. Kein Bot im Meeting, keine Cloud.

## Was Cadence kann (v0.1)

| | |
|---|---|
| 🎙️ **Zwei Spuren** | Mikrofon = du, Systemaudio = die Gegenseite. Deine Beiträge sind dadurch automatisch richtig zugeordnet. |
| 🧩 **Jede Meeting-App** | „Gesamter Systemton“ funktioniert mit allem; optional nur eine bestimmte App (inkl. Hilfsprozesse wie Teams-WebView). |
| 📝 **Lokale Transkription** | [WhisperKit](https://github.com/argmaxinc/WhisperKit) auf der Neural Engine, Deutsch/Englisch/automatisch. Live während des Gesprächs. |
| 🗣️ **Wer spricht?** | Live per Klick, per **⌃⌥1–9** (funktioniert auch, wenn Teams vorne ist) oder Namen eintippen + ⏎. |
| 🧠 **Sprechertrennung** | Nach dem Gespräch trennt [SpeakerKit](https://github.com/argmaxinc/WhisperKit) (pyannote, lokal) die Stimmen. Jede Stimme bekommt automatisch die Person, die du live am häufigsten markiert hast – ein, zwei Markierungen pro Person reichen. |
| 🏢 **Parteien** | „Wir“, „Kunde“ und beliebig weitere (Partner, Dienstleister …). Personen lassen sich verschieben und umbenennen. |
| ⭐️ **Marker & Notizen** | Wichtig / Aufgabe / Entscheidung / Notiz mit Zeitstempel, live per Hotkey oder aus jedem Satz heraus. |
| 🛡️ **Einwilligung** | Erinnerung vor jeder Aufnahme mit kopierbarem Hinweistext; die Bestätigung landet im Protokoll. |
| 💾 **Speichern & Export** | Pro Gespräch ein Ordner mit `session.json`, `transkript.md`, `protokoll.md` und Audio (`mikrofon.m4a`, `system.m4a`, `gesamt.m4a`). Export als Markdown, Protokoll, JSON, SRT, Text. |
| ▶️ **Nachbearbeiten** | Doppelklick auf einen Satz spielt die Stelle ab, Sätze umbenennen/zuordnen/korrigieren, „ab hier spricht …“, Suche, Redeanteile. |

## Voraussetzungen

- macOS **14.4** oder neuer (für Core-Audio-Process-Taps), Apple Silicon empfohlen
- Xcode 16 (bzw. die Command Line Tools mit Swift 5.10+)
- Beim ersten Start ca. 1,6 GB Download für das Sprachmodell „Large v3 Turbo“ (kleinere Modelle in den Einstellungen)

## Bauen & starten

```bash
git clone https://github.com/robinvonmises/cadence.git
cd cadence
./scripts/build-app.sh
open build/Cadence.app
```

Das Skript baut das Swift-Paket im Release-Modus, packt es als `Cadence.app` (mit `Info.plist` für die Berechtigungen) und signiert es ad hoc.
Ohne eigenen Build: Jeder Push baut die App per GitHub Actions; unter **Actions → Build → Artifacts** liegt `Cadence.zip`. Beim ersten Öffnen Rechtsklick → **Öffnen**, weil die App nicht notarisiert ist.

**Tipp:** Ad-hoc signierte Builds „vergisst“ macOS bei jedem Neubau, dann wird erneut nach den Berechtigungen gefragt. Mit eigenem Zertifikat bleibt es stabil:

```bash
CODESIGN_IDENTITY="Apple Development: Dein Name (TEAMID)" ./scripts/build-app.sh
```

**In Xcode entwickeln:** `brew install xcodegen && xcodegen` erzeugt `Cadence.xcodeproj` (siehe `project.yml`). Alternativ `open Package.swift` – dann aber über `build-app.sh` starten, weil ein nacktes Executable keine Mikrofonfreigabe bekommt.

**Tests:** `swift test` (Sprecherzuordnung, Abschnittserkennung, Export).

## Berechtigungen – wie macOS das handhabt

| Berechtigung | Wofür | Wo |
|---|---|---|
| **Mikrofon** | deine Spur | Abfrage beim ersten Start; sonst *Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon* |
| **Systemaudioaufnahme** | Ton der Meeting-App | Abfrage beim ersten Aufnahmestart; sonst *Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme → „Nur Systemaudio“* |

Cadence nutzt dafür die Core-Audio-Process-Taps von macOS. Anders als bei ScreenCaptureKit ist **keine Bildschirmaufnahme** nötig, du hörst alles ganz normal weiter, und es erscheint kein Bot im Meeting.
Die globalen Tastenkürzel brauchen **keine** Bedienungshilfen-Freigabe.

**Kopfhörer empfohlen:** Ohne Kopfhörer landet die Gegenseite über die Lautsprecher auch in deinem Mikrofon. Dafür gibt es in den Einstellungen die Echounterdrückung.

## Bedienung im Gespräch

1. Titel eingeben, Quelle wählen („Gesamter Systemton“ passt fast immer), **Aufnahme starten**.
2. Die Einwilligung bestätigen (der Hinweistext lässt sich in den Teams-Chat kopieren).
3. Wenn jemand von der Gegenseite spricht: Name eintippen + ⏎ (beim ersten Mal) bzw. **⌃⌥1–9** / Klick auf den Namen. **⌃⌥0** = unbekannt. **⌃⌥N** holt Cadence nach vorn ins Namensfeld.
4. **⌃⌥M / A / E** markieren eine wichtige Stelle / Aufgabe / Entscheidung. Notizen gehen im rechten Panel.
5. **Beenden**: Cadence transkribiert den Rest, trennt die Stimmen, ordnet zu und speichert alles.
6. Danach unter „Erkannte Stimmen“ prüfen, ob jede Stimme der richtigen Person zugeordnet ist, und bei Bedarf Protokoll exportieren.

| Kürzel | Aktion |
|---|---|
| ⌃⌥1 … 9 | Person Nr. n spricht (Reihenfolge der Teilnehmerliste, nach Partei) |
| ⌃⌥0 | Sprecher unbekannt |
| ⌃⌥N | Cadence nach vorn, neuen Namen eintippen |
| ⌃⌥M / A / E | Wichtig / Aufgabe / Entscheidung |
| ⌃⌥R | Aufnahme beenden |
| ⌘1 … 9, ⌘0, ⌘M, ⌘. | dasselbe, wenn Cadence im Vordergrund ist |

## Architektur

```
Sources/
├── CadenceCore/            plattformunabhängig, getestet
│   ├── Models.swift          Session, Party, Person, TranscriptSegment, SpeakerTag, Marker
│   ├── SpeakerResolver.swift Mikrofon + Live-Tags + Diarization-Cluster → Person
│   ├── SpeechChunker.swift   Energie-VAD: Audio → sprachnahe Abschnitte für Whisper
│   ├── SessionEditing.swift  Bearbeiten (zuordnen, umbenennen, Marker …)
│   └── Exporters.swift       Markdown, Protokoll, JSON, SRT, Text
└── Cadence/                macOS-App (SwiftUI)
    ├── Audio/                Core Audio Process Tap, Mikrofon, Konvertierung, M4A, Mixdown
    ├── Transcription/        WhisperKit- und SpeakerKit-Anbindung
    ├── Storage/              Ordner pro Gespräch
    ├── Hotkeys/              systemweite Tastenkürzel (Carbon)
    └── Views/                Live-Ansicht, Nachbearbeitung, Einstellungen, Menüleiste
```

Ablauf: **Tap/Mikrofon → 48 kHz mono → M4A** und parallel **→ 16 kHz → Abschnittserkennung → WhisperKit → Segmente**. Die Sprecherzuordnung wird bei jeder Änderung neu berechnet. Rangfolge: manuell > Stimme (Cluster) > Live-Hotkey. Nach dem Stoppen läuft die Diarization auf der Systemspur.

## Roadmap / Ideen

- [ ] **Sprecherprofile:** Stimmen über Gespräche hinweg wiedererkennen (SpeakerKit liefert bereits Stimm-Embeddings pro Cluster)
- [ ] **Live-Diarization** während des Gesprächs statt erst danach
- [ ] **Zusammenfassung & Aufgaben** automatisch, lokal (z. B. Apple Foundation Models / MLX), optional per API
- [ ] **Kalender-Integration:** Titel und Teilnehmer aus dem Termin übernehmen; Auto-Start, wenn Teams einen Anruf beginnt
- [ ] **Hochpräzise Nachtranskription** der ganzen Datei mit Wortzeitstempeln
- [ ] **Echo-Duplikate entfernen**, wenn ohne Kopfhörer gesprochen wird
- [ ] Pause/Fortsetzen, Fachbegriffe/Glossar als Prompt für Whisper
- [ ] Export nach Word/PDF, Notion, Confluence, OneNote
- [ ] App-Icon, Notarisierung, Sparkle-Updates

## Rechtlicher Hinweis

Das Aufzeichnen nicht öffentlich gesprochener Worte ohne Einwilligung ist in Deutschland strafbar (§ 201 StGB); für personenbezogene Daten gilt die DSGVO. Cadence erinnert dich vor jeder Aufnahme daran und dokumentiert die Bestätigung. Die Verantwortung liegt bei dir.
