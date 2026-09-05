import Foundation

/// Ein konstanter Buchpegel erhält die Dynamik zwischen Kapiteln und Split-Dateien.
/// LUFS bezeichnet die wahrgenommene Lautheit; dBTP den geschätzten True Peak.
struct LoudnessMeasurement: Sendable {
    let integratedLUFS: Double
    let truePeakDB: Double
    var gainDB: Double { min(-18 - integratedLUFS, -1 - truePeakDB) }
    var description: String { "Buchlautheit: \(integratedLUFS) LUFS, True Peak: \(truePeakDB) dBTP" }

    static func parse(_ output: Data) throws -> Self {
        let text = String(decoding: output, as: UTF8.self)
        guard let start = text.range(of: "{", options: .backwards),
              let end = text.range(of: "}", range: start.lowerBound..<text.endIndex),
              let data = String(text[start.lowerBound..<end.upperBound]).data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let integrated = object["input_i"].flatMap(Double.init),
              let peak = object["input_tp"].flatMap(Double.init),
              integrated.isFinite, peak.isFinite else {
            throw NSError(domain: "Loudness", code: 1, userInfo: [NSLocalizedDescriptionKey: "Keine endliche Buchlautheit messbar (z. B. Stille oder zu kurzer Inhalt)."])
        }
        return Self(integratedLUFS: integrated, truePeakDB: peak)
    }
}
