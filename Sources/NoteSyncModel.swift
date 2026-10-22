import Foundation

struct SyncNote: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var body: String
    var archived: Bool
    var deleted: Bool = false
    var version: Int = 0
    var taskIds: [String] = []

    init(_ note: Note) {
        id = note.id; title = note.displayTitle; body = note.body; archived = note.archived
    }

    func sameContent(as other: SyncNote) -> Bool {
        id == other.id && title == other.title && body == other.body && archived == other.archived && deleted == other.deleted
    }

    func rebased(from old: SyncNote, onto remote: SyncNote) -> SyncNote {
        var result = remote
        if title != old.title { result.title = title }
        if body != old.body { result.body = body }
        if archived != old.archived { result.archived = archived }
        if deleted != old.deleted { result.deleted = deleted }
        return result
    }

    var valid: Bool {
        UUID(uuidString: id) != nil &&
        title.utf16.count <= 120 && body.utf16.count <= 65_536 && version >= 0 &&
        taskIds.allSatisfy { UUID(uuidString: $0) != nil } && Set(taskIds.map { $0.lowercased() }).count == taskIds.count
    }
}

struct SyncNoteChange: Codable, Equatable {
    var note: SyncNote
    var base: SyncNote?
    var pending: Bool { base.map { !note.sameContent(as: $0) } ?? !note.deleted }
    private enum CodingKeys: String, CodingKey { case note, base }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(note, forKey: .note)
        if let base { try c.encode(base, forKey: .base) } else { try c.encodeNil(forKey: .base) }
    }
}

struct SyncNoteConflict: Codable {
    var id: String
    var note: SyncNote
}

struct NoteSyncResponse: Codable {
    var notes: [SyncNote]
    var conflicts: [SyncNoteConflict]
    var deskPalId: String?

    var valid: Bool {
        notes.allSatisfy(\.valid) && Set(notes.map { $0.id.lowercased() }).count == notes.count &&
        (deskPalId == nil || UUID(uuidString: deskPalId!) != nil) &&
        conflicts.allSatisfy { conflict in
            conflict.note.valid && conflict.id == conflict.note.id && notes.contains { $0 == conflict.note }
        }
    }
}

/// Full note documents are authoritative. The server maintains task-line IDs.
struct NoteSyncLedger: Codable {
    var entries: [SyncNoteChange] = []
    var deskPalId: String?
    var recoveryBefore: [SyncNote]?
    var recoveryAfter: [SyncNote]?
    var preservedConflicts: Int?
    var changes: [SyncNoteChange] { entries.filter(\.pending) }

    mutating func reconcile(notes: [Note]) {
        let present = Set(notes.map(\.id))
        for note in notes {
            if let i = entries.firstIndex(where: { $0.note.id == note.id }) {
                var desired = SyncNote(note)
                desired.version = entries[i].note.version
                desired.taskIds = entries[i].note.taskIds
                entries[i].note = desired
            } else {
                entries.append(SyncNoteChange(note: SyncNote(note), base: nil))
            }
        }
        for i in entries.indices where !present.contains(entries[i].note.id) { entries[i].note.deleted = true }
        // Re-pick when the remembered Desk Pal note was deleted or archived.
        if deskPalId == nil || !notes.contains(where: { !$0.archived && $0.id.caseInsensitiveCompare(deskPalId!) == .orderedSame }) {
            deskPalId = notes.first { !$0.archived && $0.displayTitle.caseInsensitiveCompare("Desk Pal") == .orderedSame }?.id
        }
    }

    /// Limit encoded bytes, including server bases, rather than assuming size.
    func batch() throws -> [SyncNoteChange] {
        var selected: [SyncNoteChange] = []
        for change in changes.prefix(100) {
            let candidate = selected + [change]
            let data = try JSONEncoder().encode(NoteSyncRequest(changes: candidate, deskPalId: deskPalId))
            if data.count > 950_000 {
                if selected.isEmpty { throw CocoaError(.fileWriteOutOfSpace) }
                break
            }
            selected = candidate
        }
        return selected
    }

