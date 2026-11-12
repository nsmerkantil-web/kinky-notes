import Foundation
import Security

enum LocalModelProvider: String, CaseIterable, Codable, Identifiable {
    case ollama, lmStudio
    var id: String { rawValue }
    var title: String { self == .ollama ? "Ollama" : "LM Studio" }
}

struct LocalModelConnection: Codable, Equatable {
    var provider: LocalModelProvider
    var baseURL: String
    var model: String
    var contextTokens = 16384

    static func `default`(for provider: LocalModelProvider) -> Self {
        Self(provider: provider, baseURL: provider == .ollama ? "http://127.0.0.1:11434" : "http://127.0.0.1:1234/v1", model: "")
    }

    func endpoint(_ path: String) throws -> URL {
        guard var parts = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else {
            throw LocalModelError.message("Укажите HTTP(S)-адрес сервера без пароля, query и fragment.")
        }
        var prefix = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if provider == .ollama {
            if prefix == "api" || prefix == "v1" { prefix = "" }
            parts.path = "/" + ([prefix, "api", path].filter { !$0.isEmpty }.joined(separator: "/"))
        } else {
            if prefix.isEmpty { prefix = "v1" }
            parts.path = "/" + prefix + "/" + path
        }
        guard let url = parts.url else { throw LocalModelError.message("Неверный адрес сервера.") }
        return url
    }

    var credentialAccount: String { provider.rawValue + ":" + ((try? endpoint(""))?.absoluteString ?? baseURL) }
    var locationDescription: String {
        let host = URLComponents(string: baseURL)?.host?.lowercased() ?? ""
        return ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)
            ? "Сервер на этом Mac. Выбирайте локальную модель для обработки без облака."
            : "Текст будет отправлен на указанный сервер."
    }
}

struct LocalModelSettings: Codable, Equatable {
    static let defaultsKey = "localModelSettings.v1"
    var provider: LocalModelProvider = .ollama
    var ollama = LocalModelConnection.default(for: .ollama)
    var lmStudio = LocalModelConnection.default(for: .lmStudio)
    var connection: LocalModelConnection {
        get { provider == .ollama ? ollama : lmStudio }
        set { if provider == .ollama { ollama = newValue } else { lmStudio = newValue } }
    }
    static func load(from defaults: UserDefaults = .standard) -> Self {
        if let data = defaults.data(forKey: defaultsKey), let value = try? JSONDecoder().decode(Self.self, from: data) { return value }
        var value = Self()
        value.ollama.model = defaults.string(forKey: "summaryModel") ?? ""
        return value
    }
    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

enum LocalModelError: LocalizedError {
    case message(String), incomplete
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .incomplete: return "Модель не завершила ответ. Предыдущий итог сохранён; проверьте контекст модели и повторите."
        }
    }
}

enum LocalModelCredentials {
    private static func query(_ connection: LocalModelConnection) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "personal.anton.notes.local-model", kSecAttrAccount as String: connection.credentialAccount]
    }
    static func read(_ connection: LocalModelConnection) throws -> String? {
        var query = query(connection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw LocalModelError.message("Не удалось прочитать токен из Связки ключей (\(status)).") }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String, for connection: LocalModelConnection) throws {
        let query = query(connection)
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw LocalModelError.message("Не удалось удалить токен (\(status)).") }
            return
        }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query.merging(attributes) { _, new in new }
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw LocalModelError.message("Не удалось сохранить токен в Связке ключей (\(status)).") }
    }
}

// Do not forward credentials across HTTP redirects, including server misconfiguration.
private final class LocalRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct LocalModelClient {
    let connection: LocalModelConnection
    var token: String? = nil
    static func authenticated(_ connection: LocalModelConnection) throws -> Self {
        Self(connection: connection, token: try LocalModelCredentials.read(connection))
    }
    private func request(_ path: String, timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: try connection.endpoint(path))
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        return request
    }
    func generationRequest(system: String, input: String, temperature: Double = 0, maxTokens: Int = 6000, json: Bool = false, timeout: TimeInterval = 1800) throws -> URLRequest {
        guard !connection.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalModelError.message("Выберите модель в настройках Ollama или LM Studio. Транскрипт сохранён.") }
        var request = try request(connection.provider == .ollama ? "chat" : "chat/completions", timeout: timeout)
        request.httpMethod = "POST"
        var body: [String: Any] = ["model": connection.model, "stream": false, "messages": [["role": "system", "content": system], ["role": "user", "content": input]]]
        if connection.provider == .ollama {
            body["think"] = connection.model.hasPrefix("gpt-oss") ? "low" as Any : false as Any
            body["options"] = ["temperature": temperature, "num_ctx": connection.contextTokens, "num_predict": maxTokens]
            if json { body["format"] = "json" }
        } else {
            body["temperature"] = temperature
            body["max_tokens"] = maxTokens
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    func httpError(status: Int, data: Data) -> LocalModelError {
        if status == 401 || status == 403 { return .message("\(connection.provider.title): сервер отклонил доступ. Проверьте API-токен в настройках.") }
        // Never echo an arbitrary server response into logs; it may contain request text or secrets.
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = object?["error"] as? String ?? (object?["error"] as? [String: Any])?["message"] as? String ?? ""
        if error.contains("token repeat") { return .message("\(connection.provider.title): token repeat limit reached. Повторите генерацию.") }
        if status == 404 { return .message("\(connection.provider.title): адрес или модель не найдены. Обновите список моделей и проверьте адрес.") }
        return .message("\(connection.provider.title): ошибка сервера HTTP \(status). Проверьте загруженную модель, контекст и свободную память.")
    }
    private func data(for request: URLRequest, session: URLSession) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request, delegate: LocalRedirectPolicy())
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(response.statusCode) else { throw httpError(status: response.statusCode, data: data) }
            return data
        } catch let error as URLError where [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut].contains(error.code) {
            throw LocalModelError.message("\(connection.provider.title) не отвечает. Запустите приложение и API Server, проверьте адрес. Транскрипт сохранён.")
        }
    }
    func decodeModels(_ data: Data) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models: [[String: Any]]
        if connection.provider == .ollama {
            guard let values = object?["models"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
            models = values.filter { item in
                guard let capabilities = item["capabilities"] as? [String] else { return true }
                return capabilities.contains("completion")
            }
        } else {
            guard let values = object?["data"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
            models = values
        }
        return Array(Set(models.compactMap { $0[connection.provider == .ollama ? "name" : "id"] as? String }.filter { !$0.isEmpty })).sorted()
    }
    func models(session: URLSession = .shared) async throws -> [String] {
        try decodeModels(await data(for: request(connection.provider == .ollama ? "tags" : "models", timeout: 8), session: session))
    }
    func decodeGeneration(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text: String?
        if connection.provider == .ollama {
            if object?["done_reason"] as? String == "length" || object?["done"] as? Bool == false { throw LocalModelError.incomplete }
            text = (object?["message"] as? [String: Any])?["content"] as? String
        } else {
            let choice = (object?["choices"] as? [[String: Any]])?.first
            guard choice?["finish_reason"] as? String == "stop" else { throw LocalModelError.incomplete }
            text = (choice?["message"] as? [String: Any])?["content"] as? String
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw URLError(.cannotParseResponse) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func generate(system: String, input: String, temperature: Double = 0, maxTokens: Int = 6000, json: Bool = false, timeout: TimeInterval = 1800, session: URLSession = .shared) async throws -> String {
        try decodeGeneration(await data(for: generationRequest(system: system, input: input, temperature: temperature, maxTokens: maxTokens, json: json, timeout: timeout), session: session))
    }
}
