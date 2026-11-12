import SwiftUI

struct TranscriptChat: View {
    let transcript: String
    let attributions: [SpeakerAttribution]

    var body: some View {
        let turns = Conversation.turns(transcript)
        let names = Dictionary(uniqueKeysWithValues: Conversation.validated(attributions, transcript: transcript).map { ($0.turnID, $0.name) })
        if turns.isEmpty {
            ContentUnavailableView("Транскрипт пока не готов", systemImage: "text.bubble", description: Text("Реплики появятся после распознавания аудио."))
        } else {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(turns) { turn in
                        HStack(alignment: .top, spacing: 0) {
                            if turn.side == .local { Spacer(minLength: 70) }
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 10) {
                                    Text(turn.side == .local ? "Вы" : turn.side == .remote ? names[turn.id] ?? "Собеседник" : "Транскрипт").fontWeight(.medium)
                                    if !turn.timestamp.isEmpty { Text(turn.timestamp).foregroundStyle(.secondary) }
                                }.font(.caption)
                                Text(turn.text).font(.system(size: 16)).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                            }.textSelection(.enabled).padding(.horizontal, 16).padding(.vertical, 12)
                                .background(turn.side == .local ? NotePalette.surface : NotePalette.selection, in: RoundedRectangle(cornerRadius: 16))
                            if turn.side != .local { Spacer(minLength: 70) }
                        }.frame(maxWidth: .infinity)
                    }
                }.padding(.vertical, 8)
            }
        }
    }
}
