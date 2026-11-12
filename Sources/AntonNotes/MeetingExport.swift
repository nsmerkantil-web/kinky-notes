import Foundation

/// A portable snapshot; exporting never changes the stored meeting.
enum MeetingExport {
    static func text(_ meeting: Meeting) -> String {
        var sections = [meeting.title, meeting.date.formatted(date: .long, time: .shortened), "Папка: \(meeting.folder)"]
        for (heading, body) in [("Итог", SummaryDocument.plainText(meeting.summary)), ("Заметки", meeting.notes), ("Транскрипт", meeting.transcript)] {
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sections.append("\(heading)\n\n\(body)") }
        }
        return sections.joined(separator: "\n\n") + "\n"
    }
    static func filename(_ meeting: Meeting) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        let cleaned = meeting.title.components(separatedBy: invalid).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        var name = cleaned.isEmpty || cleaned.allSatisfy({ $0 == "." }) ? "Встреча" : String(cleaned.prefix(100))
        while name.utf8.count > 200 { name.removeLast() }
        return name + ".txt"
    }
    static func write(_ meeting: Meeting, to url: URL) throws {
        try text(meeting).write(to: url, atomically: true, encoding: .utf8)
    }
}
