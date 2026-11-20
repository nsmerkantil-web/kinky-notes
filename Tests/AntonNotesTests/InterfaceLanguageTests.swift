import Testing
@testable import AntonNotes

@Test func interfaceLanguageTranslatesPersistedStagesAndKeepsDynamicValues() {
    let stage = "Распознавание · Удалённая сторона · 30/90 с"
    #expect(InterfaceLanguage.english.message(stage) == "Transcribing · Remote audio · 30/90 s")
    #expect(InterfaceLanguage.russian.message(stage) == stage)
    #expect(InterfaceLanguage.english.message("Ошибка записи [AVFAudio:-40]: Disk full") == "Recording failed [AVFAudio:-40]: Disk full")
    #expect(InterfaceLanguage.english.message("Не удалось сохранить: File \"library.json\" is out of space.") == "Couldn’t save: File \"library.json\" is out of space.")
    #expect(InterfaceLanguage.english.folder(NoteLibrary.inbox) == "Inbox")
    #expect(InterfaceLanguage.english.folder("Транскрипт") == "Транскрипт")
    #expect(SummaryService.isPlaceholderTitle(InterfaceLanguage.english.defaultMeetingTitle()))
    #expect(!SummaryService.isPlaceholderTitle("Meeting with Alex"))
}
