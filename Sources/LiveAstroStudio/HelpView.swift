import SwiftUI
import LiveAstroCore

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private var blocks: [MarkdownBlock] {
        guard let url = Bundle.module.url(forResource: "Help", withExtension: "md"),
              let md = try? String(contentsOf: url, encoding: .utf8)
        else { return [.paragraph("Help unavailable.")] }
        return MarkdownBlocks.parse(md)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inline(text))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 8 : 4)

        case let .paragraph(text):
            Text(inline(text))
                .fixedSize(horizontal: false, vertical: true)

        case let .bulletList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(inline(item)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case let .numberedList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(idx + 1).").monospacedDigit()
                        Text(inline(item)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case let .table(headers, rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, h in
                        Text(inline(h)).bold()
                    }
                }
                GridRow {
                    Divider().gridCellColumns(headers.count)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(inline(cell)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.vertical, 4)

        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary)
                    .frame(width: 3)
                Text(inline(text)).italic().fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4))

        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title.bold()
        case 2: return .title2.bold()
        case 3: return .headline
        default: return .subheadline.bold()
        }
    }

    /// Interpret inline markdown only (bold/italic/code); block structure is
    /// already handled by MarkdownBlocks. Falls back to the raw string.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
