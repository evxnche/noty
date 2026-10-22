import Foundation
import Combine

struct TaskSyncConfiguration: Codable {
    var endpoint: String = ""
    var token: String = ""
    var enabled: Bool = false

    var serviceURL: URL? {
        guard let url = URL(string: endpoint), let host = url.host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)),
              url.path.isEmpty || url.path == "/" else { return nil }
        return url
    }

    var ready: Bool { serviceURL != nil && token.count >= 32 && !token.contains(where: \.isWhitespace) }

    var pairingURL: URL? {
        guard ready, let url = serviceURL, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        parts.percentEncodedFragment = "token=" + token.addingPercentEncoding(withAllowedCharacters: unreserved)!
        return parts.url
    }
}

/// All model mutations happen on the main thread; network work uses URLSession.
final class TaskSync: ObservableObject {
    static let shared = TaskSync()
    @Published private(set) var status = "Sync is off"
    @Published private(set) var configuration = TaskSyncConfiguration()
    @Published private(set) var pendingCount = 0

    private var ledger = NoteSyncLedger()
    private var timer: Timer?
    private var debounce: DispatchWorkItem?
    private var request: URLSessionDataTask?
    private var drafts = Set<String>()
    private var generation = UUID()
    private var started = false
    private var storageError: String?
    private var ledgerURL: URL { Paths.support.appendingPathComponent("note-sync-state.enc") }
    private var configurationURL: URL { Paths.support.appendingPathComponent("task-sync-config.enc") }

    private init() {
        do {
            if FileManager.default.fileExists(atPath: configurationURL.path) {
                configuration = try read(TaskSyncConfiguration.self, from: configurationURL)
            }
            if FileManager.default.fileExists(atPath: ledgerURL.path) {
                ledger = try read(NoteSyncLedger.self, from: ledgerURL)
            }
        } catch {
            storageError = "Sync state could not be read. Your local notes are safe; reconnect after restoring the sync files."
            status = storageError!
        }
    }

    func start() {
        guard !started else { return }
        started = true
        if let before = ledger.recoveryBefore, let after = ledger.recoveryAfter {
            let current = NoteStore.shared.notes
            if NoteSyncLedger.matches(before, local: current) {
                guard NoteStore.shared.applySynced(NoteSyncLedger.applying(after, to: current).filter { n in after.contains { $0.id == n.id } }) else {
                    storageError = "Note storage could not commit recovered sync data. The recovery journal is retained."
                    status = storageError!; return
                }
            } else if !NoteSyncLedger.matches(after, local: current) {
                storageError = "Notes changed during interrupted sync. Current notes are preserved; sync needs recovery."
                status = storageError!
                return
            }
            ledger.recoveryBefore = nil; ledger.recoveryAfter = nil
            guard persist() else { return }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.syncNow()
        }
        localChanged()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        debounce?.cancel(); request?.cancel(); request = nil
    }

    func beginDraft(noteID: String) { drafts.insert(noteID) }
    func endDraft(noteID: String) { drafts.remove(noteID); localChanged() }

    @discardableResult
    func configure(_ new: TaskSyncConfiguration) -> String? {
        if let storageError { return storageError }
        if new.enabled && !new.ready { return "Enter an HTTPS site address and a private key of at least 32 characters." }
        let previous = configuration
        // Prevent one workspace's pending writes reaching another workspace.
        if previous.ready && (previous.endpoint != new.endpoint || previous.token != new.token),
           !ledger.changes.isEmpty {
            return "Sync your pending changes before switching to another task list."
        }
        do { try write(new, to: configurationURL) }
        catch { return "Could not save sync settings: \(error.localizedDescription)" }
        generation = UUID(); request?.cancel(); request = nil
        configuration = new
        if previous.ready && (previous.endpoint != new.endpoint || previous.token != new.token) {
            ledger = NoteSyncLedger()
        }
        localChanged()
        return nil
    }

