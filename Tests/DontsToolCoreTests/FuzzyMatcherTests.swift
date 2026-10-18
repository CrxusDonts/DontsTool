import Testing
@testable import DontsToolCore

@Suite("FuzzyMatcher")
struct FuzzyMatcherTests {
    @Test func exactMatchWins() {
        #expect(FuzzyMatcher.score(query: "Chrome", candidate: "Chrome") == 1000)
    }

    @Test func prefixBeatsWordPrefix() {
        let prefix = FuzzyMatcher.score(query: "chr", candidate: "Chrome")!
        let wordPrefix = FuzzyMatcher.score(query: "chr", candidate: "Google Chrome")!
        #expect(prefix == 900)
        #expect(wordPrefix == 800)
        #expect(prefix > wordPrefix)
    }

    @Test func substringScoresAboveSubsequence() {
        let substring = FuzzyMatcher.score(query: "rome", candidate: "Chrome")!
        let subsequence = FuzzyMatcher.score(query: "gcm", candidate: "Google Chrome")!
        #expect(substring >= 650)
        #expect(subsequence >= 300 && subsequence <= 600)
    }

    @Test func caseAndDiacriticsAreIgnored() {
        #expect(FuzzyMatcher.score(query: "cafe", candidate: "Café") == 1000)
    }

    @Test func unmatchedReturnsNil() {
        #expect(FuzzyMatcher.score(query: "xyz", candidate: "Chrome") == nil)
    }

    @Test func emptyQueryReturnsNil() {
        #expect(FuzzyMatcher.score(query: "  ", candidate: "Chrome") == nil)
    }
}
