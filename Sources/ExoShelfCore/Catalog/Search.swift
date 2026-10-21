import Foundation

/// Search over the catalogue: every word of the query must appear in the
/// title, developer, publisher, genres, series or year. Results rank
/// title matches first.
public struct CatalogSearch: Sendable {
    private let entries: [(game: Game, text: String, title: String)]

    public init(_ games: [Game]) {
        entries = games.map { ($0, Self.fold($0.searchText), Self.fold($0.title)) }
    }

    public func search(_ query: String, in subset: Set<String>? = nil) -> [Game] {
        let words = Self.fold(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else {
            return entries.filter { subset?.contains($0.game.id) ?? true }.map(\.game)
        }
        let phrase = words.joined(separator: " ")
        var scored: [(Int, Game)] = []
        for e in entries where subset?.contains(e.game.id) ?? true {
            guard words.allSatisfy({ e.text.contains($0) }) else { continue }
            let score: Int
            if e.title == phrase { score = 0 }
            else if e.title.hasPrefix(phrase) { score = 1 }
            else if e.title.contains(phrase) { score = 2 }
            else if words.allSatisfy({ e.title.contains($0) }) { score = 3 }
            else { score = 4 }
            scored.append((score, e.game))
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.sortTitle.localizedStandardCompare($1.1.sortTitle) == .orderedAscending }.map(\.1)
    }

    /// Lowercase, accents dropped, punctuation turned into spaces, so
    /// "kings quest" finds "King's Quest" and "ultima vi" finds "Ultima VI:".
    static func fold(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var out = ""
        out.reserveCapacity(folded.count)
        var lastSpace = true
        for ch in folded.unicodeScalars {
            if ch == "'" || ch == "’" { continue }
            if CharacterSet.alphanumerics.contains(ch) {
                out.unicodeScalars.append(ch)
                lastSpace = false
            } else if !lastSpace {
                out.append(" ")
                lastSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
