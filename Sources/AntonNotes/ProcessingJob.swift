import Foundation

struct ProcessingJob: Codable, Equatable {
    var stage: String
    var duration: Double = 0
    var completed: Double = 0
    var queuedAt: Date?
    var started: Date?
    var estimate: Double?
    var error: String?
    var captureError: String?
    var retranscribe: Bool?
    var connection: LocalModelConnection?
    var pending = false
}

struct MeetingQueue {
    private(set) var ids: [UUID] = []
    mutating func append(_ id: UUID) { if !ids.contains(id) { ids.append(id) } }
    mutating func next() -> UUID? { ids.isEmpty ? nil : ids.removeFirst() }
}

enum ProcessingRecovery {
    static func shouldResume(_ meeting: Meeting, audioDuration: Double) -> Bool {
        if meeting.job?.pending == true { return true }
        // Terminal ASR failures need a deliberate retry; do not loop on silent/broken audio.
        if ["Речь не обнаружена", "Ошибка распознавания", "Аудиозаписи нет"].contains(meeting.job?.stage ?? "") { return false }
        return meeting.summary.isEmpty && (!meeting.transcript.isEmpty || audioDuration > 0)
    }
}
