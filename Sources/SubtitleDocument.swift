import Foundation

struct SubtitleCue: Equatable {
    let start: Double
    let end: Double
    let text: String
}

enum SubtitleDocument {
    static func parse(_ value: String) -> [SubtitleCue] {
        let text = value.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: "\n")
        var cues: [SubtitleCue] = []; var index = 0
        while index < lines.count {
            if ["NOTE", "STYLE", "REGION"].contains(where: { lines[index].hasPrefix($0) }) {
                while index < lines.count, !lines[index].isEmpty { index += 1 }
                continue
            }
            let timing = lines[index].components(separatedBy: "-->")
            guard timing.count == 2, let start = timestamp(timing[0]), let end = timestamp(timing[1]), end > start else { index += 1; continue }
            index += 1; var body: [String] = []
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                body.append(lines[index]); index += 1
            }
            let cleaned = clean(body.joined(separator: "\n"))
            if !cleaned.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: cleaned)) }
        }
        return cues.sorted { $0.start < $1.start }
    }
    static func timestamp(_ raw: String) -> Double? {
        guard let token = raw.split(whereSeparator: \.isWhitespace).first else { return nil }
        let parts = token.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let numbers = parts.compactMap { Double($0) }
        guard numbers.count == parts.count, numbers.allSatisfy({ $0.isFinite && $0 >= 0 }), numbers.last! < 60, numbers[numbers.count - 2] < 60 else { return nil }
        return numbers.reversed().enumerated().reduce(0) { $0 + $1.element * pow(60, Double($1.offset)) }
    }
    static func clean(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        for (entity, replacement) in [("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func visible(_ cues: [SubtitleCue], at time: Double) -> String {
        guard time.isFinite else { return "" }
        // Binary search the last started cue, then include overlapping dialogue lines.
        var low = 0; var high = cues.count
        while low < high { let mid = (low + high) / 2; if cues[mid].start <= time { low = mid + 1 } else { high = mid } }
        return cues.prefix(low).filter { $0.end > time }.map(\.text).joined(separator: "\n")
    }
}

struct CaptionOption: Identifiable {
    let id: String
    let label: String
    let language: String
    var external: SubtitleTrack? = nil
    var nativeIndex: Int? = nil
}

enum CaptionLanguage {
    static func normalize(_ value: String) -> String {
        let value = value.lowercased().replacingOccurrences(of: "_", with: "-")
        let names = ["english": "en", "eng": "en", "arabic": "ar", "ara": "ar", "spanish": "es", "spa": "es", "french": "fr", "fre": "fr", "japanese": "ja", "jpn": "ja", "portuguese": "pt"]
        return names[value] ?? value.split(separator: "-").first.map(String.init) ?? value
    }
    static func preferred(_ options: [CaptionOption], language: String) -> CaptionOption? {
        guard language != "off" else { return nil }
        let wanted = normalize(language)
        return options.first { normalize($0.language) == wanted || normalize($0.label) == wanted }
    }
}
