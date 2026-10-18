/// Logical line numbers using the UTF-16 offsets supplied by native text layout.
public struct TextLineIndex {
    private var lineStarts = [0]

    public init(_ text: String) {
        var previous: UInt16?
        for (offset, codeUnit) in text.utf16.enumerated() {
            if codeUnit == 10, previous == 13 {
                // CRLF is one separator; its second code unit stays on the preceding line.
                lineStarts[lineStarts.count - 1] = offset + 1
            } else if codeUnit == 10 || codeUnit == 13 || codeUnit == 0x85
                || codeUnit == 0x2028 || codeUnit == 0x2029 {
                lineStarts.append(offset + 1)
            }
            previous = codeUnit
        }
    }

    public func lineNumber(atUTF16Offset offset: Int) -> Int {
        var low = 0, high = lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= offset { low = middle + 1 }
            else { high = middle }
        }
        return max(1, low)
    }
}
