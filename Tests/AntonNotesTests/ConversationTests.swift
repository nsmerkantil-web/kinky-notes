import Testing
@testable import AntonNotes

@Test func conversationKeepsChannelsAndUnknownText() {
    let turns = Conversation.turns("[1 с] Локальный микрофон: Привет\n[2 с] Удалённая сторона: Меня зовут Анна.\nПродолжение\n[3 с] Удалённая сторона: Да")
    #expect(turns.count == 3)
    #expect(turns[0].side == .local)
    #expect(turns[1].side == .remote)
    #expect(turns[1].text == "Меня зовут Анна.\nПродолжение")
    #expect(Conversation.turns("Старый текст без каналов")[0].side == .unknown)
}

@Test func namesNeedEvidenceAndNeverCrossChannelsOrSurviveChangedText() {
    let transcript = "[1 с] Локальный микрофон: Анна, привет\n[2 с] Удалённая сторона: Меня зовут Анна."
    let turns = Conversation.turns(transcript)
    let good = SpeakerAttribution(turnID: 1, text: turns[1].text, name: "Анна", evidence: "Меня зовут Анна.")
    #expect(Conversation.validated([good], transcript: transcript) == [good])
    #expect(Conversation.validated([SpeakerAttribution(turnID: 0, text: turns[0].text, name: "Анна", evidence: "Анна, привет")], transcript: transcript).isEmpty)
    #expect(Conversation.validated([SpeakerAttribution(turnID: 1, text: turns[1].text, name: "Мария", evidence: "Меня зовут Анна.")], transcript: transcript).isEmpty)
    #expect(Conversation.validated([good], transcript: transcript.replacingOccurrences(of: "Анна.", with: "Мария.")).isEmpty)
    #expect(Conversation.validated([good, SpeakerAttribution(turnID: 1, text: turns[1].text, name: "Анна Иванова", evidence: "Анна Иванова")], transcript: transcript).isEmpty)
}
