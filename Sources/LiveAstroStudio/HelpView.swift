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
            // Same permanent, space-reserving scroller as the Setup panels — walks up to the
            // enclosing NSScrollView and pins a legacy always-visible vertical scroller (and
            // sets hasVerticalScroller, so the page reliably scrolls all the way to the bottom).
            .background(AlwaysVisibleScroller())
        }
        .scrollIndicators(.visible)
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
                    listRow(marker: "•", item: item)
                }
            }

        case let .numberedList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    listRow(marker: "\(idx + 1).", item: item)
                }
            }

        case let .table(headers, rows):
            // Plain VStack/HStack layout — deliberately NOT SwiftUI `Grid`, which hangs the
            // whole app when laid out inside this ScrollView (found by smoke-testing the Help
            // tab). Columns get equal width and cells wrap; fine for Help's small tables.
            VStack(alignment: .leading, spacing: 6) {
                tableRow(headers, bold: true)
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    tableRow(row, bold: false)
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

        case let .codeBlock(code):
            // Verbatim monospace — no inline() so backticks/asterisks in a command stay literal.
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 5))

        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    /// One list entry: its marker + text, then any nested sub-bullets indented beneath it.
    @ViewBuilder
    private func listRow(marker: String, item: ListItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).monospacedDigit()
                Text(inline(item.text)).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(item.subItems.enumerated()), id: \.offset) { _, sub in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("◦")
                    Text(inline(sub)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 18)
            }
        }
    }

    /// One table row rendered without `Grid`: equal-width columns, wrapping cells.
    @ViewBuilder
    private func tableRow(_ cells: [String], bold: Bool) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(inline(cell))
                    .bold(bold)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
