import Foundation

public enum QueryParser {
    public static func parse(
        _ raw: String,
        routes: [String: KeywordRoute],
        frontmostBundleID: String? = nil
    ) -> SearchContext {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SearchContext(rawQuery: raw, mode: .global, frontmostBundleID: frontmostBundleID)
        }

        let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        let head = String(parts[0]).lowercased()
        if let route = routes[head] {
            let unprefixed = raw.drop(while: { $0.isWhitespace })
            let separator = unprefixed.firstIndex(where: { $0.isWhitespace })
            let argument = separator.map { String(unprefixed[$0...].drop(while: { $0.isWhitespace })) } ?? ""
            return SearchContext(
                rawQuery: raw,
                mode: .keyword(providerID: route.providerID, keyword: route.keyword, argument: argument),
                frontmostBundleID: frontmostBundleID
            )
        }

        return SearchContext(rawQuery: raw, mode: .global, frontmostBundleID: frontmostBundleID)
    }
}
