import Foundation
import NaturalLanguage

/// Splits text into speakable sentence segments for the synthesis pipeline.
/// NLTokenizer does the heavy lifting; a merge pass repairs splits after
/// abbreviations and ordinals and absorbs very short fragments, and a hard
/// split caps unpunctuated walls of text.
enum SentenceSegmenter {
    /// Suffixes after which a sentence break is almost certainly wrong.
    private static let abbreviationSuffixes = [
        "Dr.", "Prof.", "Nr.", "ca.", "usw.", "bzw.", "ggf.", "evtl.",
        "inkl.", "exkl.", "Abs.", "Str.", "Mio.", "Mrd.", "vgl.", "bzgl.",
    ]

    static func segments(for text: String, minLength: Int = 25, maxLength: Int = 500) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmed
        var raw: [String] = []
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let piece = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { raw.append(piece) }
            return true
        }
        if raw.isEmpty { raw = [trimmed] }

        var merged: [String] = []
        for piece in raw {
            if let last = merged.last, shouldMerge(after: last, minLength: minLength) {
                merged[merged.count - 1] = last + " " + piece
            } else {
                merged.append(piece)
            }
        }

        return merged.flatMap { hardSplit($0, maxLength: maxLength) }
    }

    private static func shouldMerge(after previous: String, minLength: Int) -> Bool {
        if previous.count < minLength { return true }
        if abbreviationSuffixes.contains(where: previous.hasSuffix) { return true }
        // Single letter + period ("z.", "B.", "S.") or an ordinal ("am 3.").
        if previous.range(of: #"(^|\s)\w\.$"#, options: .regularExpression) != nil { return true }
        if previous.range(of: #"\d{1,2}\.$"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// Split an overlong segment at the last comma (preferred) or space.
    private static func hardSplit(_ text: String, maxLength: Int) -> [String] {
        guard text.count > maxLength else { return [text] }
        var rest = Substring(text)
        var parts: [String] = []
        while rest.count > maxLength {
            let window = rest.prefix(maxLength)
            let cut = window.lastIndex(of: ",").map(window.index(after:))
                ?? window.lastIndex(of: " ")
                ?? window.endIndex
            let head = rest[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
            if !head.isEmpty { parts.append(head) }
            rest = rest[cut...]
        }
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { parts.append(tail) }
        return parts
    }
}
