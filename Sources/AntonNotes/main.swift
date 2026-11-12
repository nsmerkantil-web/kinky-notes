import SwiftUI
import AVFoundation
import ScreenCaptureKit
import UniformTypeIdentifiers
import WhisperKit

struct Meeting: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var folder = "Входящие"
    var notes = ""
    var transcript = ""
    var summary = ""
    var speakerAttributions: [SpeakerAttribution]?
    var date = Date()
    var job: ProcessingJob?
}

@MainActor final class Store: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var folders: [String] = [NoteLibrary.inbox]
    private var storageAvailable = true
    private let notificationsEnabled: Bool
    @Published var selected: UUID?
    @Published var status = "Готово" { didSet { log(status) } }
    @Published var localModels = LocalModelSettings.load() {
        didSet { if persistModelSettings { localModels.save() }; summaryModels = []; modelStatus = "Подключение изменено · проверьте связь" }
    }
    private var persistModelSettings = false
    var persistedSettingsEnabled: Bool { persistModelSettings }
    @Published var checkingConnection = false
    var connection: LocalModelConnection { localModels.connection }
    var model: String {
        get { localModels.connection.model }
        set { localModels.connection.model = newValue }
    }
    var serverURL: String {
        get { localModels.connection.baseURL }
        set { localModels.connection.baseURL = newValue }
    }
    @Published var recording = false
    @Published var mode = UserDefaults.standard.string(forKey: "recordingMode") ?? "Предлагать" { didSet { UserDefaults.standard.set(mode, forKey: "recordingMode") } }
    private let detector = CallDetector()
    private lazy var notifications = CallNotifications()
    @Published var starting = false
    @Published var processing = false
    @Published var summarizing = false
    @Published var showRecording = false
    @Published var asrModel = UserDefaults.standard.string(forKey: "asrModel") ?? BundledASR.model {
        didSet { if persistModelSettings { UserDefaults.standard.set(asrModel, forKey: "asrModel") } }
    }
    @Published var asrModels = ["large-v3_turbo"]
    @Published var summaryModels: [String] = []
    @Published var refreshingModels = false
    @Published var modelStatus = "Проверка моделей…"
    private var queue = MeetingQueue()
    private var cachedEngine: WhisperKit?
    private var cachedEngineModel: String?
    private var draining = false
    private var worker: Task<Void, Never>?
    var summarySession: URLSession = .shared
    private var sleeping = false
    private var powerObservers: [NSObjectProtocol] = []
    private var activeID: UUID?
    @Published var stopping = false
    @Published private(set) var recordingID: UUID?
    private var permissionFailed = false
    func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = root.appendingPathComponent("diagnostics.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
    private var callEndPolicy = CallEndPolicy()
    @Published private(set) var callWasActive = false
    @Published private(set) var automaticRecording = false
    private var stream: SCStream?
    private var sink: AudioSink?
    let root: URL
    let vaultStorage: ObsidianStorage
    private var saving = false
    init(rootOverride: URL? = nil, startServices: Bool = true) {
        notificationsEnabled = startServices
        let arguments = ProcessInfo.processInfo.arguments
        let validationIndex = arguments.firstIndex(of: "--validation-root")
        let validationRoot = rootOverride ?? validationIndex.flatMap { arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
        root = validationRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(ProcessInfo.processInfo.arguments.contains("--design-preview") ? "AntonNotes-DesignPreview" : "AntonNotes")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let isolated = validationRoot != nil || arguments.contains("--design-preview")
        persistModelSettings = !isolated
        let vault = isolated ? root.appendingPathComponent("Obsidian") : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("A-notes")
        vaultStorage = ObsidianStorage(root: root, vault: vault)
        do {
            let library = try vaultStorage.load()
            meetings = library.meetings
            folders = library.folders
        } catch {
            storageAvailable = false
            status = "Не удалось прочитать заметки: \(error.localizedDescription). Файлы не перезаписаны."
        }
        if arguments.contains("--migrate-vault") {
            print(storageAvailable ? "Obsidian vault: \(vault.path); meetings: \(meetings.count)" : status)
            exit(storageAvailable ? 0 : 1)
        }
        if ProcessInfo.processInfo.arguments.contains("--design-preview") {
            let titles = ["Library launch and support workflow", "Planning for the autumn reading club", "Каталог: объём первого релиза и приоритеты", "Workshop registration and accessibility review", "Планирование выходных", "Интеграция поиска и фильтров"]
            meetings = titles.enumerated().map { index, title in
                var m = Meeting(title:title)
                let day = [1,1,2,2,3,6][index]
                m.date = Calendar.current.date(byAdding:.day,value: -day,to:Date())!
                m.date = Calendar.current.date(bySettingHour:[16,12,17,12,15,14][index],minute:[30,32,12,31,0,56][index],second:0,of:m.date)!
                m.folder = ["Каталог", "Клуб", "Каталог", "События", "Личное", "Каталог"][index]
                m.notes = "Обсудить состояния кнопок и поведение настроек."
                if index == 0 { m.summary = "Обсудили текущий объём работ.\n\nРешения\n• Проверить интерактивные состояния.\n• Сохранить существующий функционал."; m.transcript = "[0 с] Локальный микрофон: Давайте проверим интерфейс.\n[5 с] Удалённая сторона: Начнём с настроек и кнопок." }
                return m
            }
        }
        folders = NoteLibrary(meetings: meetings, folders: folders).folders
        cleanLegacyTranscripts()
        for i in meetings.indices {
            if meetings[i].job == nil { meetings[i].job = ProcessingJob(stage: audioDuration(meetings[i].id) == 0 ? "Аудиозаписи нет" : meetings[i].summary.isEmpty ? (meetings[i].transcript.isEmpty ? "Аудио сохранено" : "Транскрипт готов") : "Готово", duration: audioDuration(meetings[i].id)) }
            if ["Запись", "Ошибка записи"].contains(meetings[i].job?.stage ?? "") {
                let duration = audioDuration(meetings[i].id)
                meetings[i].job?.captureError = meetings[i].job?.error ?? "Запись завершилась неожиданно"
                meetings[i].job?.duration = duration
                meetings[i].job?.stage = duration > 0 ? "В очереди" : "Аудиозаписи нет"
                meetings[i].job?.pending = duration > 0
                meetings[i].job?.queuedAt = meetings[i].job?.queuedAt ?? Date()
            }

        }
        recoverUnfinishedMeetings()
        let center = NSWorkspace.shared.notificationCenter
        powerObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pauseForSleep() }
        })
        powerObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeAfterSleep() }
        })
        for meeting in meetings.filter({ $0.job?.pending == true }).sorted(by: { ($0.job?.queuedAt ?? $0.date) < ($1.job?.queuedAt ?? $1.date) }) { queue.append(meeting.id) }
        save()
        if startServices {
            Task { await self.refreshModels() }
            Task {
                await self.drainQueue()
                await self.recoverMeetingTitles()
            }
        }
        selected = meetings.first?.id
        if !startServices || arguments.contains("--design-preview") { return }
        notifications.configure()
        notifications.onTakeNotes = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                NSApp.activate(ignoringOtherApps: true)
                await self.start()
            }
        }
        notifications.onOpenMeeting = { [weak self] id in
            Task { @MainActor in
                guard let self else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.selected = id
                self.showRecording = true
            }
        }
        notifications.onError = { [weak self] text in Task { @MainActor in self?.status = text } }
        log("App launched; ASR=large-v3_turbo; summary=\(model); screenPermission=\(CGPreflightScreenCaptureAccess())")
        detector.onChange = { [weak self] pids in
            Task { @MainActor in
                guard let self else { return }
                let names = pids.compactMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
                let active = names.contains { $0.contains("com.microsoft.teams") || $0.contains("com.google.Chrome") }
                let began = active && !self.callWasActive
                self.callWasActive = active
                if !active { self.notifications.clear() }
                if self.callEndPolicy.shouldStop(recording: self.recording, callActive: active, now: Date()) {
                    self.log("Call ended; automatically finalizing recording")
                    await self.stop()
                }
                if began && !self.recording {
                    self.log("Call detected")
                    if self.mode == "Автоматически" { await self.start(automatic: true) }
                    else if self.mode == "Предлагать" { await self.notifications.show() }
                }
            }
        }
        detector.start()
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "--transcribe-meeting"), args.indices.contains(i + 1), let id = UUID(uuidString: args[i + 1]) {
            Task { await self.transcribe(meetingID: id) }
        }
    }
    private func cleanLegacyTranscripts() {
        let cleaned = meetings.map { meeting -> Meeting in
            var copy = meeting
            copy.transcript = TranscriptionPolicy.clean(meeting.transcript)
            return copy
        }
        guard zip(meetings, cleaned).contains(where: { $0.transcript != $1.transcript }) else { return }
        do {
            let backup = root.appendingPathComponent("meetings-before-token-cleanup-\(UUID().uuidString).json")
            try JSONEncoder().encode(meetings).write(to: backup, options: .atomic)
            try NoteLibrary(meetings: cleaned, folders: folders).write(to: root)
            meetings = cleaned
            log("Cleaned legacy Whisper tokens; backup=\(backup.lastPathComponent)")
        } catch { status = "Не удалось очистить старые транскрипты: \(error.localizedDescription)" }
    }
    func audioDuration(_ id: UUID) -> Double {
        ["microphone.caf", "remote.caf"].compactMap { name -> Double? in
            guard let file = try? AVAudioFile(forReading: root.appendingPathComponent(id.uuidString).appendingPathComponent(name)) else { return nil }
            return Double(file.length) / file.processingFormat.sampleRate
        }.max() ?? 0
    }
    func updateJob(_ id: UUID, stage: String, error: String? = nil) {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        if meetings[i].job == nil { meetings[i].job = ProcessingJob(stage: stage) }
        meetings[i].job?.stage = stage
        meetings[i].job?.error = error
        save()
    }
    func refreshModels() async {
        guard !refreshingModels else { return }
        refreshingModels = true
        let selected = connection
        defer { refreshingModels = false }
        do {
            let models = try await LocalModelClient.authenticated(selected).models(session: summarySession)
            guard connection == selected else { return }
            summaryModels = models
            modelStatus = models.isEmpty ? "Сервер доступен, моделей нет. Загрузите текстовую модель в \(selected.provider.title)." : "\(selected.provider.title) доступна · моделей: \(models.count). Выберите модель и проверьте связь."
        } catch {
            guard connection == selected else { return }
            summaryModels = []
            modelStatus = error.localizedDescription
        }
    }
    func checkConnection() async {
        guard !checkingConnection else { return }
        let selected = connection
        checkingConnection = true
        modelStatus = "Проверка ответа модели…"
        defer { checkingConnection = false }
        do {
            _ = try await LocalModelClient.authenticated(selected).generate(system: "Reply briefly.", input: "Write OK.", maxTokens: 256, timeout: 180, session: summarySession)
            guard connection == selected else { return }
            modelStatus = "\(selected.provider.title) · \(selected.model) отвечает. Подключение готово."
        } catch {
            guard connection == selected else { return }
            modelStatus = error.localizedDescription
        }
    }
    func saveModelToken(_ token: String) {
        do {
            try LocalModelCredentials.save(token, for: connection)
            modelStatus = token.isEmpty ? "Токен удалён из Связки ключей" : "Токен сохранён в Связке ключей · проверьте связь"
        } catch { modelStatus = error.localizedDescription }
    }
    func feedback(_ meeting: Meeting, now: Date) -> String {
        let job = meeting.job
        let duration = recordingID == meeting.id ? now.timeIntervalSince(meeting.date) : (job?.duration ?? 0)
        var text = duration > 0 ? "Аудио \(Int(duration)/60):\(String(format: "%02d", Int(duration)%60))" : "Аудиозаписи нет"
        let stage = job?.stage ?? "Нет обработки"
        if stage != "Аудиозаписи нет" { text += " · " + stage }
        if let captureError = job?.captureError { text += " · Запись прервана: " + captureError }
        if let error = job?.error { text += " · " + error }
        if let estimate = job?.estimate, let start = job?.started, job?.pending == true, activeID == meeting.id {
            let left = estimate - now.timeIntervalSince(start)
            text += left > 0 ? " · ≈ \(max(1, Int(ceil(left / 60)))) мин до готовности" : " · Дольше оценки, обработка продолжается"
        } else if activeID == meeting.id { text += " · Оценка времени уточняется" }
        return text
    }
    func recoverUnfinishedMeetings() {
        for i in meetings.indices {
            let duration = audioDuration(meetings[i].id)
            if ProcessingRecovery.shouldResume(meetings[i], audioDuration: duration) {
                if meetings[i].job == nil { meetings[i].job = ProcessingJob(stage: "В очереди", duration: duration) }
                meetings[i].job?.pending = true
                if meetings[i].job?.connection == nil { meetings[i].job?.connection = connection }
                meetings[i].job?.queuedAt = meetings[i].job?.queuedAt ?? Date()
                meetings[i].job?.stage = "В очереди · восстановлено"
                meetings[i].job?.error = nil
                queue.append(meetings[i].id)
            }
        }
    }
    func pauseForSleep() {
        sleeping = true
        worker?.cancel()
        for i in meetings.indices where meetings[i].job?.pending == true {
            meetings[i].job?.stage = "Пауза · Mac спит"
            meetings[i].job?.estimate = nil
        }
        save()
        log("Processing paused for system sleep; pending jobs saved")
        if recording { Task { await self.stop() } }
    }
    func resumeAfterSleep() {
        sleeping = false
        for i in meetings.indices where meetings[i].job?.pending == true {
            meetings[i].job?.stage = "В очереди · после сна"
            queue.append(meetings[i].id)
        }
        save()
        let previous = worker
        Task {
            await previous?.value
            await self.drainQueue()
        }
    }
    func drainQueue() async {
        guard !draining, !recording, !sleeping else { return }
        draining = true
        let task = Task { await self.runQueue() }
        worker = task
        await task.value
        worker = nil
        draining = false
        if !sleeping, !recording, !queue.ids.isEmpty {
            Task { await self.drainQueue() }
        }
    }
    private func runQueue() async {
        // Allow background work without App Nap; system sleep remains allowed.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Обработка сохранённых звонков")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        while !recording, !sleeping, !Task.isCancelled, let id = queue.next() {
            activeID = id
            if let meeting = meetings.first(where: { $0.id == id }),
               !meeting.transcript.isEmpty, meeting.job?.retranscribe != true {
                await createSummary(id)
            } else {
                await processMeeting(id)
            }
            if let i = meetings.firstIndex(where: { $0.id == id }) {
                if Task.isCancelled || sleeping {
                    meetings[i].job?.stage = sleeping ? "Пауза · Mac спит" : "В очереди · после сна"
                    queue.append(id)
                } else { meetings[i].job?.pending = false }
                save()
            }
            activeID = nil
        }
    }
    func testNotification() async { await notifications.show() }
    func save() {
        guard storageAvailable, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            let merged = try vaultStorage.save(NoteLibrary(meetings: meetings, folders: folders))
            if meetings != merged.meetings { meetings = merged.meetings }
        } catch { status = "Не удалось сохранить: \(error.localizedDescription)" }
    }
    @discardableResult func changeLibrary(_ change: (inout NoteLibrary) throws -> Void) -> Bool {
        guard storageAvailable else { return false }
        do {
            var library = NoteLibrary(meetings: meetings, folders: folders)
            try change(&library)
            library = try vaultStorage.save(library)
            meetings = library.meetings
            folders = library.folders
            return true
        } catch { status = error.localizedDescription; return false }
    }
    func canDelete(_ id: UUID) -> Bool {
        id != recordingID && id != activeID && !starting && !stopping && !summarizing
    }
    func deleteMeeting(_ id: UUID) {
        guard canDelete(id), changeLibrary({ $0.deleteMeeting(id) }) else { return }
        if selected == id { selected = nil }
        let audio = root.appendingPathComponent(id.uuidString)
        if FileManager.default.fileExists(atPath: audio.path) {
            do { try FileManager.default.trashItem(at: audio, resultingItemURL: nil) }
            catch { status = "Запись удалена; не удалось переместить аудио в Корзину: \(error.localizedDescription)" }
        }
    }
    func add(folder: String? = nil) { var m = Meeting(title: "Встреча \(Date().formatted(date: .abbreviated, time: .shortened))"); m.folder = folder.flatMap { folders.contains($0) ? $0 : nil } ?? NoteLibrary.inbox; meetings.insert(m, at: 0); selected = m.id; save() }
    func start(automatic: Bool = false) async {
        guard !recording && !starting && !stopping else { return }
        starting = true
        defer { starting = false }
        if permissionFailed && !CGPreflightScreenCaptureAccess() {
            status = "macOS отклонила захват. После изменения разрешения полностью перезапустите A-notes. Если переключатель уже включён, удалите A-notes из списка записи экрана и добавьте текущую сборку заново."
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { status = "Разрешите микрофон в настройках macOS"; return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { throw NSError(domain: "Capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Нет доступного дисплея"]) }
            var meeting = Meeting(title: "Встреча \(Date().formatted(date: .abbreviated, time: .shortened))")
            meeting.job = ProcessingJob(stage: "Запись")
            let directory = root.appendingPathComponent(meeting.id.uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let output = AudioSink(directory: directory)
            output.onFailure = { [weak self] message in
                Task { @MainActor in
                    guard let self, self.recordingID == meeting.id else { return }
                    await self.stop(captureFailure: message)
                }
            }
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.captureMicrophone = true
            config.excludesCurrentProcessAudio = true
            config.width = 2; config.height = 2
            config.sampleRate = 48000; config.channelCount = 1
            let capture = SCStream(filter: SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []), configuration: config, delegate: output)
            try capture.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
            try capture.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue)
            try await capture.startCapture()
            meetings.insert(meeting, at: 0); save()
            automaticRecording = automatic
            sink = output; stream = capture; recordingID = meeting.id; recording = true
            if !automatic { selected = meeting.id; showRecording = true }
            notifications.clear(); permissionFailed = false
            callEndPolicy = CallEndPolicy()
            _ = callEndPolicy.shouldStop(recording: true, callActive: callWasActive, now: Date())
            log("Capture started meeting=\(meeting.id)")
            status = "Запись микрофона и системного звука"
        } catch {
            let e = error as NSError
            permissionFailed = e.domain == SCStreamErrorDomain && e.code == -3801
            status = "Ошибка записи [\(e.domain):\(e.code)]: \(e.localizedDescription)"
        }
    }
    func stop(captureFailure: String? = nil) async {
        guard !stopping, let id = recordingID else { return }
        stopping = true
        callEndPolicy = CallEndPolicy()
        let capture = stream
        let output = sink
        // Detach before suspension: stop taps and late delegate callbacks cannot finish twice.
        recording = false; stream = nil; sink = nil; recordingID = nil
        let stopFailure = await CaptureFinalization.run(stop: {
            if let capture { try await capture.stopCapture() }
        }, close: { if let output { await output.finish() } })
        let failure = captureFailure ?? stopFailure
        if let i = meetings.firstIndex(where: { $0.id == id }) {
            meetings[i].job?.duration = audioDuration(id)
            meetings[i].job?.captureError = failure
        }
        log("Capture finalized meeting=\(id) duration=\(audioDuration(id)) interrupted=\(failure != nil)")
        stopping = false
        let hasAudio = audioDuration(id) > 0
        Task { await notifications.recordingEnded(id: id, hasAudio: hasAudio, interrupted: failure != nil) }
        if audioDuration(id) > 0 {
            status = failure == nil ? "Аудио сохранено" : "Запись прервана; сохранённое аудио отправлено в обработку"
            await transcribe(meetingID: id)
        } else {
            updateJob(id, stage: "Аудиозаписи нет", error: failure)
            await drainQueue()
        }
    }
    func transcribe(meetingID: UUID? = nil) async {
        guard let id = meetingID ?? selected, activeID != id else { return }
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        if meetings[i].job == nil { meetings[i].job = ProcessingJob(stage: "В очереди") }
        if meetings[i].job?.pending != true { meetings[i].job?.queuedAt = Date() }
        meetings[i].job?.pending = true
        meetings[i].job?.retranscribe = true
        if persistModelSettings { localModels = LocalModelSettings.load() }
        meetings[i].job?.connection = connection
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString).appendingPathComponent("transcription-checkpoint.json"))
        queue.append(id)
        updateJob(id, stage: sleeping ? "Пауза · Mac спит" : "В очереди")
        await drainQueue()
    }
    private func processMeeting(_ id: UUID) async {
        let directory = root.appendingPathComponent(id.uuidString)
        guard ["microphone.caf", "remote.caf"].contains(where: { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) else { status = "У этой встречи нет аудиозаписи"; updateJob(id, stage: "Аудиозаписи нет"); return }
        processing = true
        defer { processing = false }
        let language = "auto"
        let chosenModel = asrModel
        let began = Date()
        if let i = meetings.firstIndex(where: { $0.id == id }) {
            meetings[i].job?.started = began
            meetings[i].job?.completed = 0
            meetings[i].job?.estimate = 120 + audioDuration(id) * 2 + 60
        }
        updateJob(id, stage: "Подготовка распознавания")
        log("ASR started meeting=\(id) model=\(chosenModel) language=\(language)")
        status = "Загрузка локальной Whisper-модели / распознавание…"
        do {
            let engine: WhisperKit
            if let cachedEngine, cachedEngineModel == chosenModel { engine = cachedEngine }
            else {
                cachedEngine = nil
                engine = try await BundledASR.engine(model: chosenModel)
                cachedEngine = engine; cachedEngineModel = chosenModel
            }
            let checkpointURL = directory.appendingPathComponent("transcription-checkpoint.json")
            var checkpoint = TranscriptionCheckpoint.load(from: checkpointURL, model: chosenModel)
            var lines = checkpoint.lines.map { ($0.time, $0.text) }
            if let i = meetings.firstIndex(where: { $0.id == id }) { meetings[i].job?.completed = checkpoint.offsets.values.reduce(0, +) }
            for (file, speaker) in [("microphone.caf", "Локальный микрофон"), ("remote.caf", "Удалённая сторона")] {
                let path = root.appendingPathComponent(id.uuidString).appendingPathComponent(file).path
                guard FileManager.default.fileExists(atPath: path) else { continue }
                let audio = try AVAudioFile(forReading: URL(fileURLWithPath: path))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 8192) else { continue }
                var peak: Float = 0
                while audio.framePosition < audio.length {
                    try Task.checkCancellation()
                    try audio.read(into: buffer)
                    guard buffer.frameLength > 0 else { break }
                    if let channels = buffer.floatChannelData {
                        for channel in 0..<Int(buffer.format.channelCount) {
                            for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channels[channel][frame])) }
                        }
                    }
                }
                log("ASR track=\(file) frames=\(audio.length) peak=\(peak)")
                if peak < 0.00001 { log("Skipped silent track \(file)"); continue }
                let duration = Double(audio.length) / audio.processingFormat.sampleRate
                var offset = checkpoint.offsets[file] ?? 0
                while offset < duration {
                    try Task.checkCancellation()
                    updateJob(id, stage: "Распознавание · \(speaker) · \(Int(offset))/\(Int(duration)) с")
                    let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: path, startTime: offset, endTime: min(duration, offset + 30))
                    let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, samples.count)))
                    if rms > 0.0003 {
                        let detection = try await engine.detectLangauge(audioArray: samples)
                        var results: [TranscriptionResult] = []
                        var bestScore = -Float.infinity
                        var detected = detection.language
                        for candidate in TranscriptionPolicy.candidateLanguages(detection.language) {
                            let attempt = try await engine.transcribe(audioArray: samples, decodeOptions: TranscriptionPolicy.options(language: candidate))
                            let segments = attempt.flatMap(\.segments)
                            let score = segments.reduce(Float(0)) { $0 + $1.avgLogprob } / Float(max(1, segments.count))
                            if !segments.isEmpty && score > bestScore { results = attempt; bestScore = score; detected = candidate }
                        }
                        log("ASR language=\(detected) track=\(file) offset=\(offset)")
                        for result in results {
                            for segment in result.segments {
                                let text = TranscriptionPolicy.clean(segment.text).trimmingCharacters(in: .whitespacesAndNewlines)
                                if !text.isEmpty { lines.append((offset + Double(segment.start), "[\(Int(offset + Double(segment.start))) с] \(speaker): \(text)")) }
                            }
                        }
                    }
                    offset += 30
                    try Task.checkCancellation()
                    checkpoint.lines = lines.map { TranscriptionCheckpoint.Line(time: $0.0, text: $0.1) }
                    checkpoint.offsets[file] = min(offset, duration)
                    try checkpoint.save(to: checkpointURL)
                    if let i = meetings.firstIndex(where: { $0.id == id }) {
                        meetings[i].job?.completed += min(30, duration - (offset - 30))
                        let done = meetings[i].job?.completed ?? 0
                        meetings[i].job?.estimate = began.distance(to: Date()) / max(1, done) * max(done, audioDuration(id) * 2) + 60
                    }
                }
            }
            guard !lines.isEmpty else { status = "Нет аудио или распознанной речи"; updateJob(id, stage: "Речь не обнаружена"); return }
            if let index = meetings.firstIndex(where: {$0.id == id}) {
                try Task.checkCancellation()
                meetings[index].job?.retranscribe = false
                meetings[index].speakerAttributions = nil
                meetings[index].transcript = lines.sorted {$0.0 < $1.0}.map {$0.1}.joined(separator: "\n")
                save()
            }
            try? FileManager.default.removeItem(at: checkpointURL)
            status = "Транскрипт готов"
            await createSummary(id)
        } catch {
            if Task.isCancelled { return }
            status = "Ошибка распознавания: \(error.localizedDescription)"; updateJob(id, stage: "Ошибка распознавания", error: error.localizedDescription) }
    }
    func summarize(meetingID: UUID? = nil) async {
        guard let id = meetingID ?? selected,
              let i = meetings.firstIndex(where: { $0.id == id }),
              !meetings[i].transcript.isEmpty, meetings[i].job?.pending != true else { return }
        if meetings[i].job == nil { meetings[i].job = ProcessingJob(stage: "В очереди") }
        meetings[i].job?.pending = true
        meetings[i].job?.retranscribe = false
        if persistModelSettings { localModels = LocalModelSettings.load() }
        meetings[i].job?.connection = connection
        meetings[i].job?.queuedAt = Date()
        meetings[i].job?.estimate = nil
        queue.append(id)
        status = "Итог поставлен в очередь"
        updateJob(id, stage: sleeping ? "Пауза · Mac спит" : "В очереди · создание итога")
        await drainQueue()
    }
    /// Retry titles independently of transcription and summary generation after relaunch.
    func recoverMeetingTitles() async {
        let ids = meetings.filter {
            SummaryService.isPlaceholderTitle($0.title) && !$0.summary.isEmpty && $0.job?.pending != true
        }.sorted { $0.date > $1.date }.map(\.id)
        for id in ids {
            guard !Task.isCancelled, !sleeping else { return }
            await updateMeetingTitle(id, connection: connection)
        }
    }

    func updateMeetingTitle(_ id: UUID, connection: LocalModelConnection) async {
        guard let meeting = meetings.first(where: { $0.id == id }),
              SummaryService.isPlaceholderTitle(meeting.title), !meeting.summary.isEmpty else { return }
        do {
            guard let title = try await SummaryService.generateTitle(model: connection.model, connection: connection, summary: meeting.summary, session: summarySession) else {
                log("Title generation returned an invalid title; meeting=\(id)")
                return
            }
            try Task.checkCancellation()
            guard !sleeping, let index = meetings.firstIndex(where: { $0.id == id }),
                  meetings[index].title == meeting.title, meetings[index].summary == meeting.summary else { return }
            meetings[index].title = title
            save()
            log("Meeting title updated; meeting=\(id)")
        } catch {
            if !Task.isCancelled { log("Title generation failed; meeting=\(id); error=\(error.localizedDescription)") }
        }
    }

    private func createSummary(_ id: UUID) async {
        guard !Task.isCancelled, let meeting = meetings.first(where: { $0.id == id }), !meeting.transcript.isEmpty else { return }
        let selectedConnection = meeting.job?.connection ?? connection
        if let i = meetings.firstIndex(where: { $0.id == id }) { meetings[i].job?.connection = selectedConnection; save() }
        summarizing = true
        defer { summarizing = false }
        if let i = meetings.firstIndex(where: { $0.id == id }) {
            meetings[i].job?.started = Date()
            meetings[i].job?.estimate = nil
        }
        updateJob(id, stage: "Создание итога")
        status = "Создаём итог…"
        do {
            let analysis = try await SummaryService.analyze(model: selectedConnection.model, connection: selectedConnection, notes: meeting.notes, transcript: meeting.transcript, session: summarySession) { stage in
                self.updateJob(id, stage: stage)
            }
            try Task.checkCancellation()
            guard let index = meetings.firstIndex(where: { $0.id == id }), meetings[index].transcript == meeting.transcript else {
                throw NSError(domain: "Summary", code: 1, userInfo: [NSLocalizedDescriptionKey: "Транскрипт изменился. Запустите итог заново."])
            }
            meetings[index].summary = analysis.summary
            if let candidates = analysis.speakers {
                let attributions = Conversation.validated(candidates, transcript: meeting.transcript)
                if !attributions.isEmpty { meetings[index].speakerAttributions = attributions }
            }
            save()
            if SummaryService.isPlaceholderTitle(meeting.title) {
                updateJob(id, stage: "Подбор названия")
                await updateMeetingTitle(id, connection: selectedConnection)
                try Task.checkCancellation()
            }
            status = "Заметки готовы"
            updateJob(id, stage: "Готово")
            if notificationsEnabled { await notifications.notesReady(id: id) }
        } catch {
            if Task.isCancelled { return }
            status = "Не удалось создать итог: \(error.localizedDescription)"
            updateJob(id, stage: "Транскрипт готов; ошибка итога", error: error.localizedDescription)
        }
    }
}

