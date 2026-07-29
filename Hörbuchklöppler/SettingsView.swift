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
                Section(header: Text("Kanal & Qualität").foregroundColor(.secondary)) {
                    Picker("Modus", selection: $session.settings.isMono) {
                        Text("Mono").tag(true); Text("Stereo").tag(false)
                    }.pickerStyle(.segmented)

                    Picker("Bitrate", selection: $session.settings.bitrate) {
                        ForEach(visibleBitrates, id: \.self) { Text($0).tag($0) }
                    }
                    // Alte Ein-Parameter-onChange-Signatur (statt der Sonoma-
                    // Formen), damit macOS 13 als Deployment-Target reicht.
                    .onChange(of: session.settings.isMono) { _ in
                        let currentList = session.settings.isMono ? monoBitrates : stereoBitrates
                        if !currentList.contains(session.settings.bitrate) {
                            session.settings.bitrate = currentList.first ?? "48k"
                        }
                    }

                    Picker("Abtastrate", selection: $session.settings.sampleRate) {
                        ForEach(visibleSampleRates, id: \.self) { Text("\($0) Hz").tag($0) }
                    }
                }

                Section(header: Text("Performance & Optimierung").foregroundColor(.secondary)) {
                    Toggle("Paralleles Kodieren und Stream Copy", isOn: $session.settings.useParallelEncoding)
                        .help("Nutzt alle CPU-Kerne parallel und fügt die Dateien ohne erneute Kodierung zusammen.")
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
        .alert("Einstellungen konnten nicht gespeichert werden", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "Unbekannter Fehler")
        }
        .onAppear {
            // Local state sync
            isUnlimited = session.settings.maxDurationHours == nil
            maxHours = session.settings.maxDurationHours ?? 10
            maxSliderUpperBound = max(24, maxHours)
        }
    }
}
