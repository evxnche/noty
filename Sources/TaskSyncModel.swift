import Foundation

/// The shared representation contains tasks, never the rest of a note's body.
struct SyncTask: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var noteId: String
    var listTitle: String
    var text: String
    var completed: Bool
    var position: Double
    var deleted: Bool = false
    var version: Int = 0

    func sameContent(as other: SyncTask) -> Bool {
        var a = self, b = other
        a.version = 0; b.version = 0
        return a == b
    }

    /// Rebase edits made locally since a snapshot onto the latest server record.
    func rebased(from old: SyncTask, onto remote: SyncTask) -> SyncTask {
        var result = remote
        if text != old.text { result.text = text }
        if completed != old.completed { result.completed = completed }
        if position != old.position { result.position = position }
        if listTitle != old.listTitle { result.listTitle = listTitle }
        if deleted != old.deleted { result.deleted = deleted }
        return result
    }
}

struct SyncChange: Codable, Equatable {
    var task: SyncTask
    var base: SyncTask?

    private enum CodingKeys: String, CodingKey { case task, base }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(task, forKey: .task)
        if let base { try container.encode(base, forKey: .base) }
        else { try container.encodeNil(forKey: .base) }
    }

    var pending: Bool { base.map { !task.sameContent(as: $0) } ?? !task.deleted }
}

struct SyncConflict: Codable {
    var id: String
    var task: SyncTask
}

struct SyncResponse: Codable {
    var tasks: [SyncTask]
    var conflicts: [SyncConflict]
}

struct TaskSyncLedger: Codable {
    var entries: [SyncChange] = []
    var changes: [SyncChange] { entries.filter(\.pending) }

    /// Text matching happens before positional matching, preserving identity when
    /// tasks are inserted or rearranged. Duplicate text is matched one-to-one.
    mutating func reconcile(notes: [Note]) {
        let active = notes.filter { !$0.archived }
        let activeIDs = Set(active.map(\.id))
        for note in active {
            let lines = Self.taskLines(note.body)
            let old = entries.indices.filter { entries[$0].task.noteId == note.id && !entries[$0].task.deleted }
            var unused = Set(old)
            var matches: [Int: Int] = [:]
            for (position, line) in lines.enumerated() {
                if let match = unused.filter({ entries[$0].task.text == line.text }).min(by: {
                    abs(entries[$0].task.position - Double(position)) < abs(entries[$1].task.position - Double(position))
                }) {
                    matches[position] = match
                    unused.remove(match)
                }
            }
            for position in lines.indices where matches[position] == nil {
                if let match = unused.first(where: { entries[$0].task.position == Double(position) }) {
                    matches[position] = match
                    unused.remove(match)
                }
            }
            let title = note.titleCustom ? Self.sharedTitle(note.displayTitle) : "Tasks"
            for (position, line) in lines.enumerated() {
                if let index = matches[position] {
                    entries[index].task.text = line.text
                    entries[index].task.completed = line.completed
                    entries[index].task.position = Double(position)
                    entries[index].task.listTitle = title
                } else {
                    entries.append(SyncChange(task: SyncTask(noteId: note.id, listTitle: title,
                        text: line.text, completed: line.completed, position: Double(position)), base: nil))
                }
            }
            for index in unused { entries[index].task.deleted = true }
        }
        for i in entries.indices where !activeIDs.contains(entries[i].task.noteId) {
            entries[i].task.deleted = true
        }
        // Retain unpublished removals: an in-flight first upload may already be
        // accepted. Its acknowledgement must become a queued deletion, not a
        // newly discovered remote task. Unsynced removals are never transmitted.
    }