    @discardableResult
    mutating func receive(notes remoteNotes: [SyncNote], conflicts: [SyncNoteConflict], sent: [SyncNoteChange], local: [Note]) -> [Note] {
        let snapshots = Dictionary(uniqueKeysWithValues: sent.map { ($0.note.id, $0.note) })
        let conflicted = Set(conflicts.map(\.id))
        for remote in remoteNotes {
            if let i = entries.firstIndex(where: { $0.note.id == remote.id }) {
                let existing = entries[i]
                if conflicted.contains(remote.id) {
                    if !existing.note.deleted && !existing.note.sameContent(as: remote) {
                        var copy = existing.note
                        copy.id = UUID().uuidString; copy.version = 0; copy.taskIds = []; copy.deleted = false
                        copy.title = Self.copyTitle(copy.title)
                        entries.append(SyncNoteChange(note: copy, base: nil))
                    }
                    entries[i] = SyncNoteChange(note: remote, base: remote)
                } else if let snapshot = snapshots[remote.id] {
                    var desired = existing.note.rebased(from: snapshot, onto: remote)
                    if let merged = Self.mergeBody(base: snapshot.body, local: existing.note.body, remote: remote.body) {
                        desired.body = merged
                        entries[i] = SyncNoteChange(note: desired, base: remote)
                    } else {
                        var copy = existing.note
                        copy.id = UUID().uuidString; copy.version = 0; copy.taskIds = []
                        copy.title = Self.copyTitle(copy.title)
                        entries.append(SyncNoteChange(note: copy, base: nil))
                        entries[i] = SyncNoteChange(note: remote, base: remote)
                        preservedConflicts = (preservedConflicts ?? 0) + 1
                    }
                } else if existing.base == nil && existing.note.deleted {
                    var removed = remote; removed.deleted = true
                    entries[i] = SyncNoteChange(note: removed, base: remote)
                } else if existing.pending, let base = existing.base {
                    if remote.deleted && !existing.note.deleted { continue }
                    entries[i] = SyncNoteChange(note: existing.note.rebased(from: base, onto: remote), base: base)
                } else if !existing.pending {
                    entries[i] = SyncNoteChange(note: remote, base: remote)
                }
            } else {
                entries.append(SyncNoteChange(note: remote, base: remote))
            }
        }
        return Self.applying(entries.map(\.note), to: local)
    }

    /// Record the server's acceptance of a sent note while an editor draft is open, leaving
    /// local notes untouched. Without it the next upload claims a stale base and the
    /// server reports the note's own earlier text as a conflict.
    mutating func acknowledge(notes remoteNotes: [SyncNote], conflicts: [SyncNoteConflict], sent: [SyncNoteChange]) {
        let conflicted = Set(conflicts.map(\.id))
        for change in sent where !conflicted.contains(change.note.id) {
            guard let remote = remoteNotes.first(where: { $0.id == change.note.id }), remote.sameContent(as: change.note),
                  let i = entries.firstIndex(where: { $0.note.id == remote.id }) else { continue }
            entries[i].base = remote
            entries[i].note.version = remote.version
            entries[i].note.taskIds = remote.taskIds
        }
    }

    static func applying(_ documents: [SyncNote], to local: [Note]) -> [Note] {
        var result = local
        for document in documents {
            if let i = result.firstIndex(where: { $0.id == document.id }) {
                if document.deleted { result.remove(at: i); continue }
                let before = result[i]
                if result[i].body != document.body { result[i].applyBody(document.body) }
                if result[i].displayTitle != document.title { result[i].applyTypedTitle(document.title) }
                result[i].archived = document.archived
                if result[i] != before { result[i].modified = Date() }
            } else if !document.deleted {
                var note = Note()
                note.id = document.id; note.applyBody(document.body); note.applyTypedTitle(document.title)
                note.archived = document.archived
                note.order = (result.map(\.order).min() ?? 0) - 1
                result.append(note)
            }
        }
        return result
    }

    static func matches(_ documents: [SyncNote], local: [Note]) -> Bool {
        guard documents.count == local.count else { return false }
        let byID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        return local.allSatisfy { note in byID[note.id]?.sameContent(as: SyncNote(note)) == true }
    }

    private static func copyTitle(_ title: String) -> String {
        var prefix = ""
        for character in title {
            guard prefix.utf16.count + String(character).utf16.count <= 107 else { break }
            prefix.append(character)
        }
        return prefix + " (local copy)"
    }

    /// Preserve independent in-flight edits; overlapping edits keep a copy.
    static func mergeBody(base: String, local: String, remote: String) -> String? {
        if local == base { return remote }
        if remote == base || local == remote { return local }
        let original = base.components(separatedBy: "\n")
        func change(_ value: String) -> (start: Int, end: Int, lines: [String]) {
            let target = value.components(separatedBy: "\n")
            var prefix = 0, suffix = 0
            while prefix < min(original.count, target.count), original[prefix] == target[prefix] { prefix += 1 }
            while suffix < min(original.count - prefix, target.count - prefix),
                  original[original.count - suffix - 1] == target[target.count - suffix - 1] { suffix += 1 }
            return (prefix, original.count - suffix, Array(target[prefix..<(target.count - suffix)]))
        }
        let mine = change(local), theirs = change(remote)
        if mine.start == mine.end && theirs.start == theirs.end && mine.start == theirs.start {
            return (Array(original[..<mine.start]) + theirs.lines + mine.lines + Array(original[mine.end...])).joined(separator: "\n")
        }
        let first = mine.start < theirs.start ? mine : theirs
        let second = mine.start < theirs.start ? theirs : mine
        guard first.end <= second.start else { return nil }
        return (Array(original[..<first.start]) + first.lines + Array(original[first.end..<second.start]) +
                second.lines + Array(original[second.end...])).joined(separator: "\n")
    }
}

struct NoteSyncRequest: Encodable {
    var changes: [SyncNoteChange]
    var deskPalId: String?
}
