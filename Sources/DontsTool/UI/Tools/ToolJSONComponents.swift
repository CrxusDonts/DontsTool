import DontsToolCore
import SwiftUI

struct ToolQuietButton: View {
    let title: String
    var systemImage: String? = nil
    var active = false
    var disabled = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                }
                if !title.isEmpty {
                    Text(title)
                        .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                }
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, title.isEmpty ? 7 : 9)
            .frame(height: 26)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(borderColor, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
    }

    private var foregroundColor: Color {
        if disabled { return Theme.tertiary }
        if active { return ToolTheme.accent }
        return hovering ? ToolTheme.ink : ToolTheme.secondary
    }

    private var backgroundColor: Color {
        if active { return Theme.accentFill }
        if hovering && !disabled { return Theme.controlFill }
        return Color.clear
    }

    private var borderColor: Color {
        if active { return Theme.accentBorder }
        if hovering && !disabled { return Theme.controlBorder }
        return Color.clear
    }
}

struct ToolToolbarDivider: View {
    var body: some View {
        ToolTheme.border
            .frame(width: 1, height: 15)
            .padding(.horizontal, 2)
    }
}

struct JSONStatusPill: View {
    enum Tone {
        case neutral
        case valid
        case warning
        case error
    }

    let text: String
    let tone: Tone
    var clickable = false
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action, clickable {
                Button(action: action) { pillContent }
                    .buttonStyle(.plain)
            } else {
                pillContent
            }
        }
    }

    private var pillContent: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tintColor)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(textColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(backgroundColor, in: Capsule())
        .overlay(Capsule().strokeBorder(borderColor, lineWidth: 0.5))
    }

    private var tintColor: Color {
        switch tone {
        case .neutral: Theme.tertiary
        case .valid: Theme.success
        case .warning: Theme.warning
        case .error: ToolTheme.diffRemoved
        }
    }

    private var textColor: Color {
        switch tone {
        case .neutral: ToolTheme.secondary
        case .valid: Theme.success
        case .warning: Theme.warning
        case .error: ToolTheme.diffRemoved
        }
    }

    private var backgroundColor: Color {
        switch tone {
        case .neutral: Theme.controlFill
        case .valid: Theme.success.opacity(0.11)
        case .warning: Theme.warning.opacity(0.12)
        case .error: ToolTheme.diffRemoved.opacity(0.12)
        }
    }

    private var borderColor: Color {
        switch tone {
        case .neutral: ToolTheme.border
        case .valid: Theme.success.opacity(0.28)
        case .warning: Theme.warning.opacity(0.32)
        case .error: ToolTheme.diffRemoved.opacity(0.32)
        }
    }
}

struct JSONBreadcrumbBar: View {
    let segments: [JSONBreadcrumbSegment]
    let fullPath: String
    let onSelectSegment: (JSONBreadcrumbSegment) -> Void
    let onCopyPath: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    if segments.isEmpty {
                        Text("$")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.tertiary)
                            .padding(.horizontal, 6)
                    } else {
                        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(Theme.tertiary)
                            }
                            let isLast = index == segments.count - 1
                            Button {
                                onSelectSegment(segment)
                            } label: {
                                Text(segment.label)
                                    .font(.system(size: 11, weight: isLast ? .semibold : .regular, design: .monospaced))
                                    .foregroundStyle(isLast ? ToolTheme.foldCollapsedText : ToolTheme.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2.5)
                                    .background(
                                        isLast ? Theme.accentFill : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 4.5)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4.5)
                                            .strokeBorder(isLast ? Theme.accentBorder : Color.clear, lineWidth: 0.5)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            Spacer(minLength: 4)

            if !segments.isEmpty {
                Button {
                    onCopyPath(fullPath)
                } label: {
                    Label("复制路径", systemImage: "doc.on.doc")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(ToolTheme.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("复制当前 JSONPath：\(fullPath)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(ToolTheme.gutter)
    }
}
