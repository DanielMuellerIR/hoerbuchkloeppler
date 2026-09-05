import HoerbuchkloepplerCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var session: ConversionSession
    @Binding var isPresented: Bool
    @State private var isUnlimited = true
    @State private var maxHours: Int = 10
    @State private var maxSliderUpperBound: Int = 24
    @State private var saveError: String?

    let monoBitrates = ["24k", "32k", "48k", "64k", "96k", "128k"]
    let stereoBitrates = ["48k", "64k", "96k", "128k", "160k", "192k", "256k"]
    let sampleRates = [8000, 16000, 22050, 32000, 44100, 48000]

    private var visibleBitrates: [String] {
        let supported = session.settings.isMono ? monoBitrates : stereoBitrates
        return supported.contains(session.settings.bitrate)
            ? supported
            : [session.settings.bitrate] + supported
    }

    private var visibleSampleRates: [Int] {
        sampleRates.contains(session.settings.sampleRate)
            ? sampleRates
            : [session.settings.sampleRate] + sampleRates
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Audio Kodierung").font(.headline).padding()
            Form {
                Section(header: Text("Qualitätsprofil")) {
                    Menu("Profil anwenden") {
                        ForEach(AudioQualityProfile.allCases) { profile in
                            Button(profile.title) { session.settings = profile.applying(to: session.settings) }
                        }
                    }
                    Text("Profile setzen Kanäle, Bitrate und Abtastrate. Alle Werte bleiben danach einzeln änderbar.")
                        .font(.caption)
                }
                Section(header: Text("Kanal & Qualität").foregroundColor(.secondary)) {
                    Picker("Modus", selection: $session.settings.isMono) {
                        Text("Mono").tag(true); Text("Stereo").tag(false)
                    }.pickerStyle(.segmented)

                    Picker("Bitrate", selection: $session.settings.bitrate) {
                        ForEach(visibleBitrates, id: \.self) { Text($0).tag($0) }
                    }

                    Picker("Abtastrate", selection: $session.settings.sampleRate) {
                        ForEach(visibleSampleRates, id: \.self) { Text("\($0) Hz").tag($0) }
                    }
                }

                Section(header: Text("Performance & Optimierung").foregroundColor(.secondary)) {
                    Picker("Maximale Prozesse", selection: $session.settings.workerLimit) {
                        Text("Automatisch (höchstens 4)").tag(Int?.none)
                        ForEach(1...32, id: \.self) { Text(String($0)).tag(Int?.some($0)) }
                    }
                    Toggle("Paralleles Kodieren und Stream Copy", isOn: $session.settings.useParallelEncoding)
                    Text(session.settings.useParallelEncoding
                         ? "Performance: Kapitel einzeln als AAC kodieren, dann ohne erneute Kodierung verbinden. Weniger temporärer Speicher; AAC-Padding kann Übergänge verschieben."
                         : "Standard: Abschnitte als WAV vorbereiten, danach einmal durchgehend als AAC kodieren. Mehr temporärer Speicher; geeignet für durchgehende Musik.")
                        .font(.caption)
                }

                Section(header: Text("Maximale Dauer").foregroundColor(.secondary)) {
                    Toggle("Unlimitiert", isOn: Binding(
                        get: { self.isUnlimited },
                        set: { newValue in
                            self.isUnlimited = newValue
                            session.settings.maxDurationHours = newValue ? nil : maxHours
                        }
                    ))
                    if !isUnlimited {
                        HStack {
                            Text("Max. Länge: \(maxHours) Std.")
                                .frame(width: 120, alignment: .leading)
                            Slider(value: Binding(
                                get: { Double(maxHours) },
                                set: { maxHours = Int($0) }
                            ), in: 1...Double(maxSliderUpperBound), step: 1)
                            .onChange(of: maxHours) { newValue in
                                session.settings.maxDurationHours = max(1, newValue)
                            }
                        }
                    }
                }
            }.formStyle(.grouped).padding()

            Button("Fertig") {
                do {
                    try SettingsManager.shared.saveSettings(session.settings)
                    isPresented = false
                } catch {
                    saveError = error.localizedDescription
                }
            }
            .padding().keyboardShortcut(.defaultAction)
        }
        .frame(width: 450)
        .errorAlert(
            "Einstellungen konnten nicht gespeichert werden",
            message: $saveError,
            fallback: "Unbekannter Fehler"
        )
        .onAppear {
            // Local state sync
            isUnlimited = session.settings.maxDurationHours == nil
            maxHours = session.settings.maxDurationHours ?? 10
            maxSliderUpperBound = max(24, maxHours)
        }
    }
}
