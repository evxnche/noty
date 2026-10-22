import AppKit

/// Pure-logic checks for the pieces that don't need a UI: header levels, the
/// `list` keyword transform, task markers, derived titles, the palette count.
/// Run with scripts/run-tests.sh.
@main enum LogicTests {
    static func main() {
        var failed = 0

        func check(_ name: String, _ condition: Bool) {
            if condition {
                print("✓ \(name)")
            } else {
                failed += 1
                print("✗ \(name)")
            }
        }
        func checkEqual<T: Equatable>(_ name: String, _ got: T, _ want: T) {
            check(name, got == want)
        }

        // Sync shares checkbox lines only, keeping local prose and photos private.
        var syncNote = Note()
        syncNote.body = "Private preface\n☐ Buy milk\n![Photo](photo-private.png)\n☑ Call mum\n☐ "
        var ledger = TaskSyncLedger()
        ledger.reconcile(notes: [syncNote])
        checkEqual("sync extracts non-empty checkbox tasks", ledger.entries.count, 2)
        checkEqual("sync hides derived prose titles", ledger.entries.first?.task.listTitle, "Tasks")
        check("sync excludes private prose and photo links", ledger.entries.allSatisfy {
            !$0.task.text.contains("Private") && !$0.task.text.contains("photo-")
        })
        let milkID = ledger.entries.first!.task.id
        let callID = ledger.entries.last!.task.id
        let initial = ledger.changes
        let newChangeJSON = String(decoding: try! JSONEncoder().encode(initial[0]), as: UTF8.self)
        check("new task wire format sends an explicit null base", newChangeJSON.contains("\"base\":null"))
        let uploaded = initial.map { change -> SyncTask in
            var task = change.task; task.version = 1; return task
        }
        _ = ledger.receive(tasks: uploaded, conflicts: [], sent: initial, notes: [syncNote])
        check("sync acknowledgement clears queued changes", ledger.changes.isEmpty)
        syncNote.body = "Private preface\n☐ New task\n☑ Call mum\n☐ Buy milk\n![Photo](photo-private.png)"
        ledger.reconcile(notes: [syncNote])
        checkEqual("sync keeps task identity after insertion and reorder", ledger.entries.first { $0.task.text == "Buy milk" }?.task.id, milkID)
        checkEqual("sync keeps completed task identity", ledger.entries.first { $0.task.text == "Call mum" }?.task.id, callID)
        var remoteMilk = uploaded.first { $0.id == milkID }!
        remoteMilk.completed = true; remoteMilk.version = 2
        let changedNotes = ledger.receive(tasks: [remoteMilk, uploaded.last!], conflicts: [], sent: [], notes: [syncNote])
        check("remote update preserves private prose", changedNotes[0].body.contains("Private preface"))
        check("remote update preserves photo link", changedNotes[0].body.contains("![Photo](photo-private.png)"))
        check("remote completion merges alongside pending reorder", changedNotes[0].body.contains("☑ Buy milk"))

        var duplicate = Note(); duplicate.body = "☐ Same\n☐ Same"
        var duplicateLedger = TaskSyncLedger(); duplicateLedger.reconcile(notes: [duplicate])
        checkEqual("duplicate task text still has distinct IDs", Set(duplicateLedger.entries.map { $0.task.id }).count, 2)
        var deletion = TaskSyncLedger(); deletion.reconcile(notes: [syncNote])
        let deletionSent = deletion.changes
        _ = deletion.receive(tasks: deletionSent.map { var t = $0.task; t.version = 1; return t }, conflicts: [], sent: deletionSent, notes: [syncNote])
        deletion.reconcile(notes: [])
        check("deleting a synced note queues tombstones", deletion.changes.allSatisfy { $0.task.deleted } && deletion.changes.count == 3)
        var unpublished = TaskSyncLedger(); unpublished.reconcile(notes: [duplicate]); unpublished.reconcile(notes: [])
        check("never-published deleted tasks need no upload", unpublished.changes.isEmpty)

        var inflight = TaskSyncLedger(); inflight.reconcile(notes: [duplicate])
        let sending = inflight.changes
        duplicate.body = "☐ Edited during request\n☐ Same"
        inflight.reconcile(notes: [duplicate])
        let received = sending.map { var t = $0.task; t.version = 1; return t }
        _ = inflight.receive(tasks: received, conflicts: [], sent: sending, notes: [duplicate])
        check("edit made during upload stays queued", inflight.changes.contains { $0.task.text == "Edited during request" })
        check("in-flight edit rebases to acknowledgement", inflight.changes.first?.base?.version == 1)

        var freshRemote = SyncTask(noteId: UUID().uuidString, listTitle: "Mobile", text: "Created on phone", completed: false, position: 0)
        freshRemote.version = 1
        var freshLedger = TaskSyncLedger()
        let phoneNotes = freshLedger.receive(tasks: [freshRemote], conflicts: [], sent: [], notes: [])
        check("phone list creates a native note", phoneNotes.first?.body == "☐ Created on phone" && phoneNotes.first?.title == "Mobile")

        var conflictNote = Note(); conflictNote.body = "Private heading\n☐ Original task"
        var conflictLedger = TaskSyncLedger(); conflictLedger.reconcile(notes: [conflictNote])
        let conflictInitial = conflictLedger.changes
        var serverTask = conflictInitial[0].task; serverTask.version = 1
        _ = conflictLedger.receive(tasks: [serverTask], conflicts: [], sent: conflictInitial, notes: [conflictNote])
        conflictNote.body = "Private heading\n☐ Local edit"
        conflictLedger.reconcile(notes: [conflictNote])
        let conflictingSent = conflictLedger.changes
        serverTask.text = "Phone edit"; serverTask.version = 2
        let preserved = conflictLedger.receive(tasks: [serverTask], conflicts: [SyncConflict(id: serverTask.id, task: serverTask)], sent: conflictingSent, notes: [conflictNote])
        check("conflicting task text keeps both versions", preserved[0].body.contains("☐ Phone edit") && preserved[0].body.contains("☐ Local edit"))
        check("conflict copy gets a new ID", conflictLedger.changes.count == 1 && conflictLedger.changes[0].task.id != serverTask.id)
        check("conflict keeps surrounding prose", preserved[0].body.contains("Private heading"))
        var firstUpload = TaskSyncLedger()
        var fleeting = Note(); fleeting.body = "☐ Removed while uploading"
        firstUpload.reconcile(notes: [fleeting])
        let firstSent = firstUpload.changes
        firstUpload.reconcile(notes: [])
        let acceptedFirst = firstSent.map { var t = $0.task; t.version = 1; return t }
        let afterRemoval = firstUpload.receive(tasks: acceptedFirst, conflicts: [], sent: firstSent, notes: [])
        check("first upload cannot resurrect a note removed in flight", afterRemoval.isEmpty)
        check("removal during first upload queues acknowledged tombstone", firstUpload.changes.first?.task.deleted == true && firstUpload.changes.first?.base?.version == 1)
        var lostUpload = TaskSyncLedger(); lostUpload.reconcile(notes: [fleeting])
        let lostSent = lostUpload.changes
        lostUpload.reconcile(notes: [])
        let lostAcknowledgement = lostSent.map { var t = $0.task; t.version = 1; return t }
        let afterLostResponse = lostUpload.receive(tasks: lostAcknowledgement, conflicts: [], sent: [], notes: [])
        check("lost first-upload response cannot revive a removed note", afterLostResponse.isEmpty)
        check("later GET queues the first-upload deletion", lostUpload.changes.first?.task.deleted == true)
        var orderNote = Note(); orderNote.applyTypedTitle("Mac title"); orderNote.body = "Private line\n☐ First\nPhoto stays here\n☐ Second"
        var orderLedger = TaskSyncLedger(); orderLedger.reconcile(notes: [orderNote])
        let orderSent = orderLedger.changes
        var orderedRemote = orderSent.map { var t = $0.task; t.version = 1; return t }
        let acknowledgedOrder = orderLedger.receive(tasks: orderedRemote, conflicts: [], sent: orderSent, notes: [orderNote])
        orderedRemote[0].position = 1; orderedRemote[1].position = 0
        for i in orderedRemote.indices { orderedRemote[i].listTitle = "Phone title"; orderedRemote[i].version = 2 }
        let reorderedNotes = orderLedger.receive(tasks: orderedRemote, conflicts: [], sent: [], notes: acknowledgedOrder)
        checkEqual("remote reorder updates native checkbox slots", reorderedNotes[0].body, "Private line\n☐ Second\nPhoto stays here\n☐ First")
        checkEqual("remote rename updates native custom title", reorderedNotes[0].title, "Phone title")
        orderLedger.reconcile(notes: reorderedNotes)
        check("native reconciliation does not undo remote order or title", orderLedger.changes.isEmpty)
        let key = String(repeating: "a", count: 32)
        check("HTTPS sync configuration is ready", TaskSyncConfiguration(endpoint: "https://noty.example", token: key, enabled: true).ready)
        check("remote cleartext endpoint is rejected", !TaskSyncConfiguration(endpoint: "http://noty.example", token: key, enabled: true).ready)
        check("loopback endpoint is allowed for local verification", TaskSyncConfiguration(endpoint: "http://127.0.0.1:4545", token: key, enabled: true).ready)
        check("endpoint credentials are rejected", !TaskSyncConfiguration(endpoint: "https://user:secret@noty.example", token: key, enabled: true).ready)
        check("short key is rejected", !TaskSyncConfiguration(endpoint: "https://noty.example", token: "short", enabled: true).ready)
        check("pairing key stays in fragment", TaskSyncConfiguration(endpoint: "https://noty.example", token: key, enabled: true).pairingURL?.query == nil)

        // Photos survive reload as relative links, with collision-free local copies.
        let photoDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: photoDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: photoDirectory) }
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let data = bitmap.representation(using: .png, properties: [:])!
            let first = try Photos.save(data, extension: "png", directory: photoDirectory)
            let second = try Photos.save(data, extension: "png", directory: photoDirectory)
            check("photo copies have unique names", first != second)
            let names = Photos.names(in: first + "\n" + first + "\n" + second)
            checkEqual("photo links deduplicate", names.count, 2)
            checkEqual("photo bytes preserved", try Data(contentsOf: photoDirectory.appendingPathComponent(names[0])), data)
            check("photo link rejects traversal", Photos.names(in: "![Photo](../../note.key)").isEmpty)
            do {
                _ = try Photos.save(Data("invalid".utf8), extension: "png", directory: photoDirectory)
                check("invalid image rejected", false)
            } catch { check("invalid image rejected", true) }
        } catch { check("photo storage: \(error)", false) }

        // MARK: Headers

        checkEqual("h1", Headers.level(of: "# Title"), 1)
        checkEqual("h2", Headers.level(of: "## Sub"), 2)
        checkEqual("h6", Headers.level(of: "###### Deep"), 6)
        checkEqual("bare hash is a header in the making", Headers.level(of: "#"), 1)
        checkEqual("hash and space", Headers.level(of: "# "), 1)
        check("no space after hashes is prose", Headers.level(of: "#Title") == nil)
        check("seven hashes is prose", Headers.level(of: "#######") == nil)
        check("plain line", Headers.level(of: "list") == nil)
        check("empty line", Headers.level(of: "") == nil)

        // MARK: The list keyword

        // Fresh note: one task, ready to type.
        let fresh = Tasks.listTransform(text: "list", caret: 4)
        checkEqual("fresh note becomes one empty task", fresh?.text, "☐ ")
        checkEqual("caret lands after the box", fresh?.caret, 2)

        // Caret anywhere on the keyword line still triggers.
        check("caret mid-keyword triggers",
              Tasks.listTransform(text: "list", caret: 2) != nil)

        // Prose converts; the keyword line is consumed.
        let conv = Tasks.listTransform(text: "list\nmilk\nbread", caret: 4)
        checkEqual("prose becomes tasks", conv?.text, "☐ milk\n☐ bread")
        checkEqual("caret at end of first task", conv?.caret, 6)

        // Blank lines are left blank, existing tasks keep their marks; every
        // other non-empty line gains a box, the note as a whole is the list.
        let mixed = Tasks.listTransform(text: "Shopping\nlist\n\nmilk\n☑ done", caret: 12)
        checkEqual("blank stays blank, done stays done",
                   mixed?.text, "☐ Shopping\n\n☐ milk\n☑ done")

        // Case-insensitive.
        check("LIST triggers too", Tasks.listTransform(text: "LIST", caret: 4) != nil)

        // An already-all-tasks note strips back to prose.
        let strip = Tasks.listTransform(text: "☐ milk\n☑ bread\nlist", caret: 19)
        checkEqual("all-tasks note strips to prose", strip?.text, "milk\nbread")

        // Not the keyword: part of a longer line, or another line entirely.
        check("word inside a sentence does not trigger",
              Tasks.listTransform(text: "a list of things", caret: 6) == nil)
        check("listing does not trigger",
              Tasks.listTransform(text: "listing", caret: 7) == nil)
        check("keyword on another line does not trigger",
              Tasks.listTransform(text: "list\nmilk", caret: 9) == nil)
        check("cr line endings decline politely",
              Tasks.listTransform(text: "list\r\nmilk", caret: 4) == nil)

        // MARK: Tasks round-trip

        checkEqual("markdown task in", Tasks.fromMarkdown("- [ ] buy\n- [x] done"),
                   "☐ buy\n☑ done")
        checkEqual("markdown task out", Tasks.toMarkdown("☐ buy\n☑ done"),
                   "- [ ] buy\n- [x] done")

        // MARK: Self-populating lists

        // Parsing: bullets, numbered items, and the prose that must stay prose.
        let dash = Lists.item("- milk")
        checkEqual("dash bullet prefix", dash?.prefix, "- ")
        checkEqual("dash bullet carries on", dash?.nextPrefix, "- ")
        checkEqual("dash bullet body", dash?.body, "milk")
        checkEqual("star bullet prefix", Lists.item("* milk")?.nextPrefix, "* ")
        checkEqual("angle bullet prefix", Lists.item("> milk")?.nextPrefix, "> ")
        checkEqual("numbered counts up", Lists.item("1. first")?.nextPrefix, "2. ")
        checkEqual("slash numbering counts up", Lists.item("3/ third")?.nextPrefix, "4/ ")
        checkEqual("slash numbering keeps its separator", Lists.item("3/ third")?.prefix(number: 4), "4/ ")
        checkEqual("multi-digit numbers count up", Lists.item("9. nine")?.nextPrefix, "10. ")
        checkEqual("indent carried onto the next line",
                   Lists.item("  - nested")?.nextPrefix, "  - ")
        checkEqual("indent kept on exit", Lists.item("  - nested")?.indent, "  ")
        check("empty bullet is a list end", Lists.item("- ")?.isBlank == true)
        check("empty number is a list end", Lists.item("2. ")?.isBlank == true)
        check("numbered item is numbered", Lists.item("1. first")?.isNumbered == true)
        check("bullet is not numbered", Lists.item("- milk")?.isNumbered == false)

        check("plain sentence is prose", Lists.item("not a list") == nil)
        check("marker needs its space", Lists.item("-milk") == nil)
        check("decimals stay prose", Lists.item("1.5 things") == nil)
        check("hash header is prose", Lists.item("# Heading") == nil)
        check("task line is prose to the list parser", Lists.item("☐ milk") == nil)
        check("bare indent is prose", Lists.item("   ") == nil)
        check("empty line is prose", Lists.item("") == nil)

        // Renumbering: a split mid-list straightens the lines after it.
        checkEqual("split renumbers the rest",
                   Lists.renumbered(["1. one", "2. tw", "2. o", "3. three"], around: 2),
                   ["1. one", "2. tw", "3. o", "4. three"])
        checkEqual("a block's first number anchors it",
                   Lists.renumbered(["5. five", "5. more"], around: 1),
                   ["5. five", "6. more"])
        checkEqual("bullets break a block",
                   Lists.renumbered(["1. one", "- two", "2. three"], around: 2),
                   ["1. one", "- two", "2. three"])
        checkEqual("indent depths count separately",
                   Lists.renumbered(["1. one", "  1. deep", "  2. deep", "  2. deep"], around: 3),
                   ["1. one", "  1. deep", "  2. deep", "  3. deep"])
        checkEqual("leaving a depth re-anchors it",
                   Lists.renumbered(["1. one", "  1. deep", "  2. deep", "2. two"], around: 3),
                   ["1. one", "  1. deep", "  2. deep", "2. two"])
        check("bullets are left alone",
              Lists.renumbered(["- one", "- two"], around: 1) == ["- one", "- two"])
        check("anchor outside the lines changes nothing",
              Lists.renumbered(["- one"], around: 5) == ["- one"])

        // MARK: Bracket pairing

        checkEqual("paren closes itself", Lists.closingBracket(for: "("), ")")
        checkEqual("square closes itself", Lists.closingBracket(for: "["), "]")
        checkEqual("curly closes itself", Lists.closingBracket(for: "{"), "}")
        checkEqual("quote closes itself", Lists.closingBracket(for: "\""), "\"")
        check("letters stand alone", Lists.closingBracket(for: "x") == nil)

        check("bang asks for an image", Lists.breaksImageSyntax(beforeCaret: "see!", typed: "["))
        check("closed alt asks for a paren", Lists.breaksImageSyntax(beforeCaret: "![alt]", typed: "("))
        check("plain brackets pair", !Lists.breaksImageSyntax(beforeCaret: "see ", typed: "["))
        check("plain parens pair", !Lists.breaksImageSyntax(beforeCaret: "see ", typed: "("))
        check("only images mind", !Lists.breaksImageSyntax(beforeCaret: "see ", typed: "{"))

        // MARK: Titles

        checkEqual("title strips hashes", Note.derivedTitle(from: "# Heading"), "Heading")
        checkEqual("title strips task mark", Note.derivedTitle(from: "☐ task"), "task")
        checkEqual("hashes stripped from title even without a space",
                  Note.derivedTitle(from: "#tag"), "tag")

        var n = Note(body: "# Shopping\nmilk")
        n.applyTypedTitle("Groceries")
        checkEqual("typed title is kept", n.title, "Groceries")
        check("typed title is custom", n.titleCustom)
        n.applyBody("# Shopping\nmilk\nbread")
        checkEqual("body edit does not overwrite a custom title", n.title, "Groceries")

        n.applyTypedTitle("  ")
        check("blank rename returns to derived", !n.titleCustom)
        checkEqual("blank rename uses first line", n.title, "Shopping")

        n.applyBody("# Errands")
        checkEqual("auto title follows the body again", n.title, "Errands")

        n.applyTypedTitle("  Desk  ")
        checkEqual("rename trims whitespace", n.title, "Desk")

        // MARK: ⌥⌘N vs the rest pill

        // Creating a note publishes $notes. The rest pill must resize; fan and
        // expanded already fill the edge, so that emission must not shrink them
        // back to the 12 pt pill — which is what used to eat ⌥⌘N's expand.
        check("rest pill tracks note count", DeckState.rest.resizesWithNoteCount)
        check("fan does not shrink when a note is created", !DeckState.fan.resizesWithNoteCount)
        check("expanded does not shrink when a note is created",
              !DeckState.expanded("n").resizesWithNoteCount)

        // MARK: Palette

        checkEqual("eight shades of grey", NoteColor.all.count, 8)
        checkEqual("stored indices keep resolving", NoteColor.at(9).name, NoteColor.at(1).name)
        checkEqual("negative index wraps", NoteColor.at(-1).name, NoteColor.all[7].name)

        // MARK: Bundled fonts

        // With the built app passed as the argument: its Resources/Fonts must
        // register and resolve — the same path launch takes.
        if let appPath = CommandLine.arguments.dropFirst().first {
            if let bundle = Bundle(url: URL(fileURLWithPath: appPath)) {
                FontLoader.registerBundled(bundle: bundle)
                check("IBM Plex Mono body resolves from the bundle",
                      NSFont(name: Ink.plexBody, size: 12) != nil)
                check("IBM Plex Mono tab cut resolves from the bundle",
                      NSFont(name: Ink.plexTab, size: 12) != nil)
                check("Departure Mono resolves from the bundle",
                      NSFont(name: Ink.departure, size: 12) != nil)
            } else {
                check("app bundle loads", false)
            }
        }

        if failed > 0 {
            print("\n\(failed) failure\(failed == 1 ? "" : "s")")
            exit(1)
        }
        print("\nall green")
    }
}
