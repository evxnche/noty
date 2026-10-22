import Foundation

/// A one-time, additive migration. Other native notes are never edited.
@main enum PrepareDeskPal {
    static func main() throws {
        guard CommandLine.arguments.count >= 3 else { fatalError("Supply plan snapshot path and preview output path; add --apply to save.") }
        let source = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let projects = source["projects"] as? [[String: Any]] ?? []
        let savedTasks = source["tasks"] as? [[String: Any]] ?? []
        let selectedID = savedTasks.first { ($0["listTitle"] as? String)?.lowercased() == "desk pal" }?["noteId"] as? String
        let store = NoteStore.shared
        guard let note = selectedID.flatMap({ store.note(id: $0) }) ?? store.notes.first(where: { $0.displayTitle.lowercased() == "desk pal" }) else {
            fatalError("Desk Pal note was not found; no notes changed.")
        }
        let stages = ["to-do", "idea", "building", "testing", "shipped"]
        func heading(_ line: String) -> String? {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("# ") else { return nil }
            let label = String(value.dropFirst(2)).trimmingCharacters(in: .whitespaces).lowercased()
            if ["to-do", "todo", "to do"].contains(label) { return "to-do" }
            if label == "shift" { return "shipped" }
            return stages.contains(label) ? label : nil
        }
        func item(_ raw: String) -> String {
            var value = Tasks.stripped(raw).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("- ") || value.hasPrefix("* ") { value = String(value.dropFirst(2)) }
            return value
        }
        var body = note.body
        var lines = body.components(separatedBy: "\n")
        if !lines.contains(where: { heading($0) == "to-do" }) {
            body = "# to-do\n" + body
            lines = body.components(separatedBy: "\n")
        }
        for stage in stages where !lines.contains(where: { heading($0) == stage }) {
            if !body.hasSuffix("\n") { body += "\n" }
            body += "\n# " + stage + "\n"
            lines = body.components(separatedBy: "\n")
        }
        var already = Set<String>(), active: String?
        for line in lines {
            if let stage = heading(line) { active = stage; continue }
            if let active, active != "to-do", !line.trimmingCharacters(in: .whitespaces).isEmpty {
                already.insert(item(line).lowercased())
            }
        }
        for stage in stages.dropFirst() {
            let names = projects.compactMap { project -> String? in
                guard project["s"] as? String == stage, let name = project["n"] as? String,
                      !already.contains(name.lowercased()) else { return nil }
                already.insert(name.lowercased()); return name
            }
            guard !names.isEmpty, let start = lines.firstIndex(where: { heading($0) == stage }) else { continue }
            let end = lines.indices.first(where: { $0 > start && heading(lines[$0]) != nil }) ?? lines.count
            var insertion = end
            while insertion > start + 1 && lines[insertion - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertion -= 1 }
            lines.insert(contentsOf: names.map { "- " + $0 }, at: insertion)
        }
        let prepared = lines.joined(separator: "\n")
        let preview: [String: Any] = ["id": note.id, "title": note.displayTitle, "before": note.body, "after": prepared, "projects": projects.count]
        try JSONSerialization.data(withJSONObject: preview, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: CommandLine.arguments[2])
        if CommandLine.arguments.contains("--apply") {
            var updated = note; updated.applyBody(prepared); updated.modified = Date()
            let incoming = store.notes.map { $0.id == note.id ? updated : $0 }
            guard store.applySynced(incoming) else { fatalError("The database could not commit the migration. Original notes retained.") }
            TaskSync.shared.start()
            let deadline = Date().addingTimeInterval(30)
            while TaskSync.shared.status != "Up to date" && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            print("Desk Pal sections saved. Sync status: \(TaskSync.shared.status)")
            TaskSync.shared.stop()
        } else {
            print("Prepared five sections and \(projects.count) project entries; native notes were not changed.")
        }
    }
}
