import SwiftUI
import LiveAstroCore

/// Contextual help reuses the bundled manual rather than maintaining a second explanation.
struct SettingHelpButton: View {
    let sectionTitle: String
    @State private var isPresented = false
    @State private var showsFullHelp = false

    var body: some View {
        Button {
            showsFullHelp = false
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Help: \(sectionTitle)")
        .help("Explain \(sectionTitle)")
        .popover(isPresented: $isPresented) {
            VStack(spacing: 0) {
                HelpView(sectionTitle: showsFullHelp ? nil : sectionTitle)
                    .id(showsFullHelp)
                Divider()
                HStack {
                    Button(showsFullHelp ? "Back to setting" : "Read more in Help") {
                        showsFullHelp.toggle()
                    }
                    Spacer()
                    Button("Done") { isPresented = false }
                        .keyboardShortcut(.cancelAction)
                }.padding()
            }
            .frame(width: 500, height: 460)
        }
    }
}

struct HelpView: View {
    var sectionTitle: String? = nil

    /// Share a single bundled explanation between the manual and contextual help.
    static func sectionBlocks(in blocks: [MarkdownBlock], title: String) -> [MarkdownBlock] {
        guard let start = blocks.firstIndex(where: {
            if case let .heading(_, text) = $0 { return text == title }
            return false
        }), case let .heading(level, _) = blocks[start] else {
            return [.paragraph("This help topic is unavailable.")]
        }
        let end = blocks.indices.dropFirst(start + 1).first(where: {
            if case let .heading(nextLevel, _) = blocks[$0] { return nextLevel <= level }
            return false
        }) ?? blocks.endIndex
        return Array(blocks[start..<end])
    }
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

    var blocks: [MarkdownBlock] {
        guard let url = Bundle.module.url(forResource: "Help", withExtension: "md"),
              let md = try? String(contentsOf: url, encoding: .utf8)
        else { return [.paragraph("Help unavailable.")] }
        let parsed = MarkdownBlocks.parse(md)
        return sectionTitle.map { Self.sectionBlocks(in: parsed, title: $0) } ?? parsed
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