final class AudioSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onFailure: ((String) -> Void)?
    private var writeFailureReported = false
    private var finished = false
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { if !self.finished { self.onFailure?(error.localizedDescription) } }
    }
    let queue = DispatchQueue(label: "AntonNotes.audio")
    let directory: URL
    var files: [SCStreamOutputType: AVAudioFile] = [:]
    init(directory: URL) { self.directory = directory }
    func finish() async {
        await withCheckedContinuation { continuation in
            queue.async { self.finished = true; self.files.removeAll(); continuation.resume() }
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finished else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer), let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let count = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
        pcm.frameLength = count
        do {
            try sampleBuffer.copyPCMData(fromRange: 0..<sampleBuffer.numSamples, into: pcm.mutableAudioBufferList)
            if files[type] == nil {
                files[type] = try AVAudioFile(forWriting: directory.appendingPathComponent(type == .microphone ? "microphone.caf" : "remote.caf"), settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            }
            guard let writer = files[type], writer.processingFormat == pcm.format else {
                throw NSError(domain: "AudioSink", code: 1, userInfo: [NSLocalizedDescriptionKey: "Формат аудиоустройства изменился во время записи"])
            }
            try writer.write(from: pcm)
        } catch {
            if !writeFailureReported { writeFailureReported = true; onFailure?(error.localizedDescription) }
            NSLog("Audio write failed: %@", error.localizedDescription)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var query = ""
    @State private var folder: String? = nil
    @State private var detail = false
    @State private var settings = false
    @State private var modelToken = ""
    @State private var tab = "Итог"
    @AppStorage("darkAppearance") private var darkAppearance = false
    private var filtered: [Meeting] { store.meetings.filter { (folder == nil || $0.folder == folder) && (query.isEmpty || ($0.title + $0.notes + $0.transcript + $0.summary).localizedCaseInsensitiveContains(query)) }.sorted {$0.date > $1.date} }
    private var days: [Date] { Array(Set(filtered.map {Calendar.current.startOfDay(for:$0.date)})).sorted(by: >) }
    private func dayName(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Сегодня" }
        if Calendar.current.isDateInYesterday(date) { return "Вчера" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
    @FocusState private var searchFocused: Bool
    @State private var sidebarVisible = true
    @State private var searchVisible = false
    @State private var folderDraft: FolderDraft?
    @State private var deletingFolder: String?
    @State private var deletingMeeting: UUID?
    private var folders: [String] { store.folders }
    var body: some View {
        HStack(spacing:0) {
            if sidebarVisible && !detail { navigation; Divider() }
            VStack(spacing:0) {
                if (store.recording && !showRecordingInDocument) || store.starting || store.stopping {
                    recordingStrip
                        .frame(maxWidth: detail ? 730 : 850)
                        .padding(.horizontal, 40).padding(.top, 14)
                } else if !showRecordingInDocument && !["Готово", "Заметки готовы", "Папка сохранена", "Транскрипт готов", "Аудио сохранено", "Локальная суммаризация…", "Загрузка локальной Whisper-модели / распознавание…"].contains(store.status) {
                    Text(store.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.vertical, 10)
                }
                if detail, let i = store.meetings.firstIndex(where: {$0.id == store.selected}) { editor(i) }
                else { home }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(NotePalette.paper)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                if !detail {
                    Button { sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                        .help(sidebarVisible ? "Скрыть боковую панель" : "Показать боковую панель")
                }
                Button { searchVisible.toggle(); if !searchVisible { query = "" }; detail = false; searchFocused = searchVisible } label: { Image(systemName: "magnifyingglass") }
                    .help("Поиск записей")
            }
            ToolbarItem(placement: .automatic) { Spacer() }
            ToolbarItem(placement: .primaryAction) {
                if !store.recording {
                    Button("Записать звонок", systemImage: "record.circle") {
                        Task { await store.start() }
                    }.buttonStyle(NoteButtonStyle()).labelStyle(.titleAndIcon).disabled(store.starting || store.stopping)
                        .help("Записать микрофон и звук собеседников")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { store.add(folder: folder); detail = true } label: { Label("Новая заметка", systemImage: "plus") }
                    .buttonStyle(NoteButtonStyle(selected: true)).labelStyle(.titleAndIcon).keyboardShortcut("n")
            }
        }
        .onAppear { if ProcessInfo.processInfo.arguments.contains("--design-preview") { DispatchQueue.main.async { NSApp.windows.first(where: { $0.title == "A-notes" })?.setContentSize(NSSize(width:1440,height:1008)) } } }
        .tint(NotePalette.accent).preferredColorScheme(darkAppearance ? .dark : .light).frame(minWidth:960,minHeight:640)
        .onChange(of: store.selected) { _, id in tab = id == store.recordingID ? "Заметки" : "Итог" }
        .onChange(of: detail) { _, value in if value { tab = store.selected == store.recordingID ? "Заметки" : "Итог" } }
        .onChange(of: store.showRecording) { _, value in if value { detail = true; tab = store.selected == store.recordingID ? "Заметки" : "Итог"; store.showRecording = false } }
        .sheet(item: $folderDraft) { draft in
            FolderEditor(original: draft.original) { name in saveFolder(name, replacing: draft.original) }
        }
        .confirmationDialog("Удалить папку «\(deletingFolder ?? "")»? Записи останутся во «Входящих».", isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }), titleVisibility: .visible) {
            Button("Удалить папку", role: .destructive) {
                if let name = deletingFolder, store.changeLibrary({ try $0.deleteFolder(name) }), folder == name { folder = NoteLibrary.inbox }
                deletingFolder = nil
            }
        }
        .confirmationDialog("Удалить запись вместе с заметками, транскриптом и итогом? Аудиофайлы будут перемещены в Корзину.", isPresented: Binding(get: { deletingMeeting != nil }, set: { if !$0 { deletingMeeting = nil } }), titleVisibility: .visible) {
            Button("Удалить запись", role: .destructive) {
                if let id = deletingMeeting { store.deleteMeeting(id); if store.selected == nil { detail = false } }
                deletingMeeting = nil
            }
        }
        .onChange(of: store.meetings) { _, _ in store.save() }
    }
    private var showRecordingInDocument: Bool {
        detail && store.recording && store.selected == store.recordingID
    }
    private var recordingStrip: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 12) {
                if store.callWasActive { Label("Звонок активен", systemImage: "phone") }
                if store.recording,
                   let meeting = store.meetings.first(where: { $0.id == store.recordingID }) {
                    if store.automaticRecording { Text("Автозапись").foregroundStyle(.secondary) }
                    Circle().fill(.red).frame(width: 7, height: 7).accessibilityHidden(true)
                    let seconds = max(0, Int(context.date.timeIntervalSince(meeting.date)))
                    Text("Идёт запись · \(seconds / 60):\(String(format: "%02d", seconds % 60))").monospacedDigit()
                    Spacer()
                    if !detail || store.selected != meeting.id {
                        Button("Открыть запись") {
                            store.selected = meeting.id
                            detail = true
                            tab = "Заметки"
                        }.buttonStyle(NoteButtonStyle(selected: true))
                    }
                    Button("Остановить", systemImage: "stop") { Task { await store.stop() } }
                        .buttonStyle(NoteButtonStyle())
                } else {
                    Text(store.stopping ? "Сохраняем аудио…" : "Запускаем запись…")
                    Spacer()
                }
            }.font(.system(size: 13))
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(NotePalette.surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }
    private func folderLabel(_ name: String) -> some View {
        let colors: [Color] = [.teal, .purple, .orange, .blue]
        let index = name.utf8.reduce(0) { ($0 + Int($1)) % colors.count }
        return Text(name).lineLimit(1).padding(.horizontal, 6).padding(.vertical, 2)
            .background(colors[index].opacity(0.14), in: Capsule())
    }
    private func rowStatus(_ meeting: Meeting) -> String {
        guard let stage = meeting.job?.stage else { return "Без аудио" }
        if stage == "Аудиозаписи нет" { return meeting.job?.captureError == nil ? "Без аудио" : "Запись прервана" }
        if stage.hasPrefix("Распознавание") || stage == "Подготовка распознавания" { return "Распознавание" }
        if stage.hasPrefix("В очереди") { return "В очереди" }
        if meeting.job?.error != nil || stage == "Речь не обнаружена" { return "Нужен повтор" }
        return stage
    }
    private var settingsPanel: some View {
        ScrollView { VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Настройки").font(.system(size: 22, weight: .semibold))
                Spacer()
                Button { settings = false } label: { Image(systemName: "xmark").frame(width: 12) }
                    .buttonStyle(NoteButtonStyle()).keyboardShortcut(.cancelAction).accessibilityLabel("Закрыть настройки").help("Закрыть · Esc")
            }
            Picker("Оформление", selection: $darkAppearance) {
                Text("Светлое").tag(false)
                Text("Тёмное").tag(true)
            }.pickerStyle(.segmented)
            settingsField("Начало записи") {
                Picker("Начало записи", selection: $store.mode) {
                    ForEach(["Вручную", "Предлагать", "Автоматически"], id: \.self) { Text($0) }
                }
            }
            settingsField("Модель распознавания · Whisper") {
                Picker("Модель распознавания", selection: $store.asrModel) {
                    ForEach(Array(Set(store.asrModels + [store.asrModel])).sorted(), id: \.self) { Text($0).tag($0) }
                }
            }
            settingsField("Подключение для итогов") {
                Picker("Подключение", selection: $store.localModels.provider) {
                    ForEach(LocalModelProvider.allCases) { Text($0.title).tag($0) }
                }.onChange(of: store.localModels.provider) { _, _ in
                    modelToken = ""
                    Task { await store.refreshModels() }
                }
            }
            settingsField("Адрес сервера") {
                TextField("Адрес сервера", text: $store.serverURL).textFieldStyle(.roundedBorder)
            }
            settingsField("Модель итога") {
                HStack {
                    TextField("Идентификатор модели", text: $store.model).textFieldStyle(.roundedBorder)
                    Menu("Выбрать") {
                        ForEach(store.summaryModels, id: \.self) { name in Button(name) { store.model = name } }
                        if store.summaryModels.isEmpty { Text("Обновите список моделей") }
                    }.fixedSize()
                }
            }
            HStack {
                SecureField("API-токен, если включён на сервере", text: $modelToken).textFieldStyle(.roundedBorder)
                Button("Сохранить токен") { store.saveModelToken(modelToken); modelToken = "" }.disabled(modelToken.isEmpty)
                Button("Удалить токен") { store.saveModelToken(""); modelToken = "" }
            }.font(.caption)
            Text(store.connection.locationDescription).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Проверить связь") { Task { await store.checkConnection() } }.disabled(store.checkingConnection || store.model.isEmpty)
                if store.checkingConnection { ProgressView().controlSize(.small) }
            }
            Text(store.modelStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Button { Task { await store.refreshModels() } } label: {
                    Label("Обновить список моделей", systemImage: "arrow.clockwise").frame(maxWidth: .infinity, alignment: .leading)
                }.disabled(store.refreshingModels)
                Button {
                    var components = URLComponents()
                    components.scheme = "obsidian"
                    components.host = "open"
                    components.queryItems = [URLQueryItem(name: "path", value: store.vaultStorage.vault.path)]
                    if let url = components.url, !NSWorkspace.shared.open(url) {
                        NSWorkspace.shared.open(store.vaultStorage.vault)
                    }
                } label: {
                    Label("Открыть хранилище Obsidian", systemImage: "link").frame(maxWidth: .infinity, alignment: .leading)
                }
                Button { store.save() } label: {
                    Label("Обновить из Obsidian", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                } label: {
                    Label("Уведомления macOS", systemImage: "bell").frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {
                    if let url = Bundle.main.url(forResource: "CODEX_SETUP", withExtension: "md") { NSWorkspace.shared.open(url) }
                } label: { Label("Инструкция для Codex", systemImage: "doc.text").frame(maxWidth: .infinity, alignment: .leading) }
            }.buttonStyle(NoteButtonStyle())
            HStack {
                Text("Изменения сохраняются автоматически").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Готово") { settings = false }.buttonStyle(NoteButtonStyle(selected: true)).keyboardShortcut(.defaultAction)
            }
        }.padding(24) }.frame(width: 540, height: 710).background(NotePalette.paper)
            .onAppear { if store.persistedSettingsEnabled { store.localModels = LocalModelSettings.load() } }
            .onExitCommand { settings = false }
    }
    private func settingsField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            content().labelsHidden().pickerStyle(.menu).controlSize(.large).frame(maxWidth: .infinity)
        }
    }
    private var navigation: some View {
        VStack(alignment: .leading, spacing: 0) {
            navRow("Все заметки", icon: "house", selected: folder == nil && !detail) { folder = nil; detail = false }
                .modifier(NoteRowSurface(selected: folder == nil && !detail)).padding(.top, 16)
            HStack {
                Text("Папки").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button { folderDraft = FolderDraft() } label: { Image(systemName: "plus").frame(width: 12) }
                    .buttonStyle(NoteButtonStyle()).help("Создать папку").accessibilityLabel("Создать папку")
            }.padding(.leading, 10).padding(.top, 24).padding(.bottom, 6)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(folders, id: \.self) { name in
                        HStack(spacing: 0) {
                            navRow(name, icon: "folder", selected: folder == name) { folder = name; detail = false }
                            if name != NoteLibrary.inbox {
                                Menu { folderActions(name) } label: {
                                    Image(systemName: "ellipsis").frame(width: 28, height: 32).contentShape(Rectangle())
                                        .modifier(NoteRowSurface())
                                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().padding(.trailing, 4)
                                    .accessibilityLabel("Действия с папкой «\(name)»").help("Действия с папкой")
                            }
                        }.modifier(NoteRowSurface(selected: folder == name))
                            .contextMenu { if name != NoteLibrary.inbox { folderActions(name) } }
                    }
                }
            }.scrollIndicators(.hidden)
            Button { settings.toggle() } label: {
                Label("Настройки", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(NoteButtonStyle(selected: settings)).padding(.vertical, 10)
                .popover(isPresented: $settings, arrowEdge: .trailing) { settingsPanel }
        }.padding(.horizontal, 10).frame(width: 228).background(NotePalette.sidebar)
    }
    private func navRow(_ title: String, icon: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 15)).frame(width: 18)
                Text(title).font(.system(size: 14)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(NoteButtonStyle()).frame(height: 36).help(title)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var home: some View {
        GeometryReader { geometry in
            let width = min(850, geometry.size.width - 80)
            ZStack(alignment:.bottom) {
                ScrollView {
                    VStack(alignment:.leading,spacing:38) {
                        if searchVisible {
                            HStack { Image(systemName:"magnifyingglass"); TextField("Поиск заметок",text:$query).accessibilityLabel("Поиск заметок").textFieldStyle(.plain).focused($searchFocused).onExitCommand { query = ""; searchVisible = false }; Button { query = ""; searchVisible = false } label: { Image(systemName:"xmark") }.buttonStyle(NoteButtonStyle()).accessibilityLabel("Закрыть поиск") }.padding(12).background(NotePalette.surface,in:RoundedRectangle(cornerRadius:10))
                        }
                        Text(folder ?? "Все заметки").font(.system(size:28,weight:.semibold))
                        if filtered.isEmpty { Text(query.isEmpty ? "Здесь появятся ваши заметки" : "Ничего не найдено").font(.system(size:16)).foregroundStyle(.secondary).padding(.top,24) }
                        ForEach(days,id: \.self) { day in
                            VStack(alignment:.leading,spacing:8) {
                                Text(dayName(day)).font(.system(size:14,weight:.medium)).foregroundStyle(.secondary).padding(.bottom,2)
                                ForEach(filtered.filter {Calendar.current.isDate($0.date,inSameDayAs:day)}) { meeting in
                                    HStack(alignment: .top, spacing: 12) {
                                    Button { store.selected = meeting.id; detail = true } label: {
                                        HStack(alignment:.top,spacing:20) {
                                            Image(systemName: meeting.job?.duration ?? 0 > 0 ? "mic" : "doc")
                                                .font(.system(size: 15)).foregroundStyle(.secondary)
                                                .frame(width: 32, height: 32)
                                                .background(NotePalette.surface, in: RoundedRectangle(cornerRadius: 8))
                                            VStack(alignment: .leading, spacing: 5) {
                                                Text(meeting.title).font(.system(size: 15, weight: .medium)).lineLimit(2)
                                                HStack(spacing: 8) {
                                                    folderLabel(meeting.folder)
                                                    Text(rowStatus(meeting)).foregroundStyle(.secondary)
                                                }.font(.system(size: 12))
                                            }
                                            Spacer(minLength: 8)
                                            Text(meeting.date.formatted(date:.omitted,time:.shortened)).font(.system(size:14)).foregroundStyle(.secondary).frame(width:43,alignment:.trailing).padding(.top,8)
                                        }.frame(minHeight:52,alignment:.top).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    Menu { meetingActions(meeting) } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32).contentShape(Rectangle()) }
                                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 32, height: 32)
                                        .accessibilityLabel("Действия с записью «\(meeting.title)»").help("Действия с записью")
                                    }.padding(.horizontal, 12).padding(.vertical, 6).modifier(NoteRowSurface()).contextMenu { meetingActions(meeting) }
                                }
                            }
                        }
                    }.frame(width:width,alignment:.leading).padding(.top,20).padding(.bottom,32).frame(maxWidth:.infinity)
                }.scrollIndicators(.hidden)
            }
        }
    }
    private func saveFolder(_ name: String, replacing old: String?) -> String? {
        let ok = store.changeLibrary { library in
            if let old { try library.renameFolder(old, to: name) }
            else { try library.createFolder(name) }
        }
        guard ok else { return store.status }
        store.status = "Папка сохранена"
        if folder == old || old == nil { folder = name.trimmingCharacters(in: .whitespacesAndNewlines) }
        detail = false
        return nil
    }
    @ViewBuilder private func folderActions(_ name: String) -> some View {
        Button("Переименовать") { DispatchQueue.main.async { folderDraft = FolderDraft(original: name) } }
        Button("Удалить папку", role: .destructive) { DispatchQueue.main.async { deletingFolder = name } }
    }
    @ViewBuilder private func meetingActions(_ meeting: Meeting) -> some View {
        Menu("Переместить в папку") {
            ForEach(folders, id: \.self) { destination in
                Button(destination) { store.changeLibrary { try $0.move(meeting.id, to: destination) } }
                    .disabled(destination == meeting.folder)
            }
        }
        Button("Удалить запись", role: .destructive) { DispatchQueue.main.async { deletingMeeting = meeting.id } }
            .disabled(!store.canDelete(meeting.id))
    }
    private func editor(_ i: Int) -> some View {
        VStack(alignment:.leading,spacing:20) {
            Button {
                detail = false
            } label: {
                Label(folder ?? "Все заметки", systemImage: "chevron.left")
            }.buttonStyle(NoteButtonStyle()).help("Вернуться к списку записей")
            TextField("Название",text:$store.meetings[i].title, axis: .vertical).accessibilityLabel("Название записи").lineLimit(1...3).textFieldStyle(.plain).font(.system(size:28,weight:.semibold))
            HStack(spacing: 12) {
                Text(store.meetings[i].date.formatted(date: .long, time: .shortened)).foregroundStyle(.secondary)
                if store.meetings[i].id != store.recordingID {
                    Text(rowStatus(store.meetings[i])).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(folders, id: \.self) { destination in
                        Button {
                            let id = store.meetings[i].id
                            store.changeLibrary { try $0.move(id, to: destination) }
                        } label: {
                            if destination == store.meetings[i].folder {
                                Label(destination, systemImage: "checkmark")
                            } else { Text(destination) }
                        }.disabled(destination == store.meetings[i].folder)
                    }
                } label: {
                    Label(store.meetings[i].folder, systemImage: "folder")
                }.fixedSize().accessibilityLabel("Папка встречи: \(store.meetings[i].folder)")
            }.font(.system(size: 12))
            if showRecordingInDocument { recordingStrip }
            HStack(spacing: 4) {
                ForEach(["Итог", "Транскрипт", "Заметки"], id: \.self) { name in
                    Button(name) { tab = name }
                        .buttonStyle(NoteButtonStyle(selected: tab == name, capsule: true))
                        .accessibilityAddTraits(tab == name ? .isSelected : [])
                }
            }.padding(3).background(NotePalette.surface, in: Capsule())
            if tab == "Транскрипт" {
                TranscriptChat(transcript: store.meetings[i].transcript, attributions: store.meetings[i].speakerAttributions ?? [])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tab == "Итог" && store.meetings[i].summary.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        if store.meetings[i].job?.pending == true { ProgressView().controlSize(.small) }
                        Text(store.meetings[i].job?.pending == true ? "Обработка записи" : "Итога пока нет").font(.title3)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(store.feedback(store.meetings[i], now: context.date)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text(store.meetings[i].job?.pending == true ? "Задание сохранено. Обработка продолжится автоматически, в том числе после выхода Mac из сна. Можно продолжать писать заметки." : store.meetings[i].transcript.isEmpty ? "После записи звонка транскрипт и итог появятся автоматически. Пока можно писать заметки." : "Транскрипт сохранён. Запустите создание итога повторно — распознавать аудио заново не нужно.")
                        .font(.callout).foregroundStyle(.secondary)
                    if !store.meetings[i].transcript.isEmpty {
                        Button(store.meetings[i].job?.pending == true ? "Обработка…" : "Запустить итог заново") {
                            let id = store.meetings[i].id
                            Task { await store.summarize(meetingID: id) }
                        }.buttonStyle(NoteButtonStyle(selected: true)).disabled(store.meetings[i].job?.pending == true)
                    } else {
                        Button("Открыть заметки") { tab = "Заметки" }.buttonStyle(NoteButtonStyle(selected: true))
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    .background(NotePalette.surface, in: RoundedRectangle(cornerRadius: 12))
                Spacer()
            } else if tab == "Итог" {
                SummaryView(text: $store.meetings[i].summary).id(store.meetings[i].id)
            } else {
                TextEditor(text: $store.meetings[i].notes)
                    .font(.system(size: 16)).lineSpacing(5).scrollContentBackground(.hidden).accessibilityLabel("Заметки встречи")
            }
            Divider()
            HStack(spacing: 8) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 8) {
                        if store.meetings[i].job?.pending == true { ProgressView().controlSize(.small) }
                        Text(store.feedback(store.meetings[i], now: context.date)).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    }
                }
                Spacer(minLength: 12)
                Menu {
                    Button("Показать Markdown в хранилище") {
                        NSWorkspace.shared.selectFile(store.vaultStorage.meetingURL(store.meetings[i].id).appendingPathComponent("index.md").path, inFileViewerRootedAtPath: "")
                    }
                    Button("Экспортировать в .txt…") { exportText(store.meetings[i]) }
                    Button("Открыть текстовый файл") { openText(store.meetings[i]) }
                } label: { Label("Экспорт", systemImage: "square.and.arrow.up").padding(.horizontal, 8).frame(height: 32) }
                    .menuStyle(.borderlessButton).fixedSize().modifier(NoteRowSurface())
                Menu {
                    Button("Распознать аудио повторно") { let id = store.meetings[i].id; Task { await store.transcribe(meetingID: id) } }
                        .disabled(store.recording || store.starting || store.stopping || store.meetings[i].job?.pending == true || store.audioDuration(store.meetings[i].id) == 0)
                    Button(store.meetings[i].summary.isEmpty ? "Повторить создание итога" : "Обновить итог") { let id = store.meetings[i].id; Task { await store.summarize(meetingID: id) } }
                        .disabled(store.meetings[i].job?.pending == true || store.meetings[i].transcript.isEmpty)
                    if store.audioDuration(store.meetings[i].id) > 0 {
                        Button("Показать аудиофайлы в Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: store.root.appendingPathComponent(store.meetings[i].id.uuidString).path) }
                    }
                    Divider()
                    meetingActions(store.meetings[i])
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 32).contentShape(Rectangle()) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().modifier(NoteRowSurface())
                    .accessibilityLabel("Действия с записью").help("Действия с записью")
            }

        }.frame(maxWidth:730, maxHeight: .infinity, alignment: .top).padding(.horizontal,40).padding(.top,30).padding(.bottom,20).frame(maxWidth:.infinity)
    }
    private func exportText(_ meeting: Meeting) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = MeetingExport.filename(meeting)
        panel.title = "Экспорт заметки"
        guard let window = NSApp.windows.first(where: { $0.title == "A-notes" && $0.isVisible }) else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try MeetingExport.write(meeting, to: url) }
            catch { store.status = "Не удалось экспортировать: \(error.localizedDescription)" }
        }
    }
    private func openText(_ meeting: Meeting) {
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("A-notes-Export").appendingPathComponent(meeting.id.uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(MeetingExport.filename(meeting))
            try MeetingExport.write(meeting, to: url)
            if !NSWorkspace.shared.open(url) { store.status = "Не удалось открыть текстовый файл" }
        } catch { store.status = "Не удалось создать текстовый файл: \(error.localizedDescription)" }
    }

}
struct AntonNotesApp: App {
    @StateObject var store = Store()
    var body: some Scene { WindowGroup("A-notes") { ContentView().environmentObject(store) }.windowStyle(.hiddenTitleBar).windowToolbarStyle(.unified).defaultSize(width:1440,height:1008) }
}

if SetupCommand.runIfRequested() { dispatchMain() }
else { AntonNotesApp.main() }
