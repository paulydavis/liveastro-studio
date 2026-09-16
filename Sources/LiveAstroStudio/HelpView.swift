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
    @State private var query = ""
    @State private var selectedTopic: String?
    @State private var selectedGroup: HelpGroup?
    @State private var lastTopicID: Int?
    @State private var overviewRequest = 0

    private static let markdown = Bundle.module.url(forResource: "Help", withExtension: "md")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    private static let catalog = HelpCatalog(markdown: markdown ?? "")

    private enum HelpGroup: String, CaseIterable, Identifiable {
        case start = "Get started", settings = "Understand a setting", problems = "Fix a problem"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .start: return "sparkles"
            case .settings: return "slider.horizontal.3"
            case .problems: return "stethoscope"
            }
        }
        var summary: String {
            switch self {
            case .start: return "Connect your source, prepare calibration and start a session."
            case .settings: return "What each control does, when to use it and what to check."
            case .problems: return "No images, rejected subs, dust shadows or a delayed broadcast."
            }
        }
        func includes(_ topic: HelpCatalog.Topic) -> Bool {
            let section = topic.parent ?? topic.title
            switch self {
            case .start: return ["Quick Start", "Source Modes", "Try Without a Telescope", "OBS and Go Live", "Scene Automation", "Broadcast setups", "Session Outputs"].contains(section)
            case .settings: return ["Capture settings", "Display Adjustments", "Calibration", "Reseed Reference"].contains(section)
            case .problems: return section == "Troubleshooting"
            }
        }
    }

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
        Group {
            if sectionTitle != nil {
                article
            } else {
                browser
            }
        }
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if selectedTopic != nil {
                    Button { selectedTopic = nil } label: { Label("Back", systemImage: "chevron.left") }
                }
                Text("Help").font(.title2.weight(.medium))
                Spacer()
                Button("All topics") {
                    selectedTopic = nil; selectedGroup = nil; query = ""; lastTopicID = nil
                    overviewRequest += 1
                }
            }.padding(20)
            if let selectedTopic {
                HelpView(sectionTitle: selectedTopic).id(selectedTopic)
            } else {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search settings, calibration or a problem", text: $query)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Search Help")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }
                .padding(12).background(SetupStyle.panel, in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 20).padding(.bottom, 12)
                ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Color.clear.frame(height: 0).id("help-top")
                        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ForEach(HelpGroup.allCases) { group in
                                Button { selectedGroup = selectedGroup == group ? nil : group; lastTopicID = nil } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: group.symbol).frame(width: 24).foregroundStyle(SetupStyle.accent)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(group.rawValue).font(.headline)
                                            Text(group.summary).font(.callout).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: selectedGroup == group ? "chevron.down" : "chevron.right")
                                    }.padding(14).background(SetupStyle.panel, in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                            }
                        }
                        Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                             ? selectedGroup?.rawValue ?? "All topics" : "Search results")
                            .font(.headline).padding(.top, 8)
                        let results = Self.catalog.search(query).filter {
                            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedGroup?.includes($0) != false
                        }
                        if results.isEmpty {
                            Text(Self.markdown == nil ? "Help unavailable. The bundled manual could not be loaded."
                                 : "No matching topics. Try a shorter phrase such as ‘flats’, ‘rejected’ or ‘OBS’.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(results) { topic in
                            Button { lastTopicID = topic.id; selectedTopic = topic.title } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(topic.title).foregroundStyle(.primary)
                                        if let parent = topic.parent { Text(parent).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(SetupStyle.accent)
                                }.contentShape(Rectangle()).padding(.vertical, 4)
                            }.buttonStyle(.plain).id(topic.id)
                            Divider()
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .background(AlwaysVisibleScroller())
                }
                .onAppear {
                    if let lastTopicID { scroll.scrollTo(lastTopicID, anchor: .center) }
                }
                .onChange(of: query) { _, _ in
                    lastTopicID = nil
                    scroll.scrollTo("help-top", anchor: .top)
                }
                .onChange(of: overviewRequest) { _, _ in scroll.scrollTo("help-top", anchor: .top) }
                }
            }
        }
        .background(SetupStyle.background)
        .environment(\.colorScheme, .dark)
        .tint(SetupStyle.accent)
    }

    private var article: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(HelpCatalog.articleParts(blocks)) { part in
                    if let title = part.detailTitle {
                        DisclosureGroup(title) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(part.blocks.enumerated()), id: \.offset) { _, block in view(for: block) }
                            }.padding(.top, 8)
                        }
                    } else {
                        ForEach(Array(part.blocks.enumerated()), id: \.offset) { _, block in view(for: block) }
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 740, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            // Same permanent, space-reserving scroller as the Setup panels — walks up to the
            // enclosing NSScrollView and pins a legacy always-visible vertical scroller (and
            // sets hasVerticalScroller, so the page reliably scrolls all the way to the bottom).
            .background(AlwaysVisibleScroller())
        }
        .scrollIndicators(.visible)
    }

    var blocks: [MarkdownBlock] {
        guard let md = Self.markdown
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
