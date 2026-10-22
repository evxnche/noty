import AppKit
import SQLite3

@main enum NoteSyncTests {
    static func main() throws {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("\(condition ? "✓" : "✗") \(name)")
            if !condition { failures += 1 }
        }
        var original = Note()
        original.applyTypedTitle("Desk Pal")
        original.body = "# to-do\n☑ Keep completed\n☐ Keep open\n\n# idea\n- An existing project\n\n# building\n\n# testing\n\n# shipped"
        var other = Note(); other.applyTypedTitle("work"); other.body = "Private work context\n☐ Keep my task"
        var ledger = NoteSyncLedger()
        ledger.reconcile(notes: [original, other])
        check("all note text is published without changing local notes", ledger.entries.count == 2 && ledger.entries.first?.note.body == original.body)
        check("new note encodes an explicit null base", String(decoding: try JSONEncoder().encode(ledger.changes[0]), as: UTF8.self).contains("\"base\":null"))
        let sent = ledger.changes
        let accepted = sent.map { change -> SyncNote in var n = change.note; n.version = 1; return n }
        let result = ledger.receive(notes: accepted, conflicts: [], sent: sent, local: [original, other])
        check("acknowledgement leaves original note fields unchanged", result == [original, other] && ledger.changes.isEmpty)
        var remote = accepted[0]; remote.body += "\n- Phone project"; remote.version = 2
        let updated = ledger.receive(notes: [remote, accepted[1]], conflicts: [], sent: [], local: result)
        check("phone text reaches its native note", updated[0].body == remote.body)
        check("phone edit leaves other notes byte-for-byte in model unchanged", updated[1] == other)

        original.body += "\n- Local project"
        var inflight = NoteSyncLedger(); inflight.reconcile(notes: [original])
        let upload = inflight.changes
        original.body += "\n- Typed during upload"
        inflight.reconcile(notes: [original])
        let received = upload.map { var n = $0.note; n.version = 1; return n }
        _ = inflight.receive(notes: received, conflicts: [], sent: upload, local: [original])
        check("in-flight draft remains pending against acknowledged base", inflight.changes.first?.note.body == original.body && inflight.changes.first?.base?.version == 1)
        var concurrent = NoteSyncLedger()
        var baseNote = Note(); baseNote.applyTypedTitle("Concurrent"); baseNote.body = "A"
        concurrent.reconcile(notes: [baseNote])
        let concurrentSent = concurrent.changes
        baseNote.body = "A\nC"; concurrent.reconcile(notes: [baseNote])
        var combined = concurrentSent[0].note; combined.body = "A\nB"; combined.version = 1
        let merged = concurrent.receive(notes: [combined], conflicts: [], sent: concurrentSent, local: [baseNote])
        check("remote body text is retained alongside typing during upload", merged[0].body.contains("B") && merged[0].body.contains("C"))
        check("later upload does not delete the merged remote text", concurrent.changes.first?.note.body.contains("B") == true)

        var typing = NoteSyncLedger()
        var typed = Note(); typed.applyTypedTitle("Desk Pal"); typed.body = "- idea"
        typing.reconcile(notes: [typed])
        let firstSend = typing.changes
        let firstSaved = firstSend.map { var n = $0.note; n.version = 1; return n }
        typing.acknowledge(notes: firstSaved, conflicts: [], sent: firstSend)
        typed.body = "- idea + more"; typing.reconcile(notes: [typed])
        check("reply during typing advances the base so the next upload is not a conflict",
              typing.changes.first?.base?.version == 1 && typing.changes.first?.note.body == typed.body)

        var repick = NoteSyncLedger(); repick.deskPalId = UUID().uuidString
        repick.reconcile(notes: [typed])
        check("deleted Desk Pal note is replaced by the live note of that title", repick.deskPalId == typed.id)

        var gone = NoteSyncLedger(); gone.reconcile(notes: [other])
        let first = gone.changes
        gone.reconcile(notes: [])
        let firstAccepted = first.map { var n = $0.note; n.version = 1; return n }
        let goneResult = gone.receive(notes: firstAccepted, conflicts: [], sent: [], local: [])
        check("lost initial acknowledgement never revives a locally deleted note", goneResult.isEmpty && gone.changes.first?.note.deleted == true)

        var conflict = NoteSyncLedger(); conflict.reconcile(notes: [other])
        let initial = conflict.changes
        let saved = initial.map { var n = $0.note; n.version = 1; return n }
        _ = conflict.receive(notes: saved, conflicts: [], sent: initial, local: [other])
        other.body = "Local conflicting text"; conflict.reconcile(notes: [other])
        let conflictsSent = conflict.changes
        var phone = saved[0]; phone.body = "Phone conflicting text"; phone.version = 2
        let both = conflict.receive(notes: [phone], conflicts: [SyncNoteConflict(id: phone.id, note: phone)], sent: conflictsSent, local: [other])
        check("conflicting full-note text keeps both versions", both.count == 2 && both.contains { $0.body == "Local conflicting text" } && both.contains { $0.body == "Phone conflicting text" })

        let roundTrip = try JSONDecoder().decode(NoteSyncLedger.self, from: JSONEncoder().encode(inflight))
        check("offline desired body and server base survive reload", roundTrip.changes == inflight.changes)
        let isolated = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: isolated) }
        let dbURL = isolated.appendingPathComponent("notes.db")
        let store = Store(url: dbURL)
        var retained = Note(); retained.applyTypedTitle("Retained"); retained.body = "Keep this body"
        check("isolated original note saved", store.upsert(retained))
        var connection: OpaquePointer?
        sqlite3_open(dbURL.path, &connection)
        sqlite3_exec(connection, "CREATE TRIGGER fail_sync BEFORE INSERT ON notes WHEN NEW.title = 'FAIL' BEGIN SELECT RAISE(ABORT, 'injected disk failure'); END;", nil, nil, nil)
        var modified = retained; modified.body = "Must roll back"
        var failing = Note(); failing.applyTypedTitle("FAIL"); failing.body = "Rejected remote note"
        check("SQLite failure rejects the received batch", !store.applySync([modified, failing], replacing: [retained]))
        let preserved = store.load()
        check("failed batch retains original note and does not publish a partial insert", preserved.count == 1 && preserved[0].body == retained.body)
        sqlite3_exec(connection, "DROP TRIGGER fail_sync;", nil, nil, nil)
        sqlite3_close(connection)
        check("successful batch persists all received notes", store.applySync([modified, failing], replacing: [retained]) && store.load().count == 2)
        if failures > 0 { exit(1) }
        print("full-note sync all green")
    }
}