    func localChanged() {
        guard started, storageError == nil else { return }
        ledger.reconcile(notes: NoteStore.shared.notes)
        pendingCount = ledger.changes.count
        guard persist() else { return }
        guard configuration.enabled && configuration.ready else { status = "Sync is off"; return }
        if pendingCount > 0 { status = "\(pendingCount) change\(pendingCount == 1 ? "" : "s") waiting to sync" }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncNow() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    func syncNow() {
        guard started, configuration.enabled, configuration.ready, storageError == nil,
              request == nil, drafts.isEmpty, let endpoint = configuration.serviceURL else { return }
        ledger.reconcile(notes: NoteStore.shared.notes)
        let sent: [SyncNoteChange]
        do { sent = try ledger.batch() }
        catch { status = "A note is too large for one sync request. Local notes remain saved."; return }
        guard sent.allSatisfy({ $0.note.valid }) else {
            status = "A note exceeds the sync service’s limits. Local notes remain saved."
            return
        }
        guard persist() else { return }
        var outgoing = URLRequest(url: endpoint.appendingPathComponent("api/notes"))
        outgoing.httpMethod = sent.isEmpty ? "GET" : "POST"
        outgoing.setValue("Bearer " + configuration.token, forHTTPHeaderField: "Authorization")
        outgoing.setValue("application/json", forHTTPHeaderField: "Accept")
        outgoing.cachePolicy = .reloadIgnoringLocalCacheData
        outgoing.timeoutInterval = 20
        if !sent.isEmpty {
            outgoing.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do { outgoing.httpBody = try JSONEncoder().encode(NoteSyncRequest(changes: sent, deskPalId: ledger.deskPalId)) }
            catch { status = "Could not prepare task changes."; return }
        }
        let currentGeneration = generation
        status = "Syncing…"
        request = URLSession.shared.dataTask(with: outgoing) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration else { return }
                self.request = nil
                if let error {
                    self.status = "Offline — changes saved on this Mac. \(error.localizedDescription)"
                    return
                }
                guard let http = response as? HTTPURLResponse else { self.status = "Sync returned no response."; return }
                guard http.statusCode == 200 else {
                    switch http.statusCode {
                    case 401: self.status = "Private key was refused. Check Sync settings."
                    case 503: self.status = "The sync service needs its storage configured. Local changes are saved."
                    default: self.status = "Note sync failed (HTTP \(http.statusCode)). Local changes are saved."
                    }
                    return
                }
                guard let data, data.count <= 16_000_000,
                      let result = try? JSONDecoder().decode(NoteSyncResponse.self, from: data), result.valid,
                      self.ledger.entries.allSatisfy({ entry in
                        guard let base = entry.base else { return true }
                        return result.notes.contains { $0.id == base.id && $0.version >= base.version }
                      }) else {
                    self.status = "The sync service returned invalid or incomplete note data. Local notes are saved."
                    return
                }
                // Keep what the server accepted, then retry after the editor flushes its draft.
                guard self.drafts.isEmpty else {
                    self.ledger.acknowledge(notes: result.notes, conflicts: result.conflicts, sent: sent)
                    guard self.persist() else { return }
                    self.localChanged(); return
                }
                self.ledger.reconcile(notes: NoteStore.shared.notes)
                let current = NoteStore.shared.notes
                let notes = self.ledger.receive(notes: result.notes, conflicts: result.conflicts, sent: sent, local: current)
                if let role = result.deskPalId { self.ledger.deskPalId = role }
                self.ledger.recoveryBefore = NoteStore.shared.persistedNotes().map(SyncNote.init)
                self.ledger.recoveryAfter = notes.map(SyncNote.init)
                guard self.persist() else { return }
                guard NoteStore.shared.applySynced(notes) else {
                    self.storageError = "Note storage could not commit sync data. Current notes and recovery journal are retained."
                    self.status = self.storageError!; return
                }
                self.ledger.recoveryBefore = nil; self.ledger.recoveryAfter = nil
                guard self.persist() else { return }
                self.pendingCount = self.ledger.changes.count
                self.status = result.conflicts.isEmpty
                    ? (self.pendingCount == 0 ? "Up to date" : "\(self.pendingCount) changes waiting to sync")
                    : "Another device edited a note. Both versions were kept."
                if self.pendingCount > 0 { self.localChanged() }
            }
        }
        request?.resume()
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        let plain = Crypto.open(data)
        guard !plain.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode(type, from: Data(plain.utf8))
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let json = try JSONEncoder().encode(value)
        let sealed = Crypto.seal(String(decoding: json, as: UTF8.self))
        guard !sealed.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        try sealed.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    @discardableResult
    private func persist() -> Bool {
        do { try write(ledger, to: ledgerURL); return true }
        catch { status = "Could not save the sync queue. Local notes remain saved."; return false }
    }
}
