#!/usr/bin/env bash
# Kleiner Linux-Probeweg, kein Build oder Abnahmetest der vollständigen CLI.
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
[ "$(uname -s)" = Linux ] || { echo 'Dieser Versuch benötigt Linux.' >&2; exit 1; }
for tool in swiftc ffmpeg ffprobe; do
  command -v "$tool" >/dev/null || { echo "Werkzeug fehlt: $tool" >&2; exit 1; }
done
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/hk-linux-core.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT

cat > "$work_dir/main.swift" <<'SWIFT'
import Foundation

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--inspect" {
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let chapters = object["chapters"] as! [[String: Any]]
    precondition(chapters.count == 2)
    for (index, chapter) in chapters.enumerated() {
        let tags = chapter["tags"] as! [String: String]
        precondition(tags["title"] == (index == 0 ? "Kapitel eins" : "Kapitel zwei"))
        precondition(abs(Double(chapter["start_time"] as! String)! - Double(index)) < 0.001)
        precondition(abs(Double(chapter["end_time"] as! String)! - Double(index + 1)) < 0.001)
    }
    let audio = (object["streams"] as! [[String: Any]]).first { ($0["codec_type"] as? String) == "audio" }!
    precondition(audio["codec_name"] as? String == "aac")
    precondition(audio["sample_rate"] as? String == "32000")
    precondition(audio["channels"] as? Int == 1)
    precondition(abs(Double(audio["duration"] as! String)! - 2) < 0.1)
    print("LINUX_AUDIO_OK: AAC, Mono, 32000 Hz, zwei Kapitel mit geprüften Zeiten/Titeln")
} else {
    let directory = URL(fileURLWithPath: CommandLine.arguments[1])
    precondition(AudioSettings.bitsPerSecond("48k") == 48_000)
    precondition(AudioSettings.isValidBitrate("8k"))
    precondition(AudioSettings.isValidBitrate("320k"))
    precondition(!AudioSettings.isValidBitrate("7k"))
    let data = Data(#"{"isMono":false,"bitrate":"kaputt","sampleRate":1,"importWorkerLimit":99}"#.utf8)
    let normalized = try JSONDecoder().decode(AudioSettings.self, from: data).normalized()
    precondition(!normalized.isMono && normalized.bitrate == "48k")
    precondition(normalized.sampleRate == 32_000 && normalized.importWorkerLimit == 4)
    precondition(AudioSettings(workerLimit: 0).effectiveWorkerLimit == 1)
    let manager = SettingsManager(settingsURL: directory.appendingPathComponent("settings.json"))
    try manager.saveSettings(AudioSettings(isMono: false, useParallelEncoding: false))
    precondition(!manager.loadSettings().isMono && manager.loadSettings().useParallelEncoding)
    let measurement = try LoudnessMeasurement.parse(Data(#"{"input_i":"-20","input_tp":"-5"}"#.utf8))
    precondition(measurement.gainDB == 2)
    print("LINUX_MODELS_OK: AudioSettings, SettingsManager, LoudnessMeasurement aus dem unveränderten Core")
}
SWIFT

core_dir="$repo_dir/HoerbuchkloepplerCore/Sources/HoerbuchkloepplerCore"
swiftc -swift-version 6 -warnings-as-errors \
  "$core_dir/AudioSettings.swift" "$core_dir/SettingsManager.swift" \
  "$core_dir/LoudnessMeasurement.swift" "$work_dir/main.swift" -o "$work_dir/probe"
"$work_dir/probe" "$work_dir"

cat > "$work_dir/chapters.txt" <<'METADATA'
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=1000
title=Kapitel eins
[CHAPTER]
TIMEBASE=1/1000
START=1000
END=2000
title=Kapitel zwei
METADATA

ffmpeg -nostdin -v error -f lavfi -i 'sine=frequency=440:sample_rate=32000:duration=2' \
  -i "$work_dir/chapters.txt" -map 0:a -map_metadata 1 -map_chapters 1 \
  -ac 1 -ar 32000 -c:a aac -b:a 48k -movflags +faststart "$work_dir/book.m4b"
ffprobe -v error -show_streams -show_chapters -of json "$work_dir/book.m4b" > "$work_dir/inspection.json"
"$work_dir/probe" --inspect "$work_dir/inspection.json"
ffmpeg -nostdin -v error -xerror -i "$work_dir/book.m4b" -map 0:a:0 -f null -
printf '%s\n' 'LINUX_DECODE_OK: vollständig ohne Fehler dekodiert'
