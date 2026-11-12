import SwiftUI

struct SummaryView: View {
    @Binding var text: String
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                if editing {
                    Button("Отмена") { editing = false }.buttonStyle(NoteButtonStyle())
                    Button("Сохранить") { text = SummaryDocument.markdown(fromReadable: draft, preservingHeadingsFrom: text); editing = false }
                        .buttonStyle(NoteButtonStyle(selected: true))
                } else {
                    Button { draft = SummaryDocument.plainText(text); editing = true } label: {
                        Label("Редактировать", systemImage: "pencil")
                    }.buttonStyle(NoteButtonStyle())
                }
            }
            if editing {
                TextEditor(text: $draft)
                    .font(.system(size: 16)).lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("Редактирование итога встречи")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(SummaryDocument.blocks(text)) { block in
                            switch block.kind {
                            case .heading:
                                Text(SummaryDocument.inline(block.text))
                                    .font(.system(size: 19, weight: .semibold))
                                    .padding(.top, block.id == 0 ? 0 : 12)
                                    .accessibilityAddTraits(.isHeader)
                            case .paragraph:
                                Text(SummaryDocument.inline(block.text))
                                    .font(.system(size: 16)).lineSpacing(5)
                            case .bullet(let depth):
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text("•").foregroundStyle(.secondary)
                                    Text(SummaryDocument.inline(block.text)).lineSpacing(5)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.font(.system(size: 16)).padding(.leading, CGFloat(depth) * 22)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 12).padding(.bottom, 20)
                        .textSelection(.enabled)
                }.accessibilityLabel("Итог встречи")
            }
        }
    }
}
