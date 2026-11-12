import Foundation
import WhisperKit

enum BundledASR {
    static let model = "large-v3_turbo"
    static var root: URL? { Bundle.main.resourceURL?.appendingPathComponent("OfflineASR") }
    static func engine(model selected: String) async throws -> WhisperKit {
        guard selected == model, let root, FileManager.default.fileExists(atPath: root.path) else {
            return try await WhisperKit(model: selected)
        }
        let modelFolder = root.appendingPathComponent("Model")
        let tokenizer = root.appendingPathComponent("Hub/models/openai/whisper-large-v3")
        for path in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"] {
            guard FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent(path).path) else {
                throw LocalModelError.message("Встроенная Whisper-модель повреждена. Переустановите A-notes; аудио сохранено.")
            }
        }
        for path in ["tokenizer.json", "tokenizer_config.json", "config.json"] {
            guard FileManager.default.fileExists(atPath: tokenizer.appendingPathComponent(path).path) else {
                throw LocalModelError.message("Отсутствуют файлы встроенного tokenizer. Переустановите A-notes.")
            }
        }
        return try await WhisperKit(WhisperKitConfig(model: model, modelFolder: modelFolder.path,
            tokenizerFolder: root.appendingPathComponent("Hub"), verbose: false, load: true, download: false))
    }
}

// Setup and diagnostics for a user's Codex. No GUI, meeting reads, or server changes.
enum SetupCommand {
    static func runIfRequested() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let command = args.dropFirst().first,
              ["--configure-local-model", "--check-local-model", "--check-bundled-asr", "--transcribe-check", "--audit-processing", "--audit-reopen"].contains(command) else { return false }
        Task { @MainActor in
            do {
                switch command {
                case "--configure-local-model":
                    func value(_ flag: String) throws -> String {
                        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { throw LocalModelError.message("Не указан параметр \(flag)") }
                        return args[index + 1]
                    }
                    let name = try value("--provider")
                    guard let provider = LocalModelProvider(rawValue: name == "lm-studio" ? "lmStudio" : name) else { throw LocalModelError.message("Поддерживаются ollama и lm-studio") }
                    var settings = LocalModelSettings.load()
                    settings.provider = provider
                    settings.connection.baseURL = try value("--server")
                    settings.connection.model = try value("--model")
                    guard !settings.connection.model.isEmpty else { throw LocalModelError.message("Model ID не может быть пустым") }
                    _ = try settings.connection.endpoint("models")
                    let useBundledASR = args.contains("--use-bundled-asr")
                    if useBundledASR {
                        guard let root = BundledASR.root, FileManager.default.fileExists(atPath: root.path) else {
                            throw LocalModelError.message("В app нет встроенных ASR assets")
                        }
                    }
                    var suppliedToken: String?
                    if args.contains("--token-stdin") {
                        guard let token = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
                            throw LocalModelError.message("Нет токена на stdin")
                        }
                        suppliedToken = token
                    }
                    if args.contains("--verify") { try await checkModel(settings.connection, suppliedToken: suppliedToken) }
                    if let suppliedToken { try LocalModelCredentials.save(suppliedToken, for: settings.connection) }
                    settings.save()
                    if useBundledASR { UserDefaults.standard.set(BundledASR.model, forKey: "asrModel") }
                    print("Настройки сохранены. Уже запущенная A-notes подхватит их перед следующим заданием; активное задание сохранит прежнее подключение.")
                case "--check-local-model":
                    try await checkModel(LocalModelSettings.load().connection)
                case "--audit-processing", "--audit-reopen":
                    try await PackagingAudit.run(args)
                case "--check-bundled-asr", "--transcribe-check":
                    guard let root = BundledASR.root, FileManager.default.fileExists(atPath: root.path) else { throw LocalModelError.message("В app нет встроенных ASR assets") }
                    let engine = try await BundledASR.engine(model: BundledASR.model)
                    if command == "--transcribe-check" {
                        guard args.count == 3 else { throw LocalModelError.message("Укажите путь к синтетическому аудиофайлу") }
                        let results = try await engine.transcribe(audioPath: args[2], decodeOptions: DecodingOptions(language: "en", skipSpecialTokens: true))
                        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { throw LocalModelError.message("ASR не вернул текст") }
                        print("PASS: bundled ASR transcription · \(text.count) characters")
                    } else { print("PASS: bundled ASR weights + tokenizer loaded") }
                default: break
                }
                exit(0)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        return true
    }

    private static func checkModel(_ connection: LocalModelConnection, suppliedToken: String? = nil) async throws {
        let client = try suppliedToken.map { LocalModelClient(connection: connection, token: $0) } ?? LocalModelClient.authenticated(connection)
        let models = try await client.models()
        guard models.contains(connection.model) else { throw LocalModelError.message("Выбранная модель отсутствует в каталоге сервера") }
        _ = try await client.generate(system: "Reply briefly.", input: "Write OK.", maxTokens: 256, timeout: 180)
        print("PASS: \(connection.provider.title) / \(connection.model) · каталог и inference")
    }
}
