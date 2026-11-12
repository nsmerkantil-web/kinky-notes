import Foundation
import Testing
@testable import AntonNotes

@Suite(.serialized) struct LocalModelsTests {
    @Test func providerProfilesSurviveSwitchingAndMigrateOllama() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("my-existing-model", forKey: "summaryModel")
        var settings = LocalModelSettings.load(from: defaults)
        #expect(settings.connection.model == "my-existing-model")
        settings.provider = .lmStudio
        #expect(settings.connection.baseURL == "http://127.0.0.1:1234/v1")
        settings.connection.model = "studio-model"
        settings.save(to: defaults)
        settings = LocalModelSettings.load(from: defaults)
        #expect(settings.connection.model == "studio-model")
        settings.provider = .ollama
        #expect(settings.connection.model == "my-existing-model")
    }

    @Test func requestUsesProviderProtocolAndNormalizesBasePaths() throws {
        for provider in LocalModelProvider.allCases {
            var connection = LocalModelConnection.default(for: provider)
            connection.model = "test-model"
            connection.baseURL += provider == .ollama ? "/api/" : "/"
            let client = LocalModelClient(connection: connection, token: "private-token")
            let request = try client.generationRequest(system: "System", input: "Text", temperature: 0, maxTokens: 6000, json: true)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            #expect(request.url?.path == (provider == .ollama ? "/api/chat" : "/v1/chat/completions"))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer private-token")
            #expect(body["model"] as? String == "test-model")
            if provider == .lmStudio {
                #expect(body["options"] == nil)
                #expect(body["think"] == nil)
                #expect(body["max_tokens"] as? Int == 6000)
                #expect(body["response_format"] == nil) // JSON remains prompt-based for compatibility.
            } else {
                #expect(body["format"] as? String == "json")
            }
        }
    }

    @Test func invalidAddressesAndTruncatedAnswersAreRejected() throws {
        var connection = LocalModelConnection.default(for: .lmStudio)
        for address in ["file:///tmp/test", "http://user:pass@localhost:1234", "http://localhost:1234/v1?key=secret"] {
            connection.baseURL = address
            #expect(throws: (any Error).self) { try connection.endpoint("models") }
        }
        connection = .default(for: .lmStudio)
        let client = LocalModelClient(connection: connection)
        let truncated = Data(#"{"choices":[{"message":{"content":"partial"},"finish_reason":"length"}]}"#.utf8)
        #expect(throws: (any Error).self) { try client.decodeGeneration(truncated) }
        let valid = Data(#"{"choices":[{"message":{"content":"Complete"},"finish_reason":"stop"}]}"#.utf8)
        #expect(try client.decodeGeneration(valid) == "Complete")
    }

    @Test func modelListsAndAuthenticationErrorsAreDistinct() throws {
        let ollama = LocalModelClient(connection: .default(for: .ollama))
        let studio = LocalModelClient(connection: .default(for: .lmStudio))
        #expect(try ollama.decodeModels(Data(#"{"models":[{"name":"chat","capabilities":["completion"]},{"name":"embed","capabilities":["embedding"]}]}"#.utf8)) == ["chat"])
        #expect(try studio.decodeModels(Data(#"{"data":[{"id":"local-chat"}]}"#.utf8)) == ["local-chat"])
        #expect(studio.httpError(status: 401, data: Data()).localizedDescription.contains("токен"))
    }

    @MainActor @Test func queuedConnectionIsPersistedAndDoesNotFollowSettingsChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(rootOverride: root, startServices: false)
        var settings = LocalModelSettings()
        settings.provider = .lmStudio
        settings.connection.model = "queued-model"
        store.localModels = settings
        var meeting = Meeting(title: "Call")
        meeting.transcript = "Синтетический транскрипт"
        store.meetings = [meeting]
        store.recording = true
        await store.summarize(meetingID: meeting.id)
        store.localModels.provider = .ollama
        #expect(store.meetings[0].job?.connection?.provider == .lmStudio)
        #expect(try store.vaultStorage.load().meetings[0].job?.connection?.model == "queued-model")
    }

    @MainActor @Test func lmStudioProducesSummaryAndTitleThroughHTTP() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StudioProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var connection = LocalModelConnection.default(for: .lmStudio)
        connection.model = "studio-test"
        let client = LocalModelClient(connection: connection)
        #expect(try await client.models(session: session) == ["studio-test"])
        let analysis = try await SummaryService.analyze(model: connection.model, connection: connection, notes: "Срок: пятница", transcript: "[0 с] Локальный микрофон: Проверим макет в пятницу", session: session, progress: { _ in })
        #expect(analysis.summary.contains("пятницу"))
        #expect(try await SummaryService.generateTitle(model: connection.model, connection: connection, summary: analysis.summary, session: session) == "Проверка макета")
    }

    @Test func liveOllamaWhenExplicitlyEnabled() async throws {
        guard let model = ProcessInfo.processInfo.environment["ANOTES_LIVE_OLLAMA_MODEL"] else { return }
        var connection = LocalModelConnection.default(for: .ollama)
        connection.model = model
        let client = LocalModelClient(connection: connection)
        #expect(try await client.models().contains(model))
        let text = try await client.generate(system: "Отвечай коротко по-русски.", input: "Тест: Анна проверит макет в пятницу. Напиши это одним предложением.", maxTokens: 256, timeout: 180)
        #expect(text.localizedCaseInsensitiveContains("пятниц"))
    }
}

private final class StudioProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let object: [String: Any]
        if request.url?.path == "/v1/models" {
            object = ["data": [["id": "studio-test"]]]
        } else {
            guard request.url?.path == "/v1/chat/completions", let data = bodyData(),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  body["options"] == nil, body["model"] as? String == "studio-test" else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
            }
            let messages = body["messages"] as? [[String: String]]
            let title = messages?.first?["content"]?.contains("Придумай") == true
            object = ["choices": [["finish_reason": "stop", "message": ["content": title ? "Проверка макета" : "## Проверка макета\n\nАнна проверит макет в пятницу."]]]]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
    private func bodyData() -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
    override func stopLoading() {}
}