    /// Acknowledgements never discard edits made while the request was in flight.
    /// Conflicting text is kept as another task instead of silently being lost.
    @discardableResult
    mutating func receive(tasks: [SyncTask], conflicts: [SyncConflict], sent: [SyncChange], notes: [Note]) -> [Note] {
        let before = entries.map(\.task)
        let conflicted = Set(conflicts.map(\.id))
        let snapshots = Dictionary(uniqueKeysWithValues: sent.map { ($0.task.id, $0.task) })
        for remote in tasks {
            if let i = entries.firstIndex(where: { $0.task.id == remote.id }) {
                let local = entries[i]
                if conflicted.contains(remote.id) {
                    if !local.task.deleted && local.task.text != remote.text {
                        var copy = local.task
                        copy.id = UUID().uuidString; copy.version = 0; copy.deleted = false
                        copy.position += 0.5
                        entries.append(SyncChange(task: copy, base: nil))
                    }
                    entries[i] = SyncChange(task: remote, base: remote)
                } else if let snapshot = snapshots[remote.id] {
                    entries[i] = SyncChange(task: local.task.rebased(from: snapshot, onto: remote), base: remote)
                } else if local.base == nil && local.task.deleted {
                    // The first POST may have succeeded before its response was
                    // lost. A later GET acknowledges it without reviving it.
                    var removed = remote
                    removed.deleted = true
                    entries[i] = SyncChange(task: removed, base: remote)
                } else if local.pending, let base = local.base {
                    // Pulls also merge remote fields alongside unsent local edits.
                    if remote.deleted && !local.task.deleted {
                        // Keep the draft live until the server reports a conflict,
                        // so it can be recovered as a new task, never resurrected.
                        continue
                    }
                    entries[i] = SyncChange(task: local.task.rebased(from: base, onto: remote), base: base)
                } else if !local.pending {
                    entries[i] = SyncChange(task: remote, base: remote)
                }
            } else {
                entries.append(SyncChange(task: remote, base: remote))
            }
        }
        return Self.applying(entries.map(\.task), replacing: before, to: notes)
    }

    private struct TaskLine {
        var line: Int
        var text: String
        var completed: Bool
    }

    private static func taskLines(_ body: String) -> [TaskLine] {
        body.components(separatedBy: "\n").enumerated().compactMap { index, line in
            guard let marker = Tasks.marker(of: line) else { return nil }
            let text = Tasks.stripped(line)
            guard !text.isEmpty else { return nil }
            return TaskLine(line: index, text: text, completed: marker == Tasks.done)
        }
    }

    private static func ordered(_ tasks: [SyncTask]) -> [SyncTask] {
        tasks.sorted { $0.position == $1.position ? $0.id < $1.id : $0.position < $1.position }
    }

    private static func sharedTitle(_ title: String) -> String {
        var result = ""
        for character in title {
            let next = String(character)
            guard result.utf16.count + next.utf16.count <= 120 else { break }
            result.append(character)
        }
        return result.isEmpty ? "Tasks" : result
    }

    private static func applying(_ tasks: [SyncTask], replacing old: [SyncTask], to notes: [Note]) -> [Note] {
        var result = notes
        let byNote = Dictionary(grouping: tasks.filter { !$0.deleted }, by: \.noteId)
        for i in result.indices where !result[i].archived {
            let noteID = result[i].id
            let previous = ordered(old.filter { $0.noteId == noteID && !$0.deleted })
            let desired = ordered(byNote[noteID] ?? [])
            let original = result[i].body.components(separatedBy: "\n")
            let parsed = taskLines(result[i].body)
            var replacements: [Int: String] = [:]
            var removals = Set<Int>()
            for (ordinal, line) in parsed.enumerated() {
                guard ordinal < desired.count else { removals.insert(line.line); continue }
                let task = desired[ordinal]
                if task.text != line.text || task.completed != line.completed {
                    replacements[line.line] = (task.completed ? Tasks.donePrefix : Tasks.openPrefix) + task.text
                }
            }
            var body = original.enumerated().compactMap { index, line -> String? in
                removals.contains(index) ? nil : (replacements[index] ?? line)
            }.joined(separator: "\n")
            for task in desired.dropFirst(parsed.count) {
                if !body.isEmpty && !body.hasSuffix("\n") { body += "\n" }
                body += (task.completed ? Tasks.donePrefix : Tasks.openPrefix) + task.text
            }
            if body != result[i].body {
                result[i].applyBody(body)
                result[i].modified = Date()
            }
            if let titleTask = desired.max(by: { $0.version < $1.version }),
               titleTask.listTitle != previous.first?.listTitle,
               (result[i].titleCustom || titleTask.listTitle != "Tasks") {
                result[i].applyTypedTitle(titleTask.listTitle)
                result[i].modified = Date()
            }
        }
        let known = Set(result.map(\.id))
        for (noteID, list) in byNote.sorted(by: { $0.key < $1.key }) where !known.contains(noteID) {
            let orderedList = ordered(list)
            var note = Note()
            note.id = noteID
            note.body = orderedList.map { ($0.completed ? Tasks.donePrefix : Tasks.openPrefix) + $0.text }.joined(separator: "\n")
            note.applyTypedTitle(orderedList.first?.listTitle ?? "Tasks")
            note.order = (result.map(\.order).min() ?? 0) - 1
            result.append(note)
        }
        return result
    }
}
