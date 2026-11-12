import XCTest
@testable import AntonNotes

final class NoteLibraryTests: XCTestCase {
    func testEmptyFolderSurvivesReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var library = NoteLibrary(meetings: [])
        try library.createFolder("  Проекты  ")
        try library.write(to: root)
        XCTAssertEqual(try NoteLibrary.read(from: root).folders, ["Входящие", "Проекты"])
    }
    func testRenameMoveAndDeleteFolderPreserveNotes() throws {
        let meeting = Meeting(title: "Звонок")
        var library = NoteLibrary(meetings: [meeting])
        try library.createFolder("Работа")
        try library.move(meeting.id, to: "Работа")
        try library.renameFolder("Работа", to: "Проекты")
        XCTAssertEqual(library.meetings.first?.folder, "Проекты")
        try library.deleteFolder("Проекты")
        XCTAssertEqual(library.meetings.first?.folder, "Входящие")
        XCTAssertEqual(library.meetings.first?.id, meeting.id)
        XCTAssertThrowsError(try library.deleteFolder("Входящие"))
    }
    func testInvalidNamesAndMovesDoNotChangeData() throws {
        let meeting = Meeting(title: "Звонок")
        var library = NoteLibrary(meetings: [meeting])
        try library.createFolder("Работа")
        XCTAssertThrowsError(try library.createFolder(" работа "))
        XCTAssertThrowsError(try library.createFolder(" \n"))
        XCTAssertThrowsError(try library.move(meeting.id, to: "Нет папки"))
        XCTAssertEqual(library.meetings.first?.folder, "Входящие")
    }
    func testLegacyMigrationAndDeletionPersist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Звонок")
        meeting.folder = "Работа"
        try JSONEncoder().encode([meeting]).write(to: root.appendingPathComponent("meetings.json"))
        var library = try NoteLibrary.read(from: root)
        XCTAssertTrue(library.folders.contains("Работа"))
        library.deleteMeeting(meeting.id)
        try library.write(to: root)
        let loaded = try NoteLibrary.read(from: root)
        XCTAssertTrue(loaded.meetings.isEmpty)
        XCTAssertTrue(loaded.folders.contains("Работа"))
    }
}
