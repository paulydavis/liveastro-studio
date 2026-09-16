import Foundation
import LiveAstroCore

struct HelpCatalog {
    struct ArticlePart: Identifiable {
        let id: Int
        let detailTitle: String?
        let blocks: [MarkdownBlock]
    }
    /// Level-four headings are optional detail; peer/parent headings resume normal content.
    static func articleParts(_ blocks: [MarkdownBlock]) -> [ArticlePart] {
        var parts: [ArticlePart] = []
        var cursor = 0
        while cursor < blocks.count {
            if case let .heading(level, title) = blocks[cursor], level == 4 {
                let end = blocks.indices.dropFirst(cursor + 1).first {
                    if case let .heading(next, _) = blocks[$0] { return next <= 4 }
                    return false
                } ?? blocks.endIndex
                parts.append(ArticlePart(id: cursor, detailTitle: title, blocks: Array(blocks[(cursor + 1)..<end])))
                cursor = end
            } else {
                let end = blocks.indices.dropFirst(cursor + 1).first {
                    if case .heading(level: 4, text: _) = blocks[$0] { return true }
                    return false
                } ?? blocks.endIndex
                parts.append(ArticlePart(id: cursor, detailTitle: nil, blocks: Array(blocks[cursor..<end])))
                cursor = end
            }
        }
        return parts
    }
    struct Topic: Identifiable {
        let id: Int
        let title: String
        let parent: String?
        let blocks: [MarkdownBlock]
        let searchText: String
    }
    let topics: [Topic]
    init(markdown: String) {
        let blocks = MarkdownBlocks.parse(markdown)
        var result: [Topic] = []
        var parent: String?
        for (index, block) in blocks.enumerated() {
            guard case let .heading(level, title) = block, level == 2 || level == 3 else { continue }
            if level == 2 { parent = title }
            let end = blocks.indices.dropFirst(index + 1).first {
                if case let .heading(nextLevel, _) = blocks[$0] { return nextLevel <= level }
                return false
            } ?? blocks.endIndex
            // Search only this topic's own text, so a child match isn't duplicated in its parent.
            let ownEnd = blocks.indices.dropFirst(index + 1).first {
                if case let .heading(nextLevel, _) = blocks[$0] { return nextLevel <= 3 }
                return false
            } ?? blocks.endIndex
            result.append(Topic(id: index, title: title, parent: level == 3 ? parent : nil,
                blocks: Array(blocks[index..<end]),
                searchText: blocks[index..<ownEnd].map(Self.text).joined(separator: " ")))
        }
        topics = result
    }

    func search(_ query: String) -> [Topic] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return topics.filter { topic in
            words.allSatisfy { topic.searchText.localizedCaseInsensitiveContains($0) }
        }
    }

    private static func text(_ block: MarkdownBlock) -> String {
        switch block {
        case let .heading(_, text), let .paragraph(text), let .quote(text), let .codeBlock(text): return text
        case let .bulletList(items), let .numberedList(items):
            return items.flatMap { [$0.text] + $0.subItems }.joined(separator: " ")
        case let .table(headers, rows): return (headers + rows.flatMap { $0 }).joined(separator: " ")
        case .rule: return ""
        }
    }
}
