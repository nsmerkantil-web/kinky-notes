import Foundation

@MainActor enum CaptureFinalization {
    // A failed stop often means the stream has already ended. Writers must close either way.
    static func run(stop: () async throws -> Void, close: () async -> Void) async -> String? {
        var failure: String?
        do { try await stop() } catch { failure = error.localizedDescription }
        await close()
        return failure
    }
}
