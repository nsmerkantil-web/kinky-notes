import Foundation
import Testing
@testable import AntonNotes

@Test func recoveryFindsUnprocessedAudioAndFailedSummary() {
    var meeting = Meeting(title: "Call")
    #expect(ProcessingRecovery.shouldResume(meeting, audioDuration: 3600))
    #expect(!ProcessingRecovery.shouldResume(meeting, audioDuration: 0))
    meeting.transcript = "Saved transcript"
    meeting.job = ProcessingJob(stage: "Транскрипт готов; ошибка итога", error: "token repeat limit")
    #expect(ProcessingRecovery.shouldResume(meeting, audioDuration: 0))
    meeting.summary = "Done"
    #expect(!ProcessingRecovery.shouldResume(meeting, audioDuration: 3600))
    meeting.job?.pending = true
    #expect(ProcessingRecovery.shouldResume(meeting, audioDuration: 3600))
}

@Test func recoveryDoesNotLoopOnUnusableAudio() {
    for stage in ["Речь не обнаружена", "Ошибка распознавания", "Аудиозаписи нет"] {
        var meeting = Meeting(title: "Call")
        meeting.job = ProcessingJob(stage: stage)
        #expect(!ProcessingRecovery.shouldResume(meeting, audioDuration: 30))
    }
}

@Test func chunksPreserveWholeLongMultilingualTranscript() {
    let text = String(repeating: "[0 с] Привет 👨‍👩‍👧‍👦! Hello\n", count: 2000)
    let parts = SummaryService.chunks(text)
    #expect(parts.count > 1)
    #expect(parts.allSatisfy { $0.count <= 12000 })
    #expect(parts.joined() == text)
}

@MainActor @Test func retryIsImmediatelyPersistedAndSurvivesSleepAndRelaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(rootOverride: root, startServices: false)
    var meeting = Meeting(title: "Call")
    meeting.transcript = "Сохранённый транскрипт"
    meeting.job = ProcessingJob(stage: "Транскрипт готов; ошибка итога", error: "token repeat limit")
    store.meetings = [meeting]
    store.recording = true // Keep the queued job from starting a real model request.
    await store.summarize(meetingID: meeting.id)
    #expect(store.meetings[0].job?.pending == true)
    #expect(store.meetings[0].job?.error == nil)
    #expect(store.meetings[0].job?.stage.contains("В очереди") == true)
    store.pauseForSleep()
    #expect(store.meetings[0].job?.stage == "Пауза · Mac спит")
    let persisted = try store.vaultStorage.load().meetings[0]
    #expect(persisted.job?.pending == true)
    #expect(persisted.transcript == meeting.transcript)
    store.resumeAfterSleep()
    await Task.yield()
    #expect(store.meetings[0].job?.stage == "В очереди · после сна")
    let restored = Store(rootOverride: root, startServices: false)
    #expect(restored.meetings[0].job?.pending == true)
    #expect(restored.meetings[0].transcript == meeting.transcript)
    #expect(restored.meetings[0].job?.retranscribe == false)
}

final class SummaryMockProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var requests = 0
    nonisolated(unsafe) static var bodies: [[String: Any]] = []
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        let count = Self.requests
        if let body = request.httpBody, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] { Self.bodies.append(json) }
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: count == 1 ? 500 : 200, httpVersion: nil, headerFields: nil)!
        let content = Data("## Итог\n\n- Итог готов".utf8)
        let json: [String: Any] = count == 1 ? ["error": "prediction aborted, token repeat limit reached"] : ["message": ["content": String(data: content, encoding: .utf8)!]]
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor @Test func tokenRepeatFailureGetsOneBoundedRetryWithReadableOutput() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SummaryMockProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    var stages: [String] = []
    let result = try await SummaryService.request(model: "test", input: "Транскрипт", progress: { stages.append($0) }, session: session)
    #expect(result.summary.contains("Итог готов"))
    #expect(SummaryMockProtocol.requests == 2)
    #expect(stages.contains { $0.contains("Повтор генерации") })
    #expect(SummaryMockProtocol.bodies.allSatisfy { $0["format"] == nil })
}

final class SleepSummaryMockProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var requests = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        let count = Self.requests
        Self.lock.unlock()
        // The first request stays in flight until sleep cancels it.
        guard count > 1 else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        let content = Data("## Итог\n\n- После пробуждения готово".utf8)
        let response = try! JSONSerialization.data(withJSONObject: ["message": ["content": String(data: content, encoding: .utf8)!]])
        client?.urlProtocol(self, didLoad: response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor @Test func inFlightSummaryIsCancelledOnSleepAndResumedOnce() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = Store(rootOverride: root, startServices: false)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SleepSummaryMockProtocol.self]
    store.model = "test"
    store.summarySession = URLSession(configuration: config)
    defer { store.summarySession.invalidateAndCancel() }
    var meeting = Meeting(title: "Call")
    meeting.transcript = "Транскрипт"
    store.meetings = [meeting]
    let running = Task { await store.summarize(meetingID: meeting.id) }
    for _ in 0..<100 where SleepSummaryMockProtocol.requestCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(store.summarizing)
    store.pauseForSleep()
    // Exercise the wake race while the cancelled worker is still unwinding.
    store.resumeAfterSleep()
    await running.value
    for _ in 0..<200 where store.meetings[0].summary.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(store.meetings[0].summary.contains("После пробуждения готово"))
    #expect(store.meetings[0].transcript == meeting.transcript)
    #expect(store.meetings[0].job?.pending == false)
    #expect(SleepSummaryMockProtocol.requests == 2)
}

@Test func transcriptionCheckpointRetainsBothTracksAndRejectsDifferentModel() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let saved = TranscriptionCheckpoint(model: "large", lines: [.init(time: 30, text: "Текст"), .init(time: 0, text: "Hello")], offsets: ["microphone.caf": 60, "remote.caf": 30])
    try saved.save(to: url)
    let restored = TranscriptionCheckpoint.load(from: url, model: "large")
    #expect(restored.offsets == saved.offsets)
    #expect(restored.lines.map(\.text) == ["Текст", "Hello"])
    #expect(TranscriptionCheckpoint.load(from: url, model: "small").lines.isEmpty)
}

@Test func generatedMeetingTitlesAreCleanAndLimited() {
    #expect(SummaryService.cleanTitle("Название: «Дизайн Talabati и следующие шаги»") == "Дизайн Talabati и следующие шаги")
    #expect(SummaryService.cleanTitle("Обсуждение дизайна. Дополнительный текст.") == "Обсуждение дизайна")
    #expect(SummaryService.cleanTitle(String(repeating: "а", count: 161)) == nil)
    #expect(SummaryService.isPlaceholderTitle("Встреча 5 нояб. 2026"))
    #expect(!SummaryService.isPlaceholderTitle("Мой важный звонок"))
}
