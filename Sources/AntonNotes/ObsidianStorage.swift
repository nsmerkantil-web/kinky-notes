import Foundation
import CryptoKit

/// Markdown is authoritative for text. JSON contains only application metadata.
/// A three-way merge imports independent Obsidian edits and refuses conflicting edits.
final class ObsidianStorage {
    let vault: URL
    private let root: URL
    private var baseline: NoteLibrary?
    private let fm = FileManager.default
    private static let fields: [(String, WritableKeyPath<Meeting, String>)] = [
        ("Заметки.md", \.notes), ("Итог.md", \.summary), ("Транскрипт.md", \.transcript)
    ]
    struct Conflict: LocalizedError {
        let path: String
        var errorDescription: String? { "Текст изменён одновременно в Kinky Notes и Obsidian: \(path). Версия Kinky Notes сохранена в папке «Конфликты»; согласуйте тексты и повторите сохранение." }
    }
    init(root: URL, vault: URL) { self.root = root; self.vault = vault }
    func meetingURL(_ id: UUID) -> URL { vault.appendingPathComponent("Встречи/\(id.uuidString)") }
    private var metadata: URL { vault.appendingPathComponent(".anotes/library.json") }
    private func put(_ text: String, at url: URL) throws {
        if fm.fileExists(atPath: url.path), try String(contentsOf: url, encoding: .utf8) == text { return }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private func jsonString(_ value: String) -> String {
        String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
    }
    private func folderPath(_ folder: String) -> String {
        "Папки/" + SHA256.hash(data: Data(folder.utf8)).map { String(format: "%02x", $0) }.joined() + ".md"
    }
    private func link(_ path: String, _ label: String) -> String {
        let clean = label.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: " ").replacingOccurrences(of: "]", with: " ").replacingOccurrences(of: "[", with: " ")
        return "[[\(path.replacingOccurrences(of: ".md", with: ""))|\(clean)]]"
    }
    func load() throws -> NoteLibrary {
        if fm.fileExists(atPath: metadata.path) {
            let saved = try JSONDecoder().decode(NoteLibrary.self, from: Data(contentsOf: metadata))
            var library = NoteLibrary(meetings: saved.meetings, folders: saved.folders)
            for i in library.meetings.indices {
                for (file, key) in Self.fields {
                    library.meetings[i][keyPath: key] = try String(contentsOf: meetingURL(library.meetings[i].id).appendingPathComponent(file), encoding: .utf8)
                }
            }
            baseline = library
            return library
        }
        let legacy = try NoteLibrary.read(from: root)
        // Retain the original JSON byte-for-byte before migration.
        for name in ["library.json", "meetings.json"] {
            let source = root.appendingPathComponent(name)
            let backup = root.appendingPathComponent("obsidian-migration-backup/\(name)")
            if fm.fileExists(atPath: source.path), !fm.fileExists(atPath: backup.path) {
                try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: backup)
            }
        }
        return try save(legacy)
    }
    func save(_ proposed: NoteLibrary) throws -> NoteLibrary {
        var merged = proposed
        // Preflight all fields before writing any authoritative file.
        for i in merged.meetings.indices {
            let id = merged.meetings[i].id
            for (file, key) in Self.fields {
                let url = meetingURL(id).appendingPathComponent(file)
                let local = merged.meetings[i][keyPath: key]
                if let original = baseline?.meetings.first(where: { $0.id == id }) {
                    let remote = try String(contentsOf: url, encoding: .utf8)
                    let base = original[keyPath: key]
                    if remote != base && local != base && local != remote {
                        let digest = SHA256.hash(data: Data(local.utf8)).map { String(format: "%02x", $0) }.joined()
                        let conflict = vault.appendingPathComponent("Конфликты/\(id.uuidString)-\(digest)-\(file)")
                        try put(local, at: conflict)
                        throw Conflict(path: url.path)
                    }
                    if local == base { merged.meetings[i][keyPath: key] = remote }
                } else if fm.fileExists(atPath: url.path), try String(contentsOf: url, encoding: .utf8) != local {
                    throw Conflict(path: url.path)
                }
            }
        }
        // Removing a meeting in the app archives its Markdown rather than erasing it.
        for old in baseline?.meetings ?? [] where !merged.meetings.contains(where: { $0.id == old.id }) {
            let source = meetingURL(old.id)
            if fm.fileExists(atPath: source.path) {
                let archive = vault.appendingPathComponent("Архив/\(old.id.uuidString)-\(UUID().uuidString)")
                try fm.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: archive)
            }
        }
        for meeting in merged.meetings {
            for (file, key) in Self.fields {
                let target = meetingURL(meeting.id).appendingPathComponent(file)
                let text = meeting[keyPath: key]
                if fm.fileExists(atPath: target.path) {
                    let previous = try String(contentsOf: target, encoding: .utf8)
                    if previous != text {
                        let digest = SHA256.hash(data: Data(previous.utf8)).map { String(format: "%02x", $0) }.joined()
                        try put(previous, at: vault.appendingPathComponent(".anotes/history/\(meeting.id.uuidString)/\(digest)-\(file)"))
                    }
                }
                try put(text, at: target)
            }
            let index = meetingURL(meeting.id).appendingPathComponent("index.md")
            if !fm.fileExists(atPath: index.path) {
                try put("---\ntype: meeting\nsource: anotes\ntags: [anotes/meeting]\n---\n\n# Встреча\n\n\(link("Встречи/\(meeting.id.uuidString)/_index", "Тексты и сведения о встрече"))\n\nЗдесь можно добавлять теги, ссылки на темы и собственные выводы.\n", at: index)
            }
            let path = "Встречи/\(meeting.id.uuidString)/"
            let body = "# \(meeting.title.replacingOccurrences(of: "\n", with: " "))\n\nДата: \(ISO8601DateFormatter().string(from: meeting.date))\n\nПапка: \(link(folderPath(meeting.folder), meeting.folder))\n\n" + Self.fields.map { "- " + link(path + $0.0, $0.0.replacingOccurrences(of: ".md", with: "")) }.joined(separator: "\n") + "\n- \(link(path + "index", "Теги, связи и выводы"))\n\nАвтоматический индекс Kinky Notes. Свои дополнения храните в index.md.\n"
            try put(body, at: meetingURL(meeting.id).appendingPathComponent("_index.md"))
        }
        for folder in merged.folders {
            let items = merged.meetings.filter { $0.folder == folder }.sorted { $0.date > $1.date }
            try put("---\ntype: index\ntags: [anotes/folder]\n---\n\n# \(folder)\n\n" + items.map { "- " + link("Встречи/\($0.id.uuidString)/index", $0.title) }.joined(separator: "\n") + "\n\n[[Обзор]]\n\nАвтоматический индекс Kinky Notes.\n", at: vault.appendingPathComponent(folderPath(folder)))
        }
        try put("# Kinky Notes\n\nОтдельная база встреч.\n\n## Папки\n\n" + merged.folders.map { "- " + link(folderPath($0), $0) }.joined(separator: "\n") + "\n\n[[Темы/index|Темы и связи]] · [[Как пользоваться]]\n\nАвтоматический обзор Kinky Notes.\n", at: vault.appendingPathComponent("Обзор.md"))
        let guide = vault.appendingPathComponent("Как пользоваться.md")
        if !fm.fileExists(atPath: guide.path) {
            try put(Self.guide, at: guide)
            try put("# Темы\n\nДобавляйте отдельные страницы тем, людей и проектов. Связывайте их с index.md нужных встреч через [[wiki-ссылки]].\n\n[[Обзор]]\n", at: vault.appendingPathComponent("Темы/index.md"))
        }
        try fm.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        // Commit metadata last. No transcript, notes or summary content in this JSON.
        var metadataOnly = merged
        for i in metadataOnly.meetings.indices {
            for (_, key) in Self.fields { metadataOnly.meetings[i][keyPath: key] = "" }
        }
        try fm.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(metadataOnly).write(to: metadata, options: .atomic)
        for old in baseline?.meetings ?? [] where !merged.meetings.contains(where: { $0.id == old.id }) {
            // The archive and committed metadata already exist. Cleanup is best effort.
            try? fm.removeItem(at: meetingURL(old.id))
        }
        for old in baseline?.folders ?? [] where !merged.folders.contains(old) {
            try? put("# \(old)\n\nПапка переименована или удалена в Kinky Notes. Актуальная навигация: [[Обзор]].\n", at: vault.appendingPathComponent(folderPath(old)))
        }
        baseline = merged
        return merged
    }
    static let guide = """
    # Как пользоваться

    Это отдельный Obsidian vault Kinky Notes. Начните с [[Обзор]].

    - Встречи/<UUID>/Заметки.md, Итог.md и Транскрипт.md — полные тексты, доступные в Kinky Notes и Obsidian. Их можно редактировать; изменения читаются при сохранении в приложении, по кнопке «Обновить из Obsidian» и после перезапуска.
    - Встречи/<UUID>/index.md — ваша страница тегов и связей. Добавляйте теги в YAML tags или #теги, ссылки [[Темы/Проект]] и ссылки на другие встречи. Приложение её не перезаписывает.
    - Обзор.md, Папки/*.md и Встречи/*/_index.md создаются автоматически. Название, дата и папка меняются в Kinky Notes. Переименование и перемещение файлов текстов не поддерживается; удалённый файл вызывает ошибку, а не тихое восстановление старого текста.
    - Темы/ — страницы проектов, людей, понятий и выводов. Перед новой страницей ищите существующую; связывайте выводы с исходными встречами. Отделяйте факты от предположений.
    - Архив/ — тексты удалённых в Kinky Notes встреч. Аудио и служебная очередь остаются в Application Support/AntonNotes.
    - Конфликты/ — версия Kinky Notes при одновременном изменении одного текста. Версия Obsidian остаётся в исходном файле. Согласуйте тексты в обоих приложениях и повторите сохранение.

    Произвольные страницы Obsidian не становятся встречами в приложении. Семантические связи и тематические теги добавляются вручную; приложение создаёт структурные связи и служебные теги. Интеграции с M.A.K.B нет.
    """ + "\n"
}
