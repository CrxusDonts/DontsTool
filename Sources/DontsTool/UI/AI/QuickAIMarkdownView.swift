import AppKit
import SwiftUI

enum QuickAIMarkdownBlock: Equatable, Identifiable {
    case prose(id: Int, text: String)
    case codeBlock(id: Int, language: String?, code: String, isClosed: Bool)

    var id: Int {
        switch self {
        case .prose(let id, _), .codeBlock(let id, _, _, _):
            id
        }
    }
}

enum QuickAIMarkdownParser {
    static func parse(_ source: String) -> [QuickAIMarkdownBlock] {
        guard !source.isEmpty else { return [] }
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var blocks: [QuickAIMarkdownBlock] = []
        var proseLines: [String] = []
        var codeLines: [String] = []
        var activeFenceChar: Character?
        var activeFenceCount = 0
        var activeLanguage: String?
        var nextID = 0

        func flushProse() {
            let trimmed = proseLines
                .drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                .reversed()
                .drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                .reversed()
            let joined = joinedLines(Array(trimmed))
            if !joined.isEmpty {
                blocks.append(.prose(id: nextID, text: joined))
                nextID += 1
            }
            proseLines.removeAll(keepingCapacity: true)
        }

        for line in lines {
            if let fenceChar = activeFenceChar {
                if isClosingFence(line, char: fenceChar, minCount: activeFenceCount) {
                    blocks.append(.codeBlock(
                        id: nextID,
                        language: activeLanguage,
                        code: joinedLines(codeLines),
                        isClosed: true
                    ))
                    nextID += 1
                    codeLines.removeAll(keepingCapacity: true)
                    activeFenceChar = nil
                    activeFenceCount = 0
                    activeLanguage = nil
                } else {
                    codeLines.append(line)
                }
            } else if let opening = parseOpeningFence(line) {
                flushProse()
                activeFenceChar = opening.char
                activeFenceCount = opening.count
                activeLanguage = opening.language
            } else {
                proseLines.append(line)
            }
        }

        if activeFenceChar != nil {
            blocks.append(.codeBlock(
                id: nextID,
                language: activeLanguage,
                code: joinedLines(codeLines),
                isClosed: false
            ))
        } else {
            flushProse()
        }

        return blocks
    }

    private static func joinedLines(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    private static func parseOpeningFence(_ line: String) -> (char: Character, count: Int, language: String?)? {
        var leadingSpaces = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " ", leadingSpaces < 3 {
            leadingSpaces += 1
            idx = line.index(after: idx)
        }
        guard idx < line.endIndex else { return nil }
        let fenceChar = line[idx]
        guard fenceChar == "`" || fenceChar == "~" else { return nil }

        var count = 0
        while idx < line.endIndex, line[idx] == fenceChar {
            count += 1
            idx = line.index(after: idx)
        }
        guard count >= 3 else { return nil }

        let rest = String(line[idx...]).trimmingCharacters(in: .whitespaces)
        if fenceChar == "`", rest.contains("`") {
            return nil
        }
        let language = rest.split(whereSeparator: \.isWhitespace).first.map(String.init)
        return (char: fenceChar, count: count, language: language?.isEmpty == true ? nil : language)
    }

    private static func isClosingFence(_ line: String, char: Character, minCount: Int) -> Bool {
        var leadingSpaces = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " ", leadingSpaces < 3 {
            leadingSpaces += 1
            idx = line.index(after: idx)
        }
        var count = 0
        while idx < line.endIndex, line[idx] == char {
            count += 1
            idx = line.index(after: idx)
        }
        guard count >= minCount else { return false }
        return line[idx...].allSatisfy { $0 == " " || $0 == "\t" }
    }
}

struct QuickAIMarkdownView: View {
    let text: String

    var body: some View {
        let blocks = QuickAIMarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                switch block {
                case .prose(_, let prose):
                    QuickAIProseView(text: prose)
                case .codeBlock(_, let language, let code, let isClosed):
                    QuickAICodeBlockView(language: language, code: code, isClosed: isClosed)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QuickAIProseView: View {
    let text: String

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                lineView(for: line)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func lineView(for rawLine: String) -> some View {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Color.clear.frame(height: 4)
        } else if trimmed.hasPrefix("### ") {
            inlineMarkdownText(String(trimmed.dropFirst(4)))
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.top, 4)
        } else if trimmed.hasPrefix("## ") {
            inlineMarkdownText(String(trimmed.dropFirst(3)))
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.top, 5)
        } else if trimmed.hasPrefix("# ") {
            inlineMarkdownText(String(trimmed.dropFirst(2)))
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.top, 6)
        } else if trimmed.hasPrefix("> ") {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.accent.opacity(0.6))
                    .frame(width: 2.5)
                inlineMarkdownText(String(trimmed.dropFirst(2)))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.vertical, 2)
        } else if let bullet = extractBullet(rawLine) {
            HStack(alignment: .top, spacing: 7) {
                Text(bullet.marker)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                inlineMarkdownText(bullet.body)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(min(bullet.indent, 4)) * 8)
        } else {
            inlineMarkdownText(rawLine)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
                .lineSpacing(3)
        }
    }

    private func inlineMarkdownText(_ source: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(source)
    }

    private func extractBullet(_ raw: String) -> (indent: Int, marker: String, body: String)? {
        let leadingSpaces = raw.prefix(while: { $0 == " " }).count
        let trimmed = raw.dropFirst(leadingSpaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
            return (indent: leadingSpaces / 2, marker: "•", body: String(trimmed.dropFirst(2)))
        }
        if let dotIndex = trimmed.firstIndex(of: ".") {
            let prefix = trimmed[..<dotIndex]
            let afterDot = trimmed.index(after: dotIndex)
            if !prefix.isEmpty,
               prefix.count <= 3,
               prefix.allSatisfy(\.isNumber),
               afterDot < trimmed.endIndex,
               trimmed[afterDot] == " " {
                let bodyStart = trimmed.index(after: afterDot)
                return (indent: leadingSpaces / 2, marker: "\(prefix).", body: String(trimmed[bodyStart...]))
            }
        }
        return nil
    }
}

private struct QuickAICodeBlockView: View {
    let language: String?
    let code: String
    let isClosed: Bool

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language?.isEmpty == false ? language! : "代码")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
                if !isClosed {
                    Text("生成中…")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.tertiary)
                }
                Spacer()
                Button {
                    copyCode()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10.5, weight: .medium))
                        Text(copied ? "已复制" : "复制代码")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(copied ? Theme.success : Theme.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.controlFill.opacity(0.6))

            Theme.separator.frame(height: 0.5)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .background(Theme.controlFill.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.controlBorder, lineWidth: 0.5)
        )
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            copied = false
        }
    }
}
