import Foundation
import CoreFoundation

struct AppSearchDocument {
    let displayName: String
    let url: URL
    private let names: [FuzzyMatcher.PreparedCandidate]
    private let aliases: [FuzzyMatcher.PreparedCandidate]

    init(entry: AppEntry) {
        displayName = entry.displayName
        url = entry.url
        let sourceNames = Set([entry.displayName, entry.url.deletingPathExtension().lastPathComponent])
        names = sourceNames.map(FuzzyMatcher.PreparedCandidate.init)

        var derived: Set<String> = []
        for name in sourceNames {
            let candidate = FuzzyMatcher.PreparedCandidate(name)
            if candidate.words.count > 1 {
                derived.insert(candidate.words.joined())
                derived.insert(candidate.words.compactMap(\.first).map(String.init).joined())
                let lastWord = candidate.words.last ?? ""
                let leadingInitials = candidate.words.dropLast().compactMap(\.first).map(String.init).joined()
                derived.insert(leadingInitials + lastWord)
            }

            guard name.unicodeScalars.contains(where: { $0.properties.isIdeographic }),
                  let latin = name.applyingTransform(.toLatin, reverse: false) else { continue }
            let pinyin = FuzzyMatcher.PreparedCandidate(latin)
            derived.insert(pinyin.words.joined())
            derived.insert(pinyin.words.compactMap(\.first).map(String.init).joined())
            derived.formUnion(Self.wordPinyinAliases(for: name))
        }
        aliases = derived.filter { !$0.isEmpty }.map(FuzzyMatcher.PreparedCandidate.init)
    }

    func matchesShortcut(_ normalizedKeyword: String) -> Bool {
        names.contains { $0.normalized == normalizedKeyword || $0.words.contains(normalizedKeyword) }
            || aliases.contains { $0.normalized == normalizedKeyword }
    }

    func score(normalizedQuery: String, compactQuery: String) -> Double? {
        let direct = names.compactMap {
            FuzzyMatcher.score(normalizedQuery: normalizedQuery, candidate: $0)
        }.max()

        // Keep literal names ahead of aliases, even after the usage boost.
        if let direct, direct >= 650 { return 1000 + direct }

        let alias = aliases.compactMap {
            FuzzyMatcher.score(normalizedQuery: compactQuery, candidate: $0)
        }.filter { $0 >= 650 }.max()
        if let alias { return 800 + alias / 10 }
        return direct
    }

    private static func wordPinyinAliases(for name: String) -> Set<String> {
        let text = name as CFString
        let locale = NSLocale(localeIdentifier: "zh_CN") as CFLocale
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            text,
            CFRangeMake(0, CFStringGetLength(text)),
            kCFStringTokenizerUnitWord,
            locale
        )
        var spelling = ""
        var spellingWithV = ""
        var initials = ""
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let token = (name as NSString).substring(with: NSRange(location: range.location, length: range.length))
            if token.unicodeScalars.contains(where: { $0.properties.isIdeographic }) {
                let transcription = CFStringTokenizerCopyCurrentTokenAttribute(
                    tokenizer, kCFStringTokenizerAttributeLatinTranscription
                ) as? String ?? token.applyingTransform(.toLatin, reverse: false) ?? token
                // Word transcription resolves readings such as 音乐; tone digits mark syllable boundaries.
                let numeric = transcription.applyingTransform(
                    StringTransform(rawValue: "Latin-NumericPinyin"), reverse: false
                ) ?? transcription
                let syllables = numeric.components(separatedBy: .decimalDigits).filter { !$0.isEmpty }
                spelling += FuzzyMatcher.normalize(syllables.joined())
                spellingWithV += FuzzyMatcher.normalize(syllables.joined().replacingOccurrences(of: "ü", with: "v"))
                initials += syllables.compactMap { FuzzyMatcher.normalize($0).first }.map(String.init).joined()
            } else {
                let literal = FuzzyMatcher.PreparedCandidate(token).words.joined()
                spelling += literal
                spellingWithV += literal
                initials += literal
            }
        }
        return Set([spelling, spellingWithV, initials]).filter { !$0.isEmpty }
    }
}
