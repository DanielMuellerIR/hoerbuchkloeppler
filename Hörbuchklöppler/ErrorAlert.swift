import SwiftUI

extension View {
    /// Zeigt einen Hinweis, solange `message` einen Text enthält, und setzt ihn
    /// beim Schließen zurück.
    ///
    /// Vier Stellen der Oberfläche brauchten denselben Aufbau: ein `Binding`,
    /// das die Sichtbarkeit aus „Text vorhanden" ableitet, ein OK-Knopf, der den
    /// Text löscht, und ein Ersatztext für den Fall, dass er beim Zeichnen schon
    /// weg ist. Der Aufbau ist leicht falsch zu schreiben — vergisst eine Stelle
    /// das Zurücksetzen, lässt sich der Hinweis nicht mehr schließen.
    func errorAlert(
        _ title: String,
        message: Binding<String?>,
        fallback: String
    ) -> some View {
        alert(title, isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { if !$0 { message.wrappedValue = nil } }
        )) {
            // `role: .cancel` macht den Knopf zusätzlich per Escape erreichbar.
            Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? fallback)
        }
    }
}
