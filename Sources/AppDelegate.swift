import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var deckManager: DeckManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMainMenu()

        deckManager = DeckManager()
        UndoToast.shared.start()
        TaskSync.shared.start()

        HotKeys.shared.register(
            newNote: { [weak self] in self?.newNote() },
            showDeck: { [weak self] in self?.deckManager.focused?.showDeck() }
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeys.shared.unregisterAll()
        TaskSync.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Actions

    @objc func newNote() {
        let note = NoteStore.shared.create()
        deckManager.focused?.expand(note.id)
    }

    @objc func toggleOverFullScreen() {
        Settings.showOverFullScreen.toggle()
        deckManager.refreshAll()
    }

    @objc func toggleAutoPairBrackets() {
        Settings.autoPairBrackets.toggle()
    }

    @objc func setDeckStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = DeckStyle(rawValue: raw) else { return }
        Settings.deckStyle = style
        deckManager.refreshAll()
    }

    @objc func setFontSize(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? Double else { return }
        Settings.noteFontSize = size
        deckManager.refreshAll()
    }

    /// ⌃+ / ⌃- while a note is open.
    func stepFontSize(by delta: Double) {
        Settings.noteFontSize += delta
        deckManager.refreshAll()
    }

    @objc func biggerText()  { stepFontSize(by: 1.5) }
    @objc func smallerText() { stepFontSize(by: -1.5) }

    @objc func setNoteFont(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Settings.noteFontName = name
        deckManager.refreshAll()
    }

    @objc func setDeckEdge(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let edge = DeckEdge(rawValue: raw) else { return }
        Settings.deckEdge = edge
        deckManager.refreshAll()
    }

    @objc func toggleLaunchAtLogin() {
        Settings.launchAtLogin.toggle()
    }

    @objc func exportMarkdown()  { Transfer.export(.markdown,  notes: NoteStore.shared.notes) }
    @objc func exportPlainText() { Transfer.export(.plainText, notes: NoteStore.shared.notes) }
    @objc func exportSingleFile(){ Transfer.export(.singleFile, notes: NoteStore.shared.notes) }
    @objc func exportStickies()  { Transfer.export(.stickies,  notes: NoteStore.shared.notes) }
    @objc func importStickies()  { Transfer.importFiles() }

    @objc func checkForUpdates() { Updater.shared.checkForUpdates() }

    @objc func toggleAutoUpdates() {
        Updater.shared.automaticallyChecks.toggle()
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func showSyncSettings() { TaskSyncWindow.shared.show() }

    @objc func showAbout() {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Noty"
        a.informativeText = """
        Sticky notes docked to the edge of your screen.

        ⌥⌘N  new note      ⌥⌘A  show deck
        Deck up — Tab picks a tab, ↩ opens it ready to type, Esc tidies away.
        In a note — Esc closes, ⌘F finds, ⌘. cycles colour, ⌘⌫ deletes.

        Notes are stored locally in an SQLite database; bodies are encrypted \
        with AES-GCM. Optional sync shares note text with your private site and \
        Desk Pal. Photos remain local files on this Mac.
        """
        a.runModal()
    }

    // MARK: Main menu
    //
    // An accessory app draws no menu bar, but NSApp.mainMenu is still what
    // dispatches ⌘C/⌘V/⌘Z inside the note editor — without it, text editing
    // loses every standard shortcut.

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Noty", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(withTitle: "Task Sync…", action: #selector(showSyncSettings), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "New Note", action: #selector(newNote), keyEquivalent: "n")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Import…", action: #selector(importStickies), keyEquivalent: "i")
        appMenu.addItem(.separator())
        let bigger = appMenu.addItem(withTitle: "Bigger Text", action: #selector(biggerText), keyEquivalent: "+")
        bigger.keyEquivalentModifierMask = [.control]
        let smaller = appMenu.addItem(withTitle: "Smaller Text", action: #selector(smallerText), keyEquivalent: "-")
        smaller.keyEquivalentModifierMask = [.control]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Noty", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Noty", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // The two remaining global shortcuts already carry ⌥; mirror that here so
        // the menu item does not shadow ⌘N inside text fields. ⌥⌘A is handled by
        // the Carbon hotkey alone (it fans the deck).
        for title in ["New Note"] {
            appMenu.item(withTitle: title)?.keyEquivalentModifierMask = [.command, .option]
        }
        for item in appMenu.items where item.action != nil
            && item.action != #selector(NSApplication.hide(_:))
            && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
