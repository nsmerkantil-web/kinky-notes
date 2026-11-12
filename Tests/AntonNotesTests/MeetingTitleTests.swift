import Foundation
import Testing
@testable import AntonNotes

private final class TitleProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"message":{"content":"Дизайн новостей и сроки релиза"},"done_reason":"stop"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor @Test func relaunchRecoversMissingTitlesWithoutRecreatingSummaries() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(rootOverride: root, startServices: false)
    var automatic = Meeting(title: "Встреча 6 нояб. 2026 г., 15:11")
    automatic.summary = "## Новости\n\nОбсудили дизайн новостей и сроки релиза."
    var custom = automatic
    custom.id = UUID(); custom.title = "Моё название"
    store.meetings = [automatic, custom]; store.save()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TitleProtocol.self]
    store.summarySession = URLSession(configuration: configuration)
    defer { store.summarySession.invalidateAndCancel() }
    store.model = "test"
    await store.recoverMeetingTitles()
    #expect(store.meetings[0].title == "Дизайн новостей и сроки релиза")
    #expect(store.meetings[0].summary == automatic.summary)
    #expect(store.meetings[1].title == custom.title)
    let reloaded = try store.vaultStorage.load()
    #expect(reloaded.meetings.first(where: { $0.id == automatic.id })?.title == "Дизайн новостей и сроки релиза")
}
