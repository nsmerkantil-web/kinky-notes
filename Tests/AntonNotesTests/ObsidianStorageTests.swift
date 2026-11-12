import XCTest
@testable import AntonNotes

final class ObsidianStorageTests: XCTestCase {
    private func fixture(_ work: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try work(root, root.appendingPathComponent("vault"))
    }
    func testMigrationPreservesExactTextsIdentityAndLegacyBackup() throws {
        try fixture { root, vault in
            var meeting = Meeting(title: "Встреча / [[проект]]")
            meeting.notes = "# Идея\n[[Тема]] #проект\n\n"
            meeting.summary = "Решено: проверить"
            meeting.transcript = "[0 с] Локальный микрофон: Привет\n"
            try NoteLibrary(meetings: [meeting], folders: ["Пустая"]).write(to: root)
            let original = try Data(contentsOf: root.appendingPathComponent("library.json"))
            let storage = ObsidianStorage(root: root, vault: vault)
            let loaded = try storage.load()
            XCTAssertEqual(loaded.meetings, [meeting])
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("obsidian-migration-backup/library.json")), original)
            let reloaded = try ObsidianStorage(root: root, vault: vault).load()
            XCTAssertEqual(reloaded.meetings, [meeting])
            XCTAssertTrue(reloaded.folders.contains("Пустая"))
            let metadata = try JSONDecoder().decode(NoteLibrary.self, from: Data(contentsOf: vault.appendingPathComponent(".anotes/library.json")))
            XCTAssertEqual(metadata.meetings.first?.transcript, "")
            XCTAssertEqual(metadata.meetings.first?.summary, "")
            XCTAssertEqual(metadata.meetings.first?.notes, "")
        }
    }
    func testIndependentExternalAndApplicationEditsMergeAndUserLinksSurvive() throws {
        try fixture { root, vault in
            let storage = ObsidianStorage(root: root, vault: vault)
            _ = try storage.load()
            var meeting = Meeting(title: "Звонок")
            meeting.notes = "Исходный текст"
            var library = try storage.save(NoteLibrary(meetings: [meeting]))
            let notes = storage.meetingURL(meeting.id).appendingPathComponent("Заметки.md")
            try "Правка Obsidian\n[[Темы/Работа]] #работа".write(to: notes, atomically: true, encoding: .utf8)
            let index = storage.meetingURL(meeting.id).appendingPathComponent("index.md")
            try "---\ntags: [работа]\n---\n[[Темы/Работа]]".write(to: index, atomically: true, encoding: .utf8)
            library.meetings[0].summary = "Итог A-notes"
            let merged = try storage.save(library)
            XCTAssertTrue(merged.meetings[0].notes.contains("Правка Obsidian"))
            XCTAssertEqual(merged.meetings[0].summary, "Итог A-notes")
            XCTAssertTrue(try String(contentsOf: index, encoding: .utf8).contains("tags: [работа]"))
            XCTAssertEqual(try storage.load().meetings, merged.meetings)
        }
    }
    func testConcurrentSameFieldDoesNotOverwriteEitherVersion() throws {
        try fixture { root, vault in
            let storage = ObsidianStorage(root: root, vault: vault)
            _ = try storage.load()
            let meeting = Meeting(title: "Конфликт")
            var library = try storage.save(NoteLibrary(meetings: [meeting]))
            let url = storage.meetingURL(meeting.id).appendingPathComponent("Заметки.md")
            try "Obsidian".write(to: url, atomically: true, encoding: .utf8)
            library.meetings[0].notes = "A-notes"
            XCTAssertThrowsError(try storage.save(library))
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Obsidian")
            let conflicts = try FileManager.default.contentsOfDirectory(at: vault.appendingPathComponent("Конфликты"), includingPropertiesForKeys: nil)
            XCTAssertEqual(try String(contentsOf: XCTUnwrap(conflicts.first), encoding: .utf8), "A-notes")
        }
    }
    func testDeletionArchivesAndMissingFileFailsClosed() throws {
        try fixture { root, vault in
            let storage = ObsidianStorage(root: root, vault: vault)
            _ = try storage.load()
            var meeting = Meeting(title: "Источник")
            meeting.transcript = "Оригинал"
            _ = try storage.save(NoteLibrary(meetings: [meeting]))
            _ = try storage.save(NoteLibrary(meetings: []))
            let archive = try FileManager.default.contentsOfDirectory(at: vault.appendingPathComponent("Архив"), includingPropertiesForKeys: nil)
            XCTAssertEqual(try String(contentsOf: XCTUnwrap(archive.first).appendingPathComponent("Транскрипт.md"), encoding: .utf8), "Оригинал")
            XCTAssertTrue(try storage.load().meetings.isEmpty)
            _ = try storage.save(NoteLibrary(meetings: [meeting]))
            try FileManager.default.removeItem(at: storage.meetingURL(meeting.id).appendingPathComponent("Заметки.md"))
            XCTAssertThrowsError(try storage.save(NoteLibrary(meetings: [meeting])))
            XCTAssertThrowsError(try ObsidianStorage(root: root, vault: vault).load())
        }
    }
}
