import Foundation
import Testing
@testable import AntonNotes

@Test func existingMarkdownRendersHeadingsParagraphsAndNestedListsWithoutMarkers() {
    let source = "### Темы\n\nПервый абзац\nпродолжается.\n\n* **Дизайн:** конкретный факт\n  - Подробность с [источником](https://example.com)\n\n## Решения\n\nОставить 2 * 3 = 6."
    let blocks = SummaryDocument.blocks(source)
    #expect(blocks.count == 6)
    #expect(blocks[0].kind == .heading)
    #expect(blocks[1].text == "Первый абзац продолжается.")
    #expect(blocks[2].kind == .bullet(0))
    #expect(blocks[3].kind == .bullet(1))
    let plain = SummaryDocument.plainText(source)
    #expect(!plain.contains("###"))
    #expect(!plain.contains("**"))
    #expect(plain.contains("• Дизайн: конкретный факт"))
    #expect(plain.contains("  • Подробность с источником"))
    #expect(plain.contains("2 * 3 = 6"))
    #expect(SummaryDocument.plainText("Абзац\n\n***\n\nДругой абзац") == "Абзац\n\nДругой абзац")
    let saved = SummaryDocument.markdown(fromReadable: plain, preservingHeadingsFrom: source)
    #expect(saved.contains("## Темы"))
    #expect(saved.contains("## Решения"))
    #expect(SummaryDocument.plainText(saved) == plain)
}

@Test func readableFormattingDoesNotInventSectionsForLegacySingleParagraph() {
    let source = "Длинный старый итог без разметки.\r\nПродолжение абзаца.\r\n\r\nОтдельный абзац."
    #expect(SummaryDocument.blocks(source).map(\.kind) == [.paragraph, .paragraph])
    #expect(SummaryDocument.plainText(source) == "Длинный старый итог без разметки. Продолжение абзаца.\n\nОтдельный абзац.")
}

@Test func chunkingKeepsTurnsTogetherAndRetainsEndOfMeeting() {
    let input = "TURN 0: начало\nTURN 1: решение\nTURN 2: конец"
    let parts = SummaryService.chunks(input, limit: 20)
    #expect(parts.joined() == input)
    #expect(parts[0] == "TURN 0: начало\n")
    #expect(parts.last?.contains("конец") == true)
    #expect(SummaryService.chunks("abc", limit: 0).joined() == "abc")
}

private final class NotesProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var requests: [String: [[String: Any]]] = [:]
    static func recorded(_ model: String) -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return requests[model] ?? [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
        }
        let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let model = body["model"] as? String ?? "unknown"
        Self.lock.lock(); Self.requests[model, default: []].append(body); let index = Self.requests[model]!.count; Self.lock.unlock()
        let prose = "## Тема \(index)\n\n- Факт-\(index): " + String(repeating: "существенная деталь. ", count: 50) + "\n\n## Следующее действие \(index)\n\n- Последнее действие-\(index): поговорить с командой."
        let text = model == "incomplete" ? "Обсуждались отношения." : prose
        let json: [String: Any] = ["message": ["content": text], "done_reason": model == "truncated" ? "length" : "stop"]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func notesSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [NotesProtocol.self]
    return URLSession(configuration: config)
}

@MainActor @Test func longCallRetainsSourceAndEveryExtractedFactWithoutSummarizingSummaries() async throws {
    let session = notesSession(); defer { session.invalidateAndCancel() }
    let transcript = (0..<7).map { "[\($0) с] Локальный микрофон: Тема \($0): " + String(repeating: "подробность ", count: 1600) }.joined(separator: "\n")
    let notes = "Важное уточнение владельца"
    let result = try await SummaryService.analyze(model: "parts", notes: notes, transcript: transcript, session: session, progress: { _ in })
    let requests = NotesProtocol.recorded("parts")
    #expect(requests.count > 5)
    let sentSource = requests.map { body in
        let messages = body["messages"] as? [[String: String]]
        return messages?.last?["content"]?.components(separatedBy: "Материал для заметок:\n").last ?? ""
    }.joined()
    #expect(sentSource.contains(SummaryService.sourceInput(transcript)))
    #expect(sentSource.contains(notes))
    for index in 1...requests.count {
        #expect(result.summary.contains("Факт-\(index):"))
        #expect(result.summary.contains("Последнее действие-\(index):"))
    }
    #expect(requests.allSatisfy { $0["format"] == nil })
}

