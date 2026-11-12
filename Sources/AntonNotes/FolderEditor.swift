import SwiftUI

struct FolderDraft: Identifiable {
    let id = UUID()
    var original: String?
}

struct FolderEditor: View {
    let original: String?
    let save: (String) -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    init(original: String?, save: @escaping (String) -> String?) {
        self.original = original
        self.save = save
        _name = State(initialValue: original ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(original == nil ? "Создать папку" : "Переименовать папку").font(.system(size: 22, weight: .semibold))
            VStack(alignment: .leading, spacing: 8) {
                Text("Название папки")
                TextField("Например, Работа", text: $name)
                    .textFieldStyle(.roundedBorder).controlSize(.large)
                    .accessibilityIdentifier("folder-name").accessibilityLabel("Название папки")
                    .focused($nameFocused)
                    .onSubmit { submit() }
                if let error { Text(error).font(.callout).foregroundStyle(.red).accessibilityIdentifier("folder-error") }
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(NoteButtonStyle()).keyboardShortcut(.cancelAction)
                Button(original == nil ? "Создать" : "Сохранить") { submit() }.buttonStyle(NoteButtonStyle(selected: true)).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28).frame(width: 420)
        .task { nameFocused = true }
    }

    private func submit() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        error = save(name)
        if error == nil { dismiss() }
        else { nameFocused = true }
    }
}
