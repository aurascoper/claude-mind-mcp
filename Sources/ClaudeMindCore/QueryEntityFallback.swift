import Foundation

/// v2.6: lowercase name-like candidate generator for the entity-mention seed
/// branch.
///
/// Phase 3a surfaced that NLTagger (and our acronym fallback) extracts
/// nothing from casual lowercase queries like "did i tell sarah about pearl
/// health today" — so the entity branch never fires even when the corpus
/// has a "Pearl Health" entity that would lower-case match.
///
/// This function generates candidate entity strings *only* when normal NER
/// returns nothing. It's deliberately conservative:
///
/// - lowercase tokenize
/// - drop stopwords + short tokens (< 4 chars)
/// - emit individual tokens AND adjacent bigrams (so "pearl health" hits)
/// - cap to MAX_CANDIDATES so a chatty query doesn't drag down the entity
///   branch with dozens of probably-irrelevant lookups
///
/// SQL side already lower-cases `entities.canonical_name` for matching, so no
/// schema change is needed.
public enum QueryEntityFallback {
    /// Common English stopwords + first-person + question words. Conservative
    /// list — over-inclusion just means slightly less recall on the entity
    /// branch, which the lexical branch should still cover.
    private static let stop: Set<String> = [
        "the","a","an","this","that","these","those",
        "and","or","but","so","if","then","else","also","just","than",
        "is","are","was","were","be","been","being","am","do","does","did","done",
        "have","has","had","having","will","would","can","could","should","may","might","must",
        "i","me","my","mine","we","us","our","ours","you","your","yours",
        "he","him","his","she","her","hers","they","them","their","theirs",
        "it","its","there","here","where","when","what","who","which","why","how",
        "to","of","in","on","at","by","for","with","from","about","into","over","under","up","down",
        "as","like","than","through","during","before","after","while","since","until","because",
        "any","some","all","each","every","both","other","another","such","same","more","most","much","many","few","several",
        "no","not","yes","ok","okay","well","really","very","much","just","only","also",
        "what","which","who","whom","whose","when","where","why","how","whether",
        "say","said","tell","told","ask","asked","know","knew","think","thought","feel","felt",
        "go","went","come","came","get","got","make","made","take","took","give","gave",
        "talk","talked","write","wrote","read","saw","see","seen","look","looked",
        "today","yesterday","tomorrow","now","then","later","soon","ago","since",
        "around","near","after","before","during","while",
        "thing","things","stuff","something","nothing","anything","everything",
        "people","person","everyone","someone","anyone",
    ]

    /// Hard caps to keep the entity branch's SQL `= ANY($1::text[])` from blowing
    /// up on long chatty queries. ~12 candidates is plenty for any real query.
    private static let MAX_CANDIDATES = 12
    private static let MIN_TOKEN_LEN = 4

    /// Returns lowercase candidate entity strings derived from the query.
    /// Empty list if the query has no useful tokens.
    public static func candidates(from query: String) -> [String] {
        let tokens = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.count >= MIN_TOKEN_LEN && !stop.contains($0) }

        // Unigrams + adjacent bigrams. Bigrams catch "pearl health" /
        // "auth migration" / "blue bottle" — the cases where the entity is
        // a multi-word lowercase phrase NLTagger would have caught if it
        // were properly capitalized.
        var out: [String] = []
        for t in tokens { out.append(t) }
        for i in 0..<max(0, tokens.count - 1) {
            out.append("\(tokens[i]) \(tokens[i + 1])")
        }

        // Dedupe preserving order, then cap.
        var seen = Set<String>()
        var deduped: [String] = []
        for s in out {
            if seen.insert(s).inserted { deduped.append(s) }
        }
        if deduped.count > MAX_CANDIDATES {
            deduped = Array(deduped.prefix(MAX_CANDIDATES))
        }
        return deduped
    }
}
