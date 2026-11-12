import Foundation

struct TranscriptionCheckpoint: Codable {
    struct Line: Codable {
        var time: Double
        var text: String
    }
    var model: String
    var lines: [Line] = []
    var offsets: [String: Double] = [:]

    static func load(from url: URL, model: String) -> Self {
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(Self.self, from: data), saved.model == model else { return Self(model: model) }
        return saved
    }
    func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
