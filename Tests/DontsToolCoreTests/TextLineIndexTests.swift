import Foundation
import Testing
@testable import DontsToolCore

@Suite("原生编辑器行号")
struct TextLineIndexTests {
    @Test(arguments: ["\n", "\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}"])
    func recognizesNativeLineSeparators(_ separator: String) {
        let text = "first" + separator + "second" + separator
        let index = TextLineIndex(text)
        let secondStart = 5 + separator.utf16.count
        #expect(index.lineNumber(atUTF16Offset: 0) == 1)
        #expect(index.lineNumber(atUTF16Offset: secondStart - 1) == 1)
        #expect(index.lineNumber(atUTF16Offset: secondStart) == 2)
        #expect(index.lineNumber(atUTF16Offset: text.utf16.count) == 3)
    }

    @Test func tracksUTF16OffsetsAcrossSurrogatePairsAndMixedSeparators() {
        let index = TextLineIndex("😀\r\n中\u{2028}𠀀\n")
        for (offset, line) in [1, 1, 1, 1, 2, 2, 3, 3, 3, 4].enumerated() {
            #expect(index.lineNumber(atUTF16Offset: offset) == line)
        }
    }

    @Test func matchesFoundationNativeLineBoundaries() {
        let text = "😀\r\n中\r尾\nnext\u{85}nel\u{2028}line\u{2029}paragraph"
        let native = text as NSString
        let index = TextLineIndex(text)
        var position = 0
        var expectedLine = 1
        while position < native.length {
            let line = native.lineRange(for: NSRange(location: position, length: 0))
            for offset in line.location..<NSMaxRange(line) {
                #expect(index.lineNumber(atUTF16Offset: offset) == expectedLine)
            }
            position = NSMaxRange(line)
            expectedLine += 1
        }
    }

    @Test func emptyTextAndClampedPositionsStayOnAnExistingLine() {
        #expect(TextLineIndex("").lineNumber(atUTF16Offset: 0) == 1)
        let index = TextLineIndex("a\nb")
        #expect(index.lineNumber(atUTF16Offset: -1) == 1)
        #expect(index.lineNumber(atUTF16Offset: 100) == 2)
    }
}
