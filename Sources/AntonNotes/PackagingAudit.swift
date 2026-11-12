import Foundation

/// Runs the normal processing queue with synthetic audio in a new, isolated library.
@MainActor enum PackagingAudit {
    private static let title = "TEST — Packaging audit"

    static func run(_ args: [String]) async throws {
        let reopen = args[1] == "--audit-reopen"
        guard args.count == (reopen ? 3 : 6) else {
            throw LocalModelError.message("Usage: --audit-processing NEW_ROOT OLLAMA_MODEL EN.caf RU.caf or --audit-reopen AUDIT_ROOT")
        }
        let root = URL(fileURLWithPath: args[2], isDirectory: true)
        let manager = FileManager.default
        let marker = root.appendingPathComponent(".a-notes-packaging-audit")
        if reopen {
            guard (try? String(contentsOf: marker, encoding: .utf8)) == title else {
                throw LocalModelError.message("Audit marker missing")
            }
        } else {
            guard let bundled = BundledASR.root, manager.fileExists(atPath: bundled.path) else {
                throw LocalModelError.message("Offline ASR is missing from the app")
            }
            // Create atomically and refuse any pre-existing path, including a live library.
            try manager.createDirectory(at: root, withIntermediateDirectories: false)
            try title.write(to: marker, atomically: true, encoding: .utf8)
        }
        let store = Store(rootOverride: root, startServices: false)
        if !reopen {
            store.asrModel = BundledASR.model
            store.localModels = LocalModelSettings()
            store.model = args[3]
            var meeting = Meeting(title: title)
            meeting.job = ProcessingJob(stage: "Аудио сохранено")
            let audio = root.appendingPathComponent(meeting.id.uuidString)
            try manager.createDirectory(at: audio, withIntermediateDirectories: false)
            try manager.copyItem(atPath: args[4], toPath: audio.appendingPathComponent("microphone.caf").path)
            try manager.copyItem(atPath: args[5], toPath: audio.appendingPathComponent("remote.caf").path)
            store.meetings = [meeting]
            store.save()
            await store.transcribe(meetingID: meeting.id)
        }
        guard store.meetings.count == 1, let meeting = store.meetings.first, meeting.title == title,
              meeting.job?.stage == "Готово", meeting.job?.pending == false,
              store.audioDuration(meeting.id) > 0, !meeting.summary.isEmpty,
              meeting.transcript.localizedCaseInsensitiveContains("library"),
              meeting.transcript.localizedCaseInsensitiveContains("библиотек"),
              meeting.summary.localizedCaseInsensitiveContains("library") ||
                meeting.summary.localizedCaseInsensitiveContains("библиотек") else {
            throw LocalModelError.message("Processing audit failed · \(store.status) · \(store.meetings.first?.job?.stage ?? "no job")")
        }
        print("PASS: \(reopen ? "reopened library" : "audio → RU/EN transcript → Llama summary") · \(meeting.transcript.count) transcript characters · \(meeting.summary.count) summary characters")
    }
}
