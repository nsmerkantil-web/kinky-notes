import Foundation

// A folder is a persistent named container. Inbox is permanent; each meeting belongs to one folder.
struct NoteLibrary: Codable {
    static let inbox = "Входящие"
    var meetings: [Meeting]
    private(set) var folders: [String]

    init(meetings: [Meeting], folders: [String] = []) {
        self.meetings = meetings
        self.folders = Array(Set(folders + meetings.map(\.folder) + [Self.inbox])).sorted()
    }

    enum Invalid: String, LocalizedError {
        case name = "Введите название папки (до 80 символов)."
        case duplicate = "Папка с таким названием уже существует."
        case missing = "Папка или запись больше не существует."
        case inbox = "Папку «Входящие» нельзя переименовать или удалить."
        var errorDescription: String? { rawValue }
    }

    private func validName(_ input: String, replacing: String? = nil) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, name.rangeOfCharacter(from: .controlCharacters) == nil else { throw Invalid.name }
        guard !folders.contains(where: { $0 != replacing && $0.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { throw Invalid.duplicate }
        return name
    }
    mutating func createFolder(_ input: String) throws {
        folders.append(try validName(input))
        folders.sort()
    }
    mutating func renameFolder(_ old: String, to input: String) throws {
        guard old != Self.inbox else { throw Invalid.inbox }
        guard let index = folders.firstIndex(of: old) else { throw Invalid.missing }
        let name = try validName(input, replacing: old)
        folders[index] = name
        for i in meetings.indices where meetings[i].folder == old { meetings[i].folder = name }
        folders.sort()
    }
    mutating func deleteFolder(_ name: String) throws {
        guard name != Self.inbox else { throw Invalid.inbox }
        guard folders.contains(name) else { throw Invalid.missing }
        for i in meetings.indices where meetings[i].folder == name { meetings[i].folder = Self.inbox }
        folders.removeAll { $0 == name }
    }
    mutating func move(_ id: UUID, to folder: String) throws {
        guard folders.contains(folder), let i = meetings.firstIndex(where: { $0.id == id }) else { throw Invalid.missing }
        meetings[i].folder = folder
    }
    mutating func deleteMeeting(_ id: UUID) { meetings.removeAll { $0.id == id } }

    static func read(from root: URL) throws -> Self {
        let file = root.appendingPathComponent("library.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let saved = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
            return Self(meetings: saved.meetings, folders: saved.folders)
        }
        let legacy = root.appendingPathComponent("meetings.json")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return Self(meetings: []) }
        return Self(meetings: try JSONDecoder().decode([Meeting].self, from: Data(contentsOf: legacy)))
    }
    func write(to root: URL) throws {
        try JSONEncoder().encode(self).write(to: root.appendingPathComponent("library.json"), options: .atomic)
    }
}
