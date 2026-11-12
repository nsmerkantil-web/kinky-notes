import Foundation

/// Display and editing share a readable projection; stored Markdown is kept intact
/// until the user explicitly saves an edit.
enum SummaryDocument {
    struct Block: Identifiable, Equatable {
        enum Kind: Equatable { case heading, paragraph, bullet(Int) }
        let id: Int
        let kind: Kind
        let text: String
    }
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
    static func blocks(_ text: String) -> [Block] {
        var output: [Block] = []
        var paragraph: [String] = []
        func append(_ kind: Block.Kind, _ text: String) { output.append(Block(id: output.count, kind: kind, text: text)) }
        func flush() {
            if !paragraph.isEmpty { append(.paragraph, paragraph.joined(separator: " ")); paragraph = [] }
        }
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || ["---", "***", "___"].contains(line) { flush(); continue }
            if line.hasPrefix("```") || line.hasPrefix("~~~") { flush(); continue }
            if let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush(); append(.heading, String(line[range.upperBound...])); continue
            }
            // Preserve numbered list labels in readable text.
            if let range = line.range(of: #"^(?:[-*+•]|\d+[.)])\s+"#, options: .regularExpression) {
                flush()
                let indent = raw.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                let marker = String(line[..<range.upperBound]).trimmingCharacters(in: .whitespaces)
                let body = String(line[range.upperBound...])
                append(.bullet(indent >= 2 ? 1 : 0), marker.first?.isNumber == true ? marker + " " + body : body)
                continue
            }
            if line.hasPrefix("> ") { paragraph.append(String(line.dropFirst(2))); continue }
            // Plain headings from existing notes / the marker-free editor.
            if ["Решения", "Следующие шаги", "Решения и следующие шаги", "Открытые вопросы", "Темы", "Краткий пересказ"].contains(line) {
                flush(); append(.heading, line); continue
            }
            paragraph.append(line)
        }
        flush()
        return output
    }
    static func markdown(fromReadable text: String, preservingHeadingsFrom original: String) -> String {
        let headings = Set(blocks(original).filter { $0.kind == .heading }.map { String(inline($0.text).characters) })
        return text.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if headings.contains(trimmed) { return "## " + trimmed }
            if let marker = line.range(of: #"^(\s*)•\s+"#, options: .regularExpression) {
                let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
                return String(indent) + "- " + line[marker.upperBound...]
            }
            return line
        }.joined(separator: "\n")
    }
    static func plainText(_ text: String) -> String {
        blocks(text).map { block in
            let content = String(inline(block.text).characters)
            if case .bullet(let depth) = block.kind { return String(repeating: "  ", count: depth) + "• " + content }
            return content
        }.joined(separator: "\n\n")
    }
}
