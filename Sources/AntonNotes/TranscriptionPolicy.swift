import Foundation
import WhisperKit

enum TranscriptionPolicy {
    static func candidateLanguages(_ detected: String) -> [String] {
        ["ru", "en"].contains(detected) ? [detected] : ["ru", "en"]
    }
    static func options(language: String = "auto") -> DecodingOptions {
        DecodingOptions(language: language == "auto" ? nil : language, detectLanguage: language == "auto", skipSpecialTokens: true)
    }

    // Strip only Whisper control tokens; retain speech, punctuation and speaker timestamps.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^<>\r\n]*\|>"#, with: "", options: .regularExpression)
    }
}
