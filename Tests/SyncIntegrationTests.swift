import AppKit

/// Runs the actual native sync engine against a disposable HTTP server.
@main enum SyncIntegrationTests {
    static func main() throws {
        guard ProcessInfo.processInfo.environment["NOTY_SUPPORT_DIR"] != nil else {
            fatalError("Use an isolated NOTY_SUPPORT_DIR for this test.")
        }
        let endpoint = ProcessInfo.processInfo.environment["NOTY_TEST_ENDPOINT"] ?? "http://127.0.0.1:8787"
        let token = ProcessInfo.processInfo.environment["NOTY_SYNC_TOKEN"] ?? "noty-local-verification-key-20261004"
        let store = NoteStore.shared
        let sync = TaskSync.shared
        sync.start()
        guard sync.configure(TaskSyncConfiguration(endpoint: endpoint, token: token, enabled: true)) == nil else {
            fatalError("Sync configuration failed")
        }
        let note = store.create(body: "Private integration prose\n☐ Native integration task\n![Photo](photo-private.png)")
        wait("native upload") { sync.status == "Up to date" && sync.pendingCount == 0 }
        let initial = try call(endpoint, token: token)
        guard let task = initial.tasks.first(where: { $0.noteId == note.id }),
              task.text == "Native integration task", !task.completed,
              !initial.tasks.contains(where: { $0.text.contains("Private integration") || $0.text.contains("photo-private") }) else {
            fatalError("Native task upload or privacy failed")
        }
        print("✓ legacy task projection includes only checkbox text")
        var completed = task; completed.completed = true
        _ = try call(endpoint, token: token, changes: [SyncChange(task: completed, base: task)])
        sync.syncNow()
        wait("remote completion") { store.note(id: note.id)?.body.contains("☑ Native integration task") == true }
        guard store.note(id: note.id)?.body.contains("Private integration prose") == true,
              store.note(id: note.id)?.body.contains("![Photo](photo-private.png)") == true else {
            fatalError("Remote completion changed private note text")
        }
        print("✓ phone completion reached native note without changing prose or photos")
        var phone = SyncTask(noteId: UUID().uuidString, listTitle: "Phone integration", text: "Added from phone", completed: false, position: 0)
        phone.id = UUID().uuidString
        // The mobile Notes client publishes its full note before legacy task edits.
        var phoneNote = Note(); phoneNote.id = phone.noteId; phoneNote.applyTypedTitle(phone.listTitle)
        try publishNote(endpoint, token: token, note: SyncNote(phoneNote))
        _ = try call(endpoint, token: token, changes: [SyncChange(task: phone, base: nil)])
        sync.syncNow()
        wait("remote create") { store.note(id: phone.noteId)?.body.trimmingCharacters(in: .whitespacesAndNewlines) == "☐ Added from phone" }
        print("✓ phone-created task arrived in a new native list")
        store.delete(id: note.id)
        wait("native deletion") { sync.status == "Up to date" && sync.pendingCount == 0 }
        let deleted = try call(endpoint, token: token)
        guard deleted.tasks.first(where: { $0.id == task.id })?.deleted == true else { fatalError("Deletion was not synced") }
        print("✓ native deletion persisted a cloud tombstone")
        store.delete(id: phone.noteId)
        wait("remove phone test fixture") { sync.status == "Up to date" && sync.pendingCount == 0 }
        let cleaned = try call(endpoint, token: token)
        guard cleaned.tasks.first(where: { $0.id == phone.id })?.deleted == true else { fatalError("Phone fixture was not removed") }
        sync.stop()
        print("native HTTP integration all green")
    }

    private static func wait(_ label: String, until ready: () -> Bool) {
        let deadline = Date().addingTimeInterval(15)
        while !ready() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if !ready() { fatalError("Timed out: \(label); status=\(TaskSync.shared.status)") }
    }

    private static func call(_ endpoint: String, token: String, changes: [SyncChange]? = nil) throws -> SyncResponse {
        var request = URLRequest(url: URL(string: endpoint)!.appendingPathComponent("api/sync"))
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let changes {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["changes": changes])
        }
        var result: Result<SyncResponse, Error>?
        URLSession.shared.dataTask(with: request) { data, response, error in
            let decoded: Result<SyncResponse, Error>
            if let error { decoded = .failure(error) }
            else if (response as? HTTPURLResponse)?.statusCode == 200, let data {
                decoded = Result { try JSONDecoder().decode(SyncResponse.self, from: data) }
            } else { decoded = .failure(CocoaError(.fileReadUnknown)) }
            DispatchQueue.main.async { result = decoded }
        }.resume()
        let deadline = Date().addingTimeInterval(15)
        while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard let result else { throw URLError(.timedOut) }
        return try result.get()
    }

    private static func publishNote(_ endpoint: String, token: String, note: SyncNote) throws {
        var request = URLRequest(url: URL(string: endpoint)!.appendingPathComponent("api/notes"))
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(NoteSyncRequest(changes: [SyncNoteChange(note: note, base: nil)]))
        var status: Int?
        URLSession.shared.dataTask(with: request) { _, response, _ in
            DispatchQueue.main.async { status = (response as? HTTPURLResponse)?.statusCode ?? 0 }
        }.resume()
        let deadline = Date().addingTimeInterval(15)
        while status == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard status == 200 else { throw URLError(.badServerResponse) }
    }
}
