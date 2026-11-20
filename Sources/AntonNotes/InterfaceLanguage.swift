import Foundation

enum InterfaceLanguage: String, CaseIterable {
    case russian = "ru"
    case english = "en"

    static let preferenceKey = "interfaceLanguage"
    static var selected: Self {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .russian
    }

    var title: String { self == .russian ? "Русский" : "English" }
    var locale: Locale { Locale(identifier: rawValue) }
    var meetingTitlePrefix: String { self == .russian ? "Встреча " : "Meeting · " }

    func defaultMeetingTitle() -> String {
        meetingTitlePrefix + Date().formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale))
    }

    func text(_ source: String) -> String {
        self == .english ? Self.englishStrings[source] ?? source : source
    }

    func folder(_ name: String) -> String {
        name == NoteLibrary.inbox ? text(name) : name
    }

    // Processing stages are stored with their original Russian values. Translate
    // them at display time so queue recovery also works with existing libraries.
    func message(_ source: String) -> String {
        guard self == .english else { return source }
        if let translation = Self.englishStrings[source] { return translation }
        guard source.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil else { return source }
        let range = NSRange(source.startIndex..., in: source)
        for (pattern, translation) in Self.messagePatterns {
            guard let match = pattern.firstMatch(in: source, range: range) else { continue }
            let arguments = (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: source).map { String(source[$0]) } ?? ""
            }
            return translation.split(separator: "{", omittingEmptySubsequences: false).enumerated().map { index, part in
                guard index > 0, let end = part.firstIndex(of: "}"),
                      let position = Int(part[..<end]), arguments.indices.contains(position - 1) else { return String(part) }
                return arguments[position - 1] + part[part.index(after: end)...]
            }.joined()
        }
        return source
    }

    private static let englishStrings = [
        "Обнаружен звонок": "Call detected",
        "Сделать заметку": "Take notes",
        "Готово": "Done",
        "Закрыть": "Close",
        "Настройки": "Settings",
        "Основные": "General",
        "Итоги и подключение": "Summary & connection",
        "Интеграции": "Integrations",
        "Развёрнуто": "Expanded",
        "Свёрнуто": "Collapsed",
        "Выбрать модель": "Choose model",
        "Параметры подключения": "Connection settings",
        "API-токен": "API token",
        "Действия с токеном": "Token actions",
        "Дополнительные действия": "More actions",
        "Закрыть настройки": "Close settings",
        "Закрыть · Esc": "Close · Esc",
        "Язык интерфейса": "Interface language",
        "Оформление": "Appearance",
        "Светлое": "Light",
        "Тёмное": "Dark",
        "Начало записи": "Start recording",
        "Вручную": "Manually",
        "Предлагать": "Ask first",
        "Автоматически": "Automatically",
        "Модель распознавания · Whisper": "Transcription model · Whisper",
        "Модель распознавания": "Transcription model",
        "Подключение для итогов": "Summary provider",
        "Подключение": "Provider",
        "Адрес сервера": "Server address",
        "Модель итога": "Summary model",
        "Идентификатор модели": "Model ID",
        "Выбрать": "Select",
        "Обновите список моделей": "Refresh the model list",
        "API-токен, если включён на сервере": "API token, if required by the server",
        "Сохранить токен": "Save token",
        "Удалить токен": "Remove token",
        "Проверить связь": "Test connection",
        "Обновить список моделей": "Refresh model list",
        "Открыть хранилище Obsidian": "Open Obsidian vault",
        "Обновить из Obsidian": "Refresh from Obsidian",
        "Уведомления macOS": "macOS notifications",
        "Инструкция для Codex": "Codex instructions",
        "Изменения сохраняются автоматически": "Changes are saved automatically",
        "Все заметки": "All notes",
        "Входящие": "Inbox",
        "Папки": "Folders",
        "Создать папку": "Create folder",
        "Действия с папкой": "Folder actions",
        "Поиск заметок": "Search notes",
        "Закрыть поиск": "Close search",
        "Здесь появятся ваши заметки": "Your notes will appear here",
        "Ничего не найдено": "No results",
        "Действия с записью": "Recording actions",
        "Переименовать": "Rename",
        "Удалить папку": "Delete folder",
        "Переместить в папку": "Move to folder",
        "Удалить запись": "Delete recording",
        "Вернуться к списку записей": "Back to recordings",
        "Название": "Title",
        "Название записи": "Recording title",
        "Итог": "Summary",
        "Транскрипт": "Transcript",
        "Заметки": "Notes",
        "Аудиозапись сохранена. Распознавание не завершено.": "Audio is saved. Transcription is incomplete.",
        "Аудиозапись и транскрипт сохранены. Создание итога не завершено.": "Audio and transcript are saved. The summary is incomplete.",
        "Повторить": "Retry",
        "Обработка записи": "Processing recording",
        "Итога пока нет": "Summary unavailable",
        "Задание сохранено. Обработка продолжится автоматически, в том числе после выхода Mac из сна. Можно продолжать писать заметки.": "Processing will resume automatically, including after your Mac wakes. You can keep taking notes.",
        "После записи звонка транскрипт и итог появятся автоматически. Пока можно писать заметки.": "The transcript and summary will appear automatically after the call is recorded. You can take notes now.",
        "Транскрипт сохранён. Можно запустить создание итога повторно.": "The transcript is saved. You can retry the summary.",
        "Обработка…": "Processing…",
        "Запустить итог заново": "Retry summary",
        "Открыть заметки": "Open notes",
        "Заметки встречи": "Meeting notes",
        "Показать Markdown в хранилище": "Show Markdown in vault",
        "Экспортировать в .txt…": "Export as .txt…",
        "Открыть текстовый файл": "Open text file",
        "Экспорт": "Export",
        "Распознать аудио повторно": "Transcribe audio again",
        "Повторить создание итога": "Retry summary",
        "Обновить итог": "Regenerate summary",
        "Показать аудиофайлы в Finder": "Show audio files in Finder",
        "Экспорт заметки": "Export note",
        "Сегодня": "Today",
        "Вчера": "Yesterday",
        "Скрыть боковую панель": "Hide sidebar",
        "Показать боковую панель": "Show sidebar",
        "Записать звонок": "Record call",
        "Записать микрофон и звук собеседников": "Record microphone and remote audio",
        "Новая заметка": "New note",
        "Удалить запись вместе с заметками, транскриптом и итогом? Аудиофайлы будут перемещены в Корзину.": "Delete this recording, its notes, transcript, and summary? Audio files will be moved to the Trash.",
        "Звонок активен": "Call active",
        "Автозапись": "Automatic recording",
        "Открыть запись": "Open recording",
        "Остановить": "Stop",
        "Сохраняем аудио…": "Saving audio…",
        "Запускаем запись…": "Starting recording…",
        "Без аудио": "No audio",
        "Запись прервана": "Recording interrupted",
        "Распознавание": "Transcribing",
        "В очереди": "Queued",
        "Нужен повтор": "Retry needed",
        "Переименовать папку": "Rename folder",
        "Название папки": "Folder name",
        "Например, Работа": "For example, Work",
        "Отмена": "Cancel",
        "Создать": "Create",
        "Сохранить": "Save",
        "Транскрипт пока не готов": "Transcript unavailable",
        "Реплики появятся после распознавания аудио.": "The conversation will appear after transcription.",
        "Вы": "You",
        "Собеседник": "Other speaker",
        "Редактировать": "Edit",
        "Редактирование итога встречи": "Editing meeting summary",
        "Итог встречи": "Meeting summary",
        "Начать заметку и запись звонка?": "Start a note and record the call?",
        "Запись завершена": "Recording finished",
        "Аудио сохранено. Расшифровка поставлена в обработку.": "Audio is saved and queued for transcription.",
        "Аудио не записалось; расшифровка недоступна.": "No audio was recorded. Transcription is unavailable.",
        "Транскрипт и саммари готовы": "Transcript and summary are ready",
        "Нажмите, чтобы открыть заметки встречи.": "Click to open the meeting notes.",
        "Разрешите уведомления A-notes в настройках macOS → Уведомления": "Allow A-notes notifications in macOS System Settings → Notifications",
        "Поиск записей": "Search recordings",
        "Аудиозаписи нет": "No audio recording",
        "Нет обработки": "No processing",
        "Аудио сохранено": "Audio saved",
        "Транскрипт готов": "Transcript ready",
        "Запись": "Recording",
        "Ошибка записи": "Recording failed",
        "Запись завершилась неожиданно": "Recording ended unexpectedly",
        "В очереди · восстановлено": "Queued · recovered",
        "В очереди · после сна": "Queued · resumed after sleep",
        "В очереди · создание итога": "Queued · summary",
        "Пауза · Mac спит": "Paused · Mac asleep",
        "Подготовка распознавания": "Preparing transcription",
        "Локальный микрофон": "Microphone",
        "Удалённая сторона": "Remote audio",
        "Речь не обнаружена": "No speech detected",
        "Ошибка распознавания": "Transcription failed",
        "Транскрипт готов; ошибка итога": "Transcript ready · summary failed",
        "Создание итога": "Creating summary",
        "Создание подробного итога": "Creating detailed summary",
        "Повтор генерации · ответ неполный или неверно оформлен": "Retrying generation · incomplete or invalid response",
        "Подбор названия": "Generating title",
        "Заметки готовы": "Notes ready",
        "Подключение изменено · проверьте связь": "Connection changed · test the connection",
        "Проверка моделей…": "Checking models…",
        "Проверка ответа модели…": "Checking model response…",
        "Токен удалён из Связки ключей": "Token removed from Keychain",
        "Токен сохранён в Связке ключей · проверьте связь": "Token saved to Keychain · test the connection",
        "Сервер на этом Mac. Выбирайте локальную модель для обработки без облака.": "Server on this Mac. Choose a local model to process without the cloud.",
        "Текст будет отправлен на указанный сервер.": "Text will be sent to the specified server.",
        "Папка сохранена": "Folder saved",
        "Встроенная Whisper-модель повреждена. Переустановите A-notes; аудио сохранено.": "The bundled Whisper model is damaged. Reinstall A-notes. Audio is saved.",
        "Отсутствуют файлы встроенного tokenizer. Переустановите A-notes.": "Bundled tokenizer files are missing. Reinstall A-notes.",
        "Загрузка локальной Whisper-модели / распознавание…": "Loading local Whisper model / transcribing…",
        "Локальная суммаризация…": "Generating summary locally…",
        "Разрешите микрофон в настройках macOS": "Allow microphone access in macOS System Settings",
        "Запись микрофона и системного звука": "Recording microphone and system audio",
        "Запись прервана; сохранённое аудио отправлено в обработку": "Recording interrupted. Saved audio is queued for processing.",
        "У этой встречи нет аудиозаписи": "This meeting has no audio recording",
        "Нет аудио или распознанной речи": "No audio or recognizable speech",
        "Итог поставлен в очередь": "Summary queued",
        "Создаём итог…": "Creating summary…",
        "Транскрипт изменился. Запустите итог заново.": "The transcript changed. Retry the summary.",
        "Формат аудиоустройства изменился во время записи": "The audio device format changed during recording",
        "Не удалось открыть текстовый файл": "Couldn’t open the text file",
        "Введите название папки (до 80 символов).": "Enter a folder name of up to 80 characters.",
        "Папка с таким названием уже существует.": "A folder with this name already exists.",
        "Папка или запись больше не существует.": "The folder or recording no longer exists.",
        "Папку «Входящие» нельзя переименовать или удалить.": "The Inbox can’t be renamed or deleted.",
        "Укажите HTTP(S)-адрес сервера без пароля, query и fragment.": "Enter an HTTP(S) server URL without a password, query, or fragment.",
        "Неверный адрес сервера.": "Invalid server address.",
        "Модель не завершила ответ. Предыдущий итог сохранён; проверьте контекст модели и повторите.": "The model returned an incomplete response. The previous summary is saved. Check the model context and retry.",
        "Модель вернула слишком краткий или неполный итог. Предыдущая версия сохранена; повторите создание итога.": "The model returned a short or incomplete summary. The previous version is saved. Retry the summary.",
        "Выберите модель в настройках Ollama или LM Studio. Транскрипт сохранён.": "Select an Ollama or LM Studio model in Settings. The transcript is saved.",
        "macOS отклонила захват. После изменения разрешения полностью перезапустите A-notes. Если переключатель уже включён, удалите A-notes из списка записи экрана и добавьте текущую сборку заново.": "macOS denied capture. Restart A-notes after changing the permission. If it is already enabled, remove A-notes from the Screen Recording list and add the current app again.",
        "Дольше оценки, обработка продолжается": "Taking longer than expected",
        "Оценка времени уточняется": "Estimating time remaining",
    ]

    private static let messagePatterns: [(NSRegularExpression, String)] = [
        ("Удалить папку «{1}»? Записи останутся во «Входящих».", "Delete “{1}”? Its recordings will move to Inbox."),
        ("Идёт запись · {1}:{2}", "Recording · {1}:{2}"),
        ("Действия с папкой «{1}»", "Actions for folder “{1}”"),
        ("Действия с записью «{1}»", "Actions for recording “{1}”"),
        ("Папка встречи: {1}", "Meeting folder: {1}"),
        ("Аудио {1}:{2}", "Audio {1}:{2}"),
        ("Запись прервана: {1}", "Recording interrupted: {1}"),
        ("≈ {1} мин до готовности", "About {1} min remaining"),
        ("Распознавание · Локальный микрофон · {1}/{2} с", "Transcribing · Microphone · {1}/{2} s"),
        ("Распознавание · Удалённая сторона · {1}/{2} с", "Transcribing · Remote audio · {1}/{2} s"),
        ("Подробные заметки · часть {1} из {2}", "Detailed notes · part {1} of {2}"),
        ("Не удалось прочитать заметки: {1}. Файлы не перезаписаны.", "Couldn’t read the notes: {1}. The files were preserved."),
        ("Не удалось очистить старые транскрипты: {1}", "Couldn’t clean up older transcripts: {1}"),
        ("Сервер доступен, моделей нет. Загрузите текстовую модель в {1}.", "Server reachable. Load a text model in {1}."),
        ("{1} доступна · моделей: {2}. Выберите модель и проверьте связь.", "{1} reachable · {2} models. Select a model and test the connection."),
        ("{1} · {2} отвечает. Подключение готово.", "{1} · {2} responded. Connection ready."),
        ("Не удалось сохранить: {1}", "Couldn’t save: {1}"),
        ("Запись удалена; не удалось переместить аудио в Корзину: {1}", "Recording deleted. Couldn’t move audio to the Trash: {1}"),
        ("Ошибка записи [{1}:{2}]: {3}", "Recording failed [{1}:{2}]: {3}"),
        ("Ошибка распознавания: {1}", "Transcription failed: {1}"),
        ("Не удалось создать итог: {1}", "Couldn’t create the summary: {1}"),
        ("Не удалось экспортировать: {1}", "Couldn’t export: {1}"),
        ("Не удалось создать текстовый файл: {1}", "Couldn’t create the text file: {1}"),
        ("Уведомление: {1}", "Notification: {1}"),
        ("Не удалось прочитать токен из Связки ключей ({1}).", "Couldn’t read the token from Keychain ({1})."),
        ("Не удалось удалить токен ({1}).", "Couldn’t remove the token ({1})."),
        ("Не удалось сохранить токен в Связке ключей ({1}).", "Couldn’t save the token in Keychain ({1})."),
        ("{1}: сервер отклонил доступ. Проверьте API-токен в настройках.", "{1}: server denied access. Check the API token in Settings."),
        ("{1}: token repeat limit reached. Повторите генерацию.", "{1}: token repeat limit reached. Retry generation."),
        ("{1}: адрес или модель не найдены. Обновите список моделей и проверьте адрес.", "{1}: address or model unavailable. Refresh the model list and check the address."),
        ("{1}: ошибка сервера HTTP {2}. Проверьте загруженную модель, контекст и свободную память.", "{1}: HTTP {2}. Check the loaded model, context, and available memory."),
        ("{1} не отвечает. Запустите приложение и API Server, проверьте адрес. Транскрипт сохранён.", "{1} isn’t responding. Start the app and its API server and check the address. The transcript is saved."),
    ].compactMap { (source: String, translation: String) in
        let pattern = NSRegularExpression.escapedPattern(for: source)
            .replacingOccurrences(of: #"\{1\}"#, with: "(.*?)")
            .replacingOccurrences(of: #"\{2\}"#, with: "(.*?)")
            .replacingOccurrences(of: #"\{3\}"#, with: "(.*?)")
        return (try? NSRegularExpression(pattern: "^" + pattern + "$", options: .dotMatchesLineSeparators))
            .map { ($0, translation) }
    }
}
