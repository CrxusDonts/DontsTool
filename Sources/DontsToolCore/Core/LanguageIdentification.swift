import Foundation
import NaturalLanguage

public protocol LanguageIdentifying: Sendable {
    func dominantLanguageCode(of text: String) -> String?
}

public struct NaturalLanguageIdentifier: LanguageIdentifying {
    public init() {}

    public func dominantLanguageCode(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }
}