@MainActor @Test func ordinaryCallKeepsLastTurnAndManualNotesInSingleRequest() async throws {
    let session = notesSession(); defer { session.invalidateAndCancel() }
    let transcript = "[0 с] Локальный микрофон: начало\n" + String(repeating: "важная информация ", count: 500) + "\n[900 с] Удалённая сторона: Договорились встретиться в пятницу."
    _ = try await SummaryService.analyze(model: "whole", notes: "Запись владельца", transcript: transcript, session: session, progress: { _ in })
    let requests = NotesProtocol.recorded("whole")
    #expect(requests.count == 1)
    let messages = requests.first?["messages"] as? [[String: String]]
    #expect(messages?.last?["content"]?.contains(SummaryService.sourceInput(transcript)) == true)
    #expect(messages?.last?["content"]?.contains("в пятницу") == true)
    #expect(messages?.last?["content"]?.contains("Запись владельца") == true)
    #expect(requests.first?["format"] == nil)
}

@MainActor @Test func incompleteOrTokenLimitedOutputCannotReplaceExistingSummary() async throws {
    for model in ["incomplete", "truncated"] {
        let session = notesSession(); defer { session.invalidateAndCancel() }
        do {
            _ = try await SummaryService.request(model: model, input: String(repeating: "Деталь разговора. ", count: 500), progress: { _ in }, session: session)
            Issue.record("Incomplete output must not be accepted")
        } catch is SummaryService.Invalid { #expect(NotesProtocol.recorded(model).count == 2) }
    }
}

@Test func mergingTopicsPreservesConcreteDetailsAndLateActions() {
    let merged = SummaryService.mergePartNotes(["## Антон\n\n- Боится смены проекта.\n\n## Другая тема\n\nФакт.", "## Антон\n\n- Договорились пойти на концерт."])
    #expect(merged.components(separatedBy: "## Антон").count == 2)
    #expect(merged.contains("Боится смены проекта."))
    #expect(merged.contains("Договорились пойти на концерт."))
    #expect(merged.contains("## Другая тема"))
    let actions = SummaryService.mergePartNotes(["## Решения и следующие шаги\n\n- Отсутствуют явно названные договорённости, ответственные или сроки.", "## Решения и следующие шаги\n\n- Встретиться с Антоном на концерте."])
    #expect(!actions.contains("Отсутствуют"))
    #expect(actions.contains("Встретиться с Антоном на концерте."))
}

@Test func summaryInputHidesTechnicalChannelsAndDeduplicatesOnlyExactNearbyEcho() {
    let input = "[0 с] Локальный микрофон: Обсудим первый проект.\n[0 с] Удалённая сторона: Обсудим первый проект.\n[10 с] Удалённая сторона: Второй проект ещё не согласован."
    let prepared = SummaryService.sourceInput(input)
    #expect(!prepared.contains("local"))
    #expect(!prepared.contains("remote"))
    #expect(!prepared.contains("Локальный микрофон"))
    #expect(prepared.components(separatedBy: "Обсудим первый проект.").count == 2)
    #expect(prepared.contains("Реплика 2"))
    #expect(prepared.contains("Второй проект ещё не согласован."))
}

@Test func optionalSpeakerPassUsesSeparateBoundedContextAndKeepsOriginalTurnIDs() {
    let transcript = "[0 с] Локальный микрофон: Привет.\n[1 с] Удалённая сторона: Меня зовут Анна.\n[2 с] Локальный микрофон: Первый вопрос.\n[3 с] Удалённая сторона: Ответ."
    let context = SpeakerAttributionService.context(transcript)
    #expect(context.contains("TURN 1 [remote]: Меня зовут Анна."))
    #expect(context.count <= 6000)
    #expect(SpeakerAttributionService.context("[0 с] Локальный микрофон: Обсудим бюджет.").isEmpty)
}

@MainActor @Test func gptOssUsesSupportedReasoningLevelForLocalNotes() async throws {
    let session = notesSession(); defer { session.invalidateAndCancel() }
    _ = try await SummaryService.request(model: "gpt-oss:20b", input: "Содержательная реплика.", progress: { _ in }, session: session)
    #expect(NotesProtocol.recorded("gpt-oss:20b").first?["think"] as? String == "low")
}
