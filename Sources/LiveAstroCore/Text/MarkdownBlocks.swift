import Foundation

/// A block-level element of a limited markdown subset. Inline markup
/// (**bold**, *italic*, `code`) is preserved verbatim inside each block's
/// text — the renderer is responsible for interpreting it.
public enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulletList([String])
    case numberedList([String])
    case table(headers: [String], rows: [[String]])
    case quote(String)
    case rule
}

/// Parses the block structure of the markdown subset used by Help.md.
/// Deliberately NOT a full CommonMark parser (YAGNI): it handles ATX
/// headings, paragraphs, `-`/`*` bullet lists, `N.` numbered lists, GitHub
/// pipe tables, `>` blockquotes, and `---` rules. Anything else is treated
/// as paragraph text.
public enum MarkdownBlocks {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []

        var para: [String] = []
        var bullets: [String] = []
        var numbers: [String] = []
        var quotes: [String] = []

        func flushPara()    { if !para.isEmpty    { blocks.append(.paragraph(para.joined(separator: " "))); para = [] } }
        func flushBullets() { if !bullets.isEmpty { blocks.append(.bulletList(bullets)); bullets = [] } }
        func flushNumbers() { if !numbers.isEmpty { blocks.append(.numberedList(numbers)); numbers = [] } }
        func flushQuotes()  { if !quotes.isEmpty  { blocks.append(.quote(quotes.joined(separator: " "))); quotes = [] } }
        func flushAll()     { flushPara(); flushBullets(); flushNumbers(); flushQuotes() }

        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            if line.isEmpty { flushAll(); i += 1; continue }

            if line == "---" { flushAll(); blocks.append(.rule); i += 1; continue }

            if let h = headingMatch(line) { flushAll(); blocks.append(.heading(level: h.0, text: h.1)); i += 1; continue }

            // Pipe table: a '|' line immediately followed by a separator row.
            if line.hasPrefix("|"), i + 1 < lines.count,
               isTableSeparator(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                flushAll()
                let headers = tableCells(line)
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count {
                    let cand = lines[j].trimmingCharacters(in: .whitespaces)
                    guard cand.hasPrefix("|") else { break }
                    rows.append(tableCells(cand)); j += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                i = j; continue
            }

            if let b = bulletMatch(line) { flushPara(); flushNumbers(); flushQuotes(); bullets.append(b); i += 1; continue }
            if let n = numberMatch(line) { flushPara(); flushBullets(); flushQuotes(); numbers.append(n); i += 1; continue }
            if let q = quoteMatch(line)  { flushPara(); flushBullets(); flushNumbers(); quotes.append(q); i += 1; continue }

            // Default: paragraph text (soft-break joins with following plain lines).
            flushBullets(); flushNumbers(); flushQuotes()
            para.append(line)
            i += 1
        }
        flushAll()
        return blocks
    }

    // MARK: - Line matchers

    private static func headingMatch(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("#") else { return nil }
        let chars = Array(line)
        var level = 0
        while level < chars.count && chars[level] == "#" { level += 1 }
        guard (1...6).contains(level), level < chars.count, chars[level] == " " else { return nil }
        let text = String(chars[(level + 1)...]).trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private static func bulletMatch(_ line: String) -> String? {
        let chars = Array(line)
        guard chars.count >= 2, chars[0] == "-" || chars[0] == "*", chars[1] == " " else { return nil }
        return String(chars[2...]).trimmingCharacters(in: .whitespaces)
    }

    private static func numberMatch(_ line: String) -> String? {
        let chars = Array(line)
        var k = 0
        while k < chars.count && chars[k].isNumber { k += 1 }
        guard k > 0, k + 1 < chars.count, chars[k] == ".", chars[k + 1] == " " else { return nil }
        return String(chars[(k + 2)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func quoteMatch(_ line: String) -> String? {
        guard line.hasPrefix(">") else { return nil }
        return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.contains("-") else { return false }
        return line.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    private static func tableCells(_ line: String) -> [String] {
        var parts = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.first == "" { parts.removeFirst() }
        if parts.last == "" { parts.removeLast() }
        return parts
    }
}
