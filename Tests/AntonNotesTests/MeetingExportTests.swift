import XCTest
@testable import AntonNotes

final class MeetingExportTests: XCTestCase {
    func testSnapshotContainsEveryExistingTextWithoutMutatingMeeting() {
        var meeting = Meeting(title: "Дизайн / Daily")
        meeting.notes = "Мои заметки 📝"
        meeting.transcript = "[0 с] Локальный микрофон: Hello"
        meeting.summary = "## Решения\nПроверить кнопки"
        let original = meeting
        let text = MeetingExport.text(meeting)
        for value in [meeting.title, meeting.folder, meeting.notes, meeting.transcript] { XCTAssertTrue(text.contains(value)) }
        XCTAssertTrue(text.contains("Решения\n\nПроверить кнопки"))
        XCTAssertFalse(text.contains("## Решения"))
        XCTAssertEqual(meeting, original)
    }
    func testUnsafeNamesRemainOneTextFilename() {
        for title in ["../a/b:c\\d\n", "..", "", " \n", String(repeating: "д", count: 200), String(repeating: "📝", count: 200)] {
            let filename = MeetingExport.filename(Meeting(title: title))
            XCTAssertTrue(filename.hasSuffix(".txt"))
            XCTAssertFalse(filename.contains("/"))
            XCTAssertFalse(filename.contains("\\"))
            XCTAssertFalse(filename.contains(":"))
            XCTAssertFalse(filename.contains("\n"))
            XCTAssertLessThanOrEqual(filename.count, 104)
            XCTAssertLessThanOrEqual(filename.utf8.count, 204)
        }
    }
    func testUTF8WriteAndFailureAreObservable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Встреча")
        meeting.notes = "Русский и English"
        let url = root.appendingPathComponent(MeetingExport.filename(meeting))
        try MeetingExport.write(meeting, to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), MeetingExport.text(meeting))
        XCTAssertThrowsError(try MeetingExport.write(meeting, to: root.appendingPathComponent("absent/file.txt")))
    }
}
