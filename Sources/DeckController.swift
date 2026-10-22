import AppKit
import SwiftUI
import Combine

// MARK: - Deck state

enum DeckState: Equatable {
    case rest
    case fan
    case expanded(String)

    var rank: Int {
        switch self {
        case .rest: return 0
        case .fan: return 1
        case .expanded: return 2
        }
    }
    var expandedID: String? {
        if case .expanded(let id) = self { return id }
        return nil
    }

    /// The rest pill's length depends on note count. Fan and expanded already
    /// fill the edge, so a `$notes` emission must not relayout those — doing so
    /// shrinks the panel back to 12 pt and eats ⌥⌘N's expand.
    var resizesWithNoteCount: Bool { self == .rest }
}

final class DeckModel: ObservableObject {
    @Published var state: DeckState = .rest
    @Published var showAll = false          // "+N more" opened into a scrolling list
    @Published var findQuery: String?       // nil = find bar hidden
    @Published var renamingID: String?      // inline title edit
    @Published var renameDraft = ""
    @Published var revealTick = 0           // bumped to restage the fan animation
    /// The tab the keyboard is on while the deck is fanned by ⌥⌘A.
    @Published var keyboardFocusID: String?

    /// Owns the NSTextView of the open note so ⌘F can drive it.
    let bridge = EditorBridge()

    /// The deck shows tabs in every state except rest.
    var fanVisible: Bool { state != .rest }

    // Mirrored from Settings so SwiftUI re-renders when a preference flips.
    @Published var style: DeckStyle = Settings.deckStyle
    @Published var edge: DeckEdge = Settings.deckEdge
    @Published var fontSize: Double = Settings.noteFontSize
    /// Published by the controller the instant the panel is resized. Reading this
    /// instead of a GeometryReader matters: the reader reports the *previous* size
    /// for a frame or two after a resize, and the deck lays out against the wrong
    /// edge in the meantime.
    @Published var panelSize: CGSize = .zero

    func syncPreferences() {
        style = Settings.deckStyle
        edge = Settings.deckEdge
        fontSize = Settings.noteFontSize
    }
}

// MARK: - Controller

/// One deck per physical display. Keyed by CGDirectDisplayID because NSScreen
/// instances are replaced wholesale on display reconfiguration.
final class DeckController: NSObject {
    let displayID: CGDirectDisplayID
    let model = DeckModel()

    private let panel = DeckPanel()
    private var hosting: DeckHostingView<DeckRootView>!
    private var container: DeckContentView!
    private var keyMonitor: Any?
    private var outsideMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var idleTimer: Timer?
    private var lastActivity = Date()
    private var lastPointer = NSEvent.mouseLocation
    private var exitWork: DispatchWorkItem?     // debounced pointer-exit check
    private var shrinkWork: DispatchWorkItem?   // delayed panel shrink after collapse
    /// True while the deck was fanned from the keyboard (⌥⌘A) rather than the
    /// pointer — the pointer is somewhere else, so the usual leave-the-hot-zone
    /// collapse must stand down until the mouse takes over.
    private var keyboardDriven = false
    /// What the panel is actually sized for. SwiftUI `model.state` lags two frames
    /// on rest→expanded so the open animation does not drag the deck; `$notes`
    /// still has to see this, not the lagged published state, or it will shrink
    /// the panel back to the pill mid-expand (⌥⌘N).
    private var sizedFor: DeckState = .rest
    private var bag = Set<AnyCancellable>()

    weak var manager: DeckManager?

    var screen: NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        super.init()

        container = DeckContentView()
        container.controller = self
        container.autoresizingMask = [.width, .height]

        hosting = DeckHostingView(rootView: DeckRootView(deck: model, controller: self))
        hosting.autoresizingMask = [.width, .height]
        hosting.frame = container.bounds
        container.addSubview(hosting)

        panel.contentView = container
        layout()
        panel.orderFrontRegardless()

