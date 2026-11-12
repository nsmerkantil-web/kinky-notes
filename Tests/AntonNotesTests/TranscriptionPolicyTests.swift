import Foundation

import Testing
@testable import AntonNotes

@Test func multilingualTranscriptionWithoutControlTokens() {
    let options = TranscriptionPolicy.options()
    #expect(options.detectLanguage)
    #expect(options.language == nil)
    #expect(options.skipSpecialTokens)
    #expect(options.task == .transcribe)
}

@Test func cleansLegacyTranscriptWithoutChangingSpeechOrSpeakerLabels() {
    let raw = "[12 c] Локальный микрофон: <|startoftranscript|><|ru|><|transcribe|><|12.24|> Привет, Антон!<|14.00|>"
    let expected = "[12 c] Локальный микрофон:  Привет, Антон!"
    #expect(TranscriptionPolicy.clean(raw) == expected)
    #expect(TranscriptionPolicy.clean(expected) == expected)
    #expect(TranscriptionPolicy.clean("Сравнение: 2 < 3; тег <example>.") == "Сравнение: 2 < 3; тег <example>.")
}

@Test func explicitRussianOverridesUnreliableLanguageDetection() {
    let options = TranscriptionPolicy.options(language: "ru")
    #expect(options.language == "ru")
    #expect(!options.detectLanguage)
    #expect(options.skipSpecialTokens)
}

@Test func sequentialCallsStayQueuedOnceAndInOrder() {
    var queue = MeetingQueue()
    let first = UUID(), second = UUID()
    queue.append(first); queue.append(second); queue.append(first)
    #expect(queue.next() == first)
    #expect(queue.next() == second)
    #expect(queue.next() == nil)
}

@Test func bilingualSelectionIgnoresSpuriousThirdLanguageAndSupportsSwitching() {
    #expect(TranscriptionPolicy.candidateLanguages("pt") == ["ru", "en"])
    #expect(TranscriptionPolicy.candidateLanguages("en") == ["en"])
}

@Test func oldMeetingsDecodeWithoutProcessingMetadata() throws {
    let json = #"{"id":"12D448BF-4E7B-41F6-BE35-64E1FA33BE39","title":"Call","folder":"Inbox","notes":"","transcript":"Привет","summary":"","date":0}"#
    let meeting = try JSONDecoder().decode(Meeting.self, from: Data(json.utf8))
    #expect(meeting.transcript == "Привет")
    #expect(meeting.job == nil)
}

@MainActor @Test func alreadyStoppedStreamStillClosesAudioWriters() async {
    struct AlreadyStopped: Error {}
    var closed = false
    let error = await CaptureFinalization.run(stop: { throw AlreadyStopped() }, close: { closed = true })
    #expect(error != nil)
    #expect(closed)
}

@MainActor @Test func closesAudioAfterSuccessfulStop() async {
    var events: [String] = []
    let error = await CaptureFinalization.run(stop: { events.append("stop") }, close: { events.append("close") })
    #expect(error == nil)
    #expect(events == ["stop", "close"])
}

import AVFoundation
@Test func microphonePCMFormatsMatchWriter() throws {
    for common in [AVAudioCommonFormat.pcmFormatInt16, .pcmFormatFloat32] {
        for interleaved in [true, false] {
            let format = try #require(AVAudioFormat(commonFormat: common, sampleRate: 48000, channels: 2, interleaved: interleaved))
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
            defer { try? FileManager.default.removeItem(at: path) }
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
            buffer.frameLength = 480
            do {
                let writer = try AVAudioFile(forWriting: path, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                #expect(writer.processingFormat == buffer.format)
                try writer.write(from: buffer)
            }
            let recorded = try AVAudioFile(forReading: path)
            #expect(recorded.length == 480)
        }
    }
}
