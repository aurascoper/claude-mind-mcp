import Foundation
import NaturalLanguage

/// Shared NER for both the AppleNLPEnricher and the CoreMLEnricher.
///
/// Two passes:
///   1. NLTagger nameType (PersonalName, PlaceName, OrganizationName).
///   2. Acronym/uppercase fallback. NLTagger doesn't classify technical
///      acronyms like `TWAP`, `OBI`, `HIP-3` as named entities — but those
///      are exactly the things memory queries hinge on. We supplement with a
///      regex pass tagged as `Acronym`.
///
/// Span offsets are character offsets, not UTF-16, since the rest of the
/// pipeline serializes via Foundation's String distance API.
public enum EntityExtractor {
    private static let acronymRegex = try! NSRegularExpression(
        pattern: #"\b([A-Z]{2,}[0-9]*(?:[._-][A-Z0-9]+)*)\b"#
    )

    public static func extract(text: String) -> [DetectedEntity] {
        var out: [DetectedEntity] = []
        var seenSpans = Set<Range<String.Index>>()

        // Pass 1: NLTagger nameType
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let opts: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        let allowed: Set<String> = ["PersonalName", "PlaceName", "OrganizationName"]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: opts) { tag, range in
            if let tag, allowed.contains(tag.rawValue) {
                seenSpans.insert(range)
                let start = text.distance(from: text.startIndex, to: range.lowerBound)
                let end   = text.distance(from: text.startIndex, to: range.upperBound)
                out.append(DetectedEntity(value: String(text[range]), type: tag.rawValue, start: start, end: end))
            }
            return true
        }

        // Pass 2: acronym/uppercase fallback. Skips spans NLTagger already
        // claimed and a small noise list.
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        acronymRegex.enumerateMatches(in: text, range: nsRange) { match, _, _ in
            guard let match, let r = Range(match.range, in: text) else { return }
            let token = String(text[r])
            if Self.acronymNoise.contains(token) { return }
            // Skip if NLTagger already extracted an overlapping span.
            for prior in seenSpans where prior.overlaps(r) { return }
            let start = text.distance(from: text.startIndex, to: r.lowerBound)
            let end   = text.distance(from: text.startIndex, to: r.upperBound)
            out.append(DetectedEntity(value: token, type: "Acronym", start: start, end: end))
        }
        return out
    }

    // Common acronyms that show up in commit messages and headers but aren't
    // useful as memory entities. Trimmed conservatively.
    private static let acronymNoise: Set<String> = [
        "I", "II", "III", "IV", "TODO", "FIXME", "WIP", "OK",
        "YES", "NO", "HTTP", "HTTPS", "URL", "URI", "API",
        "JSON", "XML", "YAML", "CSV", "TSV", "UTF", "ASCII",
        "BUG", "PR", "CI"
    ]
}

private extension Range where Bound == String.Index {
    func overlaps(_ other: Range<String.Index>) -> Bool {
        return !(self.upperBound <= other.lowerBound || other.upperBound <= self.lowerBound)
    }
}