        // Pill height tracks the note count.
        NoteStore.shared.$notes
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.sizedFor.resizesWithNoteCount else { return }
                self.layout()
            }
            .store(in: &bag)
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        idleTimer?.invalidate()
        panel.orderOut(nil)
    }

    // MARK: Layout

    func layout() { layout(for: sizedFor) }

    func layout(for state: DeckState) {
        sizedFor = state
        guard let screen else { return }
        let full = screen.frame
        let vis = screen.visibleFrame
        let edge = Settings.deckEdge

        let frame: NSRect
        switch state {
        case .rest:
            // The pill: a thin strip on the docked edge, centred along it.
            let len = DeckGeom.pillLength(noteCount: max(1, NoteStore.shared.active.count))
            let thick = DeckGeom.pillTouchWidth
            switch edge {
            case .right:
                frame = NSRect(x: full.maxX - thick, y: vis.midY - len / 2,
                               width: thick, height: len)
            case .left:
                frame = NSRect(x: full.minX, y: vis.midY - len / 2,
                               width: thick, height: len)
            case .bottom:
                // Above a visible Dock — which lives at this edge on a default
                // setup and would otherwise sit on top of the pill — and flush
                // to the true edge whenever the Dock is hidden or absent.
                frame = NSRect(x: full.midX - len / 2, y: vis.minY,
                               width: len, height: thick)
            }
        case .fan, .expanded:
            // Same size for both. Resizing the panel as a note opens makes the
            // window resize and SwiftUI's relayout land in different frames, and
            // for one frame the deck draws against the panel's far edge — which
            // looks exactly like the note flying in from mid-screen.
            let depth = DeckGeom.expandedDepth(for: edge)
            switch edge {
            case .right:
                frame = NSRect(x: full.maxX - depth, y: vis.minY,
                               width: depth, height: vis.height)
            case .left:
                frame = NSRect(x: full.minX, y: vis.minY,
                               width: depth, height: vis.height)
            case .bottom:
                frame = NSRect(x: full.minX, y: vis.minY,
                               width: full.width, height: depth)
            }
        }
        panel.setFrame(frame, display: true, animate: false)
        if model.panelSize != frame.size { model.panelSize = frame.size }
    }

    func refreshLevel() {
        panel.applyLevel()
        panel.orderFrontRegardless()
    }

    // MARK: Transitions

    private func setState(_ new: DeckState) {
        let old = model.state
        guard old != new else { return }
        shrinkWork?.cancel(); shrinkWork = nil
        DeckLog.line("setState \(old) -> \(new)  panel=\(Int(panel.frame.width))x\(Int(panel.frame.height))")

        if new.rank >= old.rank {
            layout(for: new)
            if new == .fan {
                model.state = new
                model.revealTick &+= 1
            } else {
                // The panel has to be its final size *and rendered* before the note
                // animates in. `main.async` is not enough — SwiftUI coalesces the
                // resize and the state change into one pass, and then animates the
                // container's width, dragging the whole deck across the screen with
                // it. Two display frames of delay keeps them in separate passes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0 / 60.0) {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        self.model.state = new
                    }
                }
            }
        } else {
            // Let the exit animation play at full size, then shrink the panel.
            model.state = new
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                DeckLog.line("shrink fires; state=\(self.model.state)")
                self.layout(for: self.model.state)
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: work)
        }

        noteActivity()
        if new.expandedID != nil {
            installKeyMonitor(); installOutsideMonitor()
        } else if new == .fan {
            installKeyMonitor()          // the keyboard fan listens for Tab / ↩
        } else {
            removeKeyMonitor(); removeOutsideMonitor()
        }
        if new == .rest { stopIdleWatch() } else { startIdleWatch() }
        if new == .rest {
            // A keyboard fan holds the app active; hand focus back as it tidies away.
            if keyboardDriven { NSApp.deactivate() }
            keyboardDriven = false
            model.keyboardFocusID = nil
            commitRename()
            model.showAll = false
            model.findQuery = nil
        }
    }

    /// Anything the user does keeps the deck awake.
    func noteActivity() { lastActivity = Date() }

    /// A deck left untouched tidies itself away: the fan after a few seconds, an
    /// open note after a minute. Polling the pointer avoids needing mouse-moved
    /// events (and the permissions that can come with watching them globally).
    private func startIdleWatch() {
        guard idleTimer == nil else { return }
        lastActivity = Date()
        lastPointer = NSEvent.mouseLocation
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = NSEvent.mouseLocation
            // The panel is wider than the deck, so the tracking area cannot tell us
            // the pointer has left the tabs; compare against the strip instead.
            if self.model.state == .fan, !self.keyboardDriven,
               !self.hotZone.contains(now) {
                self.collapse(); return
            }
            if abs(now.x - self.lastPointer.x) > 2 || abs(now.y - self.lastPointer.y) > 2 {
                self.lastPointer = now
                self.lastActivity = Date()
            }
            let idle = Date().timeIntervalSince(self.lastActivity)
            switch self.model.state {
            case .expanded where idle > Settings.noteIdleTimeout && !self.openNoteIsPinned:
                self.dismiss()
            default: break
            }
            // The keyboard fan has no pointer to leave, so it does not age out —
            // it stays until Esc / ↩ / the pointer takes over, or another app
            // goes active (watching didResignActive below).
        }
    }

    private func stopIdleWatch() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    func pointerEntered() {
        noteActivity()
        exitWork?.cancel(); exitWork = nil
        shrinkWork?.cancel(); shrinkWork = nil
        DeckLog.line("pointerEntered state=\(model.state) panel=\(Int(panel.frame.width))")
        guard model.state == .rest else {
            // Hand over to the mouse only when it is really on the deck. The
            // panel is far bigger than the fan, and a ⌥⌘A fan opens under a
            // pointer parked mid-screen — cancelling keyboard mode there just
            // lets the watchdog tear the fan straight back down.
            if hotZone.contains(NSEvent.mouseLocation) { endKeyboardFan() }
            layout()
            return
        }
        manager?.deckDidActivate(self)
        setState(.fan)
    }

    /// The panel is deep enough to hold an open note, but the deck itself only
    /// occupies the strip against the screen edge — that strip is what "leaving
    /// the deck" means.
    private var hotZone: NSRect {
        let f = panel.frame
        let d = DeckGeom.fanDepth + 20
        switch Settings.deckEdge {
        case .right:
            return NSRect(x: f.maxX - d, y: f.minY, width: d, height: f.height)
        case .left:
            return NSRect(x: f.minX, y: f.minY, width: d, height: f.height)
        case .bottom:
            return NSRect(x: f.minX, y: f.minY, width: f.width, height: d)
        }
    }

    func pointerExited() {
        guard model.state == .fan else { return }   // an open note stays open until Esc
        // Tracking areas fire spuriously across a resize, so confirm the pointer really left.
        exitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.state == .fan else { return }
            if !self.hotZone.contains(NSEvent.mouseLocation) {
                DeckLog.line("pointerExited confirmed")
                self.setState(.rest)
            }
        }
        exitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func expand(_ id: String) {
        noteActivity()
        manager?.deckDidActivate(self)
        setState(.expanded(id))
        claimKeyAndFocus()
    }

    // MARK: Keyboard fan (⌥⌘A)

    /// The tabs the keyboard is cycling over — mirrors `visible` in DeckRootView.
    private var keyboardVisibleIDs: [String] {
        (model.showAll
            ? NoteStore.shared.active
            : Array(NoteStore.shared.active.prefix(Settings.fanLimit))).map(\.id)
    }

    /// ⌥⌘A: fan the deck without the pointer, ready for Tab / ↩.
    func showDeck() {
        manager?.deckDidActivate(self)
        keyboardDriven = true
        model.keyboardFocusID = keyboardVisibleIDs.first
        setState(.fan)
        installResignWatch()
        // Tab has to reach the deck, so the panel must be key — the fan wakes
        // holding focus, unlike the pointer fan, which never takes it.
        stealFocus()
    }

    /// A keyboard fan outlives the idle watch on purpose; the user moving on to
    /// another app is what ends it.
    private func installResignWatch() {
        guard resignObserver == nil else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.keyboardDriven, self.model.state == .fan else { return }
            self.collapseToRest()
        }
    }

    /// The pointer took over from the keyboard.
    func endKeyboardFan() {
        guard keyboardDriven else { return }
        keyboardDriven = false
        model.keyboardFocusID = nil
    }

    private func cycleKeyboardSelection(backwards: Bool) {
        noteActivity()
        var ids = keyboardVisibleIDs
        guard !ids.isEmpty else { return }
        // Tabbing past the last shown tab pulls the rest out behind it (+N).
        if !backwards, !model.showAll,
           ids.count < NoteStore.shared.active.count,
           model.keyboardFocusID == ids.last {
            model.showAll = true
            ids = NoteStore.shared.active.map(\.id)
        }
        let current = model.keyboardFocusID.flatMap { ids.firstIndex(of: $0) } ?? -1
        model.keyboardFocusID = ids[(current + (backwards ? -1 : 1) + ids.count) % ids.count]
    }

    func beginRename(_ id: String) {
        expand(id)
        model.renameDraft = NoteStore.shared.note(id: id)?.title ?? ""
        model.renamingID = id
        noteActivity()
    }

    func commitRename() {
        guard let id = model.renamingID else { return }
        NoteStore.shared.setTitle(id: id, title: model.renameDraft)
        model.renamingID = nil
        model.bridge.focusText()
    }

    func cancelRename() {
        model.renamingID = nil
        model.bridge.focusText()
    }

    /// Accessory + `.nonactivatingPanel` will show the note without taking keys.
    /// Activation is async and the editor is created two frames later, so keep
    /// asking until the text view can actually take typing.
    private func claimKeyAndFocus() {
        stealFocus()
        for t in [0.0, 0.05, 0.12, 0.25] as [TimeInterval] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self, self.model.state.expandedID != nil else { return }
                self.stealFocus()
                if self.model.renamingID == nil { self.model.bridge.focusText() }
            }
        }
    }

    private func stealFocus() {
        let me = NSRunningApplication.current
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != me.bundleIdentifier {
            _ = me.activate(from: front)
        } else {
            NSApp.activate()
        }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Closing a note steps back to the deck — the tabs stay where they were.
    /// Only leaving the deck entirely puts it back to sleep.
    func collapse() {
        commitRename()
        if model.state.expandedID != nil {
            setState(.fan)
            // Esc out of a keyboard-opened note steps back to the deck, which
            // stays on the keyboard — only the pointer flow hands focus back.
            if !keyboardDriven { NSApp.deactivate() }
            // If the pointer is already away from the edge, the deck follows it
            // shut on the next poll rather than hanging around.
        } else {
            setState(.rest)
        }
    }

    /// True while the open note is pinned — it should survive anything the user
    /// did not aim at it.
    private var openNoteIsPinned: Bool {
        guard let id = model.state.expandedID else { return false }
        return NoteStore.shared.note(id: id)?.pinned ?? false
    }

    /// Dismiss the whole deck, note and tabs together.
    func dismiss() {
        commitRename()
        let wasExpanded = model.state.expandedID != nil
        setState(.rest)
        if wasExpanded { NSApp.deactivate() }
    }

    func collapseToRest() { setState(.rest) }

    // MARK: Key handling for the expanded note

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Keyboard-driven fan (⌥⌘A): Tab picks a tab, ↩ opens it, Esc tidies away.
            if self.model.state == .fan {
                guard self.model.keyboardFocusID != nil else { return event }
                switch event.keyCode {
                case 53:                                              // Esc
                    self.setState(.rest)
                    return nil
                case 48:                                              // Tab
                    self.cycleKeyboardSelection(backwards: mods.contains(.shift))
                    return nil
                case 36, 76:                                          // ↩ / keypad ⏎
                    if let id = self.model.keyboardFocusID { self.expand(id) }
                    return nil
                default:
                    return event
                }
            }
            guard let id = self.model.state.expandedID else { return event }

            if event.keyCode == 53 {                                  // Esc
                if self.model.renamingID != nil { self.cancelRename() }
                else if self.model.findQuery != nil { self.model.findQuery = nil }
                else { self.collapse() }
                return nil
            }
            if mods == .control {
                switch event.charactersIgnoringModifiers {
                case "+", "=":
                    (NSApp.delegate as? AppDelegate)?.stepFontSize(by: 1.5)
                    self.noteActivity()
                    return nil
                case "-", "_":
                    (NSApp.delegate as? AppDelegate)?.stepFontSize(by: -1.5)
                    self.noteActivity()
                    return nil
                default: break
                }
            }
            self.noteActivity()
            guard mods == .command else { return event }
            if event.keyCode == 51 {                                  // ⌘⌫
                NoteStore.shared.delete(id: id)
                self.collapse()
                return nil
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case ".":
                NoteStore.shared.cycleColor(id: id)
                return nil
            case "f":
                self.model.findQuery = self.model.findQuery == nil ? "" : nil
                return nil
            case "t":
                self.model.bridge.toggleTaskLine()
                return nil
            case "p":
                NoteStore.shared.togglePin(id: id)
                return nil
            default:
                return event
            }
        }
    }

    /// A click in any other app dismisses the open note. Mouse-only global monitors
    /// need no Accessibility permission.
    private func installOutsideMonitor() {
        guard outsideMonitor == nil else { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.model.state.expandedID != nil,
                  !self.openNoteIsPinned else { return }
            DispatchQueue.main.async { self.dismiss() }
        }
    }

    private func removeOutsideMonitor() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        outsideMonitor = nil
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    // MARK: Context menu

    func showContextMenu(at event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Note", action: #selector(AppDelegate.newNote), keyEquivalent: "")
        menu.addItem(withTitle: "Task Sync…", action: #selector(AppDelegate.showSyncSettings), keyEquivalent: "")
        menu.addItem(.separator())

        let overFS = NSMenuItem(title: "Show over full-screen apps",
                                action: #selector(AppDelegate.toggleOverFullScreen), keyEquivalent: "")
        overFS.state = Settings.showOverFullScreen ? .on : .off
        menu.addItem(overFS)

        let autoPair = NSMenuItem(title: "Auto-pair brackets",
                                  action: #selector(AppDelegate.toggleAutoPairBrackets), keyEquivalent: "")
        autoPair.state = Settings.autoPairBrackets ? .on : .off
        menu.addItem(autoPair)

        let styleItem = NSMenuItem(title: "Deck style", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for s in DeckStyle.allCases {
            let it = NSMenuItem(title: s.title, action: #selector(AppDelegate.setDeckStyle(_:)), keyEquivalent: "")
            it.representedObject = s.rawValue
            it.state = Settings.deckStyle == s ? .on : .off
            styleMenu.addItem(it)
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        let fontItem = NSMenuItem(title: "Note font", action: nil, keyEquivalent: "")
        let fontMenu = NSMenu()
        for f in Ink.faces {
            let it = NSMenuItem(title: f.name, action: #selector(AppDelegate.setNoteFont(_:)),
                                keyEquivalent: "")
            it.representedObject = f.body
            it.state = Ink.face.body == f.body ? .on : .off
            fontMenu.addItem(it)
        }
        fontItem.submenu = fontMenu
        menu.addItem(fontItem)

        let textItem = NSMenuItem(title: "Text size", action: nil, keyEquivalent: "")
        let textMenu = NSMenu()
        for entry in Settings.fontSizes {
            let it = NSMenuItem(title: entry.name, action: #selector(AppDelegate.setFontSize(_:)),
                                keyEquivalent: "")
            it.representedObject = entry.size
            it.state = abs(Settings.noteFontSize - entry.size) < 0.01 ? .on : .off
            textMenu.addItem(it)
        }
        textItem.submenu = textMenu
        menu.addItem(textItem)

        let edgeItem = NSMenuItem(title: "Deck edge", action: nil, keyEquivalent: "")
        let edgeMenu = NSMenu()
        for e in DeckEdge.allCases {
            let it = NSMenuItem(title: e.title, action: #selector(AppDelegate.setDeckEdge(_:)),
                                keyEquivalent: "")
            it.representedObject = e.rawValue
            it.state = Settings.deckEdge == e ? .on : .off
            edgeMenu.addItem(it)
        }
        edgeItem.submenu = edgeMenu
        menu.addItem(edgeItem)

        let updates = NSMenuItem(title: "Check for Updates…",
                                 action: #selector(AppDelegate.checkForUpdates), keyEquivalent: "")
        menu.addItem(updates)

        let autoUpdate = NSMenuItem(title: "Check automatically",
                                    action: #selector(AppDelegate.toggleAutoUpdates), keyEquivalent: "")
        autoUpdate.state = Updater.shared.automaticallyChecks ? .on : .off
        autoUpdate.isEnabled = Updater.available
        menu.addItem(autoUpdate)
        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at login",
                               action: #selector(AppDelegate.toggleLaunchAtLogin), keyEquivalent: "")
        login.state = Settings.launchAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        let exportItem = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
        let exportMenu = NSMenu()
        exportMenu.addItem(withTitle: "Markdown (one file per note)…",
                           action: #selector(AppDelegate.exportMarkdown), keyEquivalent: "")
        exportMenu.addItem(withTitle: "Plain text (one file per note)…",
                           action: #selector(AppDelegate.exportPlainText), keyEquivalent: "")
        exportMenu.addItem(withTitle: "Single document…",
                           action: #selector(AppDelegate.exportSingleFile), keyEquivalent: "")
        exportMenu.addItem(withTitle: "Sticky archive (.stickies)…",
                           action: #selector(AppDelegate.exportStickies), keyEquivalent: "")
        exportItem.submenu = exportMenu
        menu.addItem(exportItem)
        menu.addItem(withTitle: "Import…", action: #selector(AppDelegate.importStickies), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Noty", action: #selector(AppDelegate.quit), keyEquivalent: "")

        for item in menu.items where item.action != nil {
            item.target = NSApp.delegate
        }
        NSMenu.popUpContextMenu(menu, with: event, for: container)
    }
}

// MARK: - Manager

/// Keeps one deck alive per display and rebuilds the set when displays change.
final class DeckManager {
    private(set) var decks: [CGDirectDisplayID: DeckController] = [:]

    init() {
        rebuild()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.rebuild() }
    }

    func rebuild() {
        let live = Set(NSScreen.screens.compactMap {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        })
        for id in decks.keys where !live.contains(id) { decks.removeValue(forKey: id) }
        for id in live where decks[id] == nil {
            let d = DeckController(displayID: id)
            d.manager = self
            decks[id] = d
        }
        decks.values.forEach { $0.layout() }
    }

    /// Only one deck is open at a time — the one the pointer entered.
    func deckDidActivate(_ active: DeckController) {
        for d in decks.values where d !== active { d.collapseToRest() }
    }

    func refreshAll() {
        decks.values.forEach { $0.model.syncPreferences(); $0.refreshLevel(); $0.layout() }
    }

    /// Deck on the screen holding the pointer, else the main screen's.
    var focused: DeckController? {
        let p = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { $0.frame.contains(p) }),
           let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value {
            return decks[id]
        }
        return decks.values.first
    }
}
