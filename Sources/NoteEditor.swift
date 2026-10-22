import SwiftUI
import AppKit

// MARK: - Bridge to the underlying NSTextView (used for ⌘F)

final class EditorBridge: ObservableObject {
    weak var textView: NSTextView?
    @Published var matchCount = 0

    func recount(_ q: String) {
        guard let tv = textView, !q.isEmpty else { matchCount = 0; return }
        let ns = tv.string as NSString
        var count = 0, loc = 0
        while loc < ns.length {
            let r = ns.range(of: q, options: [.caseInsensitive],
                             range: NSRange(location: loc, length: ns.length - loc))
            if r.location == NSNotFound { break }
            count += 1
            loc = r.location + max(1, r.length)
        }
        matchCount = count
    }

    func findNext(_ q: String, forward: Bool = true) {
        guard let tv = textView, !q.isEmpty else { return }
        let ns = tv.string as NSString
        let sel = tv.selectedRange()
        var found: NSRange

        if forward {
            let start = min(ns.length, NSMaxRange(sel))
            found = ns.range(of: q, options: [.caseInsensitive],
                             range: NSRange(location: start, length: ns.length - start))
            if found.location == NSNotFound {
                found = ns.range(of: q, options: [.caseInsensitive])   // wrap
            }
        } else {
            found = ns.range(of: q, options: [.caseInsensitive, .backwards],
                             range: NSRange(location: 0, length: sel.location))
            if found.location == NSNotFound {
                found = ns.range(of: q, options: [.caseInsensitive, .backwards])
            }
        }
        guard found.location != NSNotFound else { return }
        tv.setSelectedRange(found)
        tv.scrollRangeToVisible(found)
        tv.showFindIndicator(for: found)
    }

    /// Turn the caret's line into a task, or strip the checkbox back off it.
    func toggleTaskLine() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let ns = tv.string as NSString
        let caret = min(tv.selectedRange().location, ns.length)
        let line = ns.lineRange(for: NSRange(location: caret, length: 0))
        let text = ns.substring(with: line)

        if Tasks.isTask(text) {
            var length = 1
            if line.length > 1, ns.character(at: line.location + 1) == 32 { length = 2 }
            let range = NSRange(location: line.location, length: length)
            guard tv.shouldChangeText(in: range, replacementString: "") else { return }
            storage.replaceCharacters(in: range, with: "")
        } else {
            let range = NSRange(location: line.location, length: 0)
            guard tv.shouldChangeText(in: range, replacementString: Tasks.openPrefix) else { return }
            storage.replaceCharacters(in: range, with: Tasks.openPrefix)
        }
        tv.didChangeText()
    }

    func focusText() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }
}

// MARK: - NSTextView wrapper

/// Text view that treats a leading ☐ / ☑ as a real checkbox: clicking the box
/// toggles it, Return carries the list on, and finished lines get struck through.
final class TaskTextView: NSTextView {
    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty, urls.allSatisfy({ NSImage(contentsOf: $0) != nil }) {
            insertPhotos(urls)
            return
        }
        if let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
            do {
                let link = try Photos.save(png, extension: "png")
                insertText("\n" + link + "\n", replacementRange: selectedRange())
            } catch { NSAlert(error: error).runModal() }
            return
        }
        super.paste(sender)
    }


    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if toggleBox(at: point) { return }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let lm = layoutManager, let tc = textContainer else { return }
        let ns = string as NSString
        let origin = textContainerOrigin
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: .byLines) { sub, range, _, _ in
            guard let sub, Tasks.isTask(sub) else { return }
            let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1),
                                       actualCharacterRange: nil)
            var r = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            r.origin.x += origin.x
            r.origin.y += origin.y
            self.addCursorRect(r.insetBy(dx: -3, dy: -2), cursor: .pointingHand)
        }
    }

    /// Returns true when the click landed on a checkbox and was consumed.
    private func toggleBox(at point: NSPoint) -> Bool {
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage else { return false }
        let ns = string as NSString
        guard ns.length > 0 else { return false }

        let index = min(characterIndexForInsertion(at: point), max(0, ns.length - 1))
        let line = ns.lineRange(for: NSRange(location: index, length: 0))
        guard line.length > 0 else { return false }
        let first = ns.character(at: line.location)
        guard first == Tasks.open.unicodeScalars.first!.value ||
              first == Tasks.done.unicodeScalars.first!.value else { return false }

        let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: line.location, length: 1),
                                   actualCharacterRange: nil)
        var box = lm.boundingRect(forGlyphRange: glyphs, in: tc)
        box.origin.x += textContainerOrigin.x
        box.origin.y += textContainerOrigin.y
        guard box.insetBy(dx: -4, dy: -3).contains(point) else { return false }

        let target = NSRange(location: line.location, length: 1)
        let flipped = String(first == Tasks.open.unicodeScalars.first!.value ? Tasks.done : Tasks.open)
        guard shouldChangeText(in: target, replacementString: flipped) else { return true }
        storage.replaceCharacters(in: target, with: flipped)
        didChangeText()
        return true
    }
}

struct NoteTextView: NSViewRepresentable {
    @Binding var text: String
    let ink: NSColor
    let bridge: EditorBridge
    var autofocus: Bool
    var fontSize: CGFloat = 13.5

    static func bodyFont(_ size: CGFloat) -> NSFont { Ink.body(size) }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let tv = TaskTextView()
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = Self.bodyFont(fontSize)
        tv.textColor = ink
        tv.insertionPointColor = ink
        tv.textContainerInset = NSSize(width: 15, height: 6)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.string = text

        scroll.documentView = tv
        bridge.textView = tv
        Self.restyle(tv, ink: ink, size: fontSize)
        if autofocus { Self.retryFocus(tv, remaining: 8) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
            Self.restyle(tv, ink: ink, size: fontSize)
        }
        let want = Self.bodyFont(fontSize)
        if tv.textColor != ink || tv.font != want {
            tv.textColor = ink
            tv.insertionPointColor = ink
            tv.font = want
            Self.restyle(tv, ink: ink, size: fontSize)
        }
        if bridge.textView !== tv { bridge.textView = tv }
    }

    /// ⌥⌘N creates the editor before the panel has become key. One async
    /// `makeFirstResponder` is a no-op in that window; keep trying briefly.
    /// Stop if some other text field (the find bar) already has focus.
    static func retryFocus(_ tv: NSTextView, remaining: Int) {
        DispatchQueue.main.async {
            guard remaining > 0 else { return }
            if let fr = tv.window?.firstResponder, fr !== tv,
               fr is NSTextView || fr is NSTextField { return }
            tv.window?.makeKeyAndOrderFront(nil)
            _ = tv.window?.makeFirstResponder(tv)
            if tv.window?.isKeyWindow == true, tv.window?.firstResponder === tv { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                retryFocus(tv, remaining: remaining - 1)
            }
        }
    }

    /// The note's plain-text styling pass: body face everywhere, header lines
    /// redrawn in the header face a step larger, and anything already ticked off
    /// dimmed and struck through.
    ///
    /// Restyling touches the whole document, which happens on every keystroke.
    /// Two things make that safe: the caret has to be put back afterwards, and
    /// `typingAttributes` has to be refreshed — otherwise the next character is
    /// inserted in the *previous* font and immediately rewritten, which reads as
    /// the text jumping under the cursor after a font or size change.
    static func restyle(_ tv: NSTextView, ink: NSColor, size: CGFloat = 13.5) {
        let font = bodyFont(size)
        tv.typingAttributes = [.font: font, .foregroundColor: ink]

        guard let storage = tv.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }
        let caret = tv.selectedRange()
        storage.beginEditing()
        storage.removeAttribute(.strikethroughStyle, range: full)
        storage.addAttribute(.foregroundColor, value: ink, range: full)
        storage.addAttribute(.font, value: font, range: full)
        let ns = storage.string as NSString
        ns.enumerateSubstrings(in: full, options: .byLines) { sub, range, _, _ in
            guard let sub else { return }
            if let level = Headers.level(of: sub) {
                storage.addAttribute(.font,
                                     value: Ink.headerFont(level: level, size: size),
                                     range: range)
            } else if Tasks.marker(of: sub) == Tasks.done {
                storage.addAttribute(.strikethroughStyle,
                                     value: NSUnderlineStyle.single.rawValue, range: range)
                storage.addAttribute(.foregroundColor,
                                     value: ink.withAlphaComponent(0.45), range: range)
            }
        }
        storage.endEditing()
        let end = (storage.string as NSString).length
        tv.setSelectedRange(NSRange(location: min(caret.location, end),
                                    length: min(caret.length, end - min(caret.location, end))))
        tv.window?.invalidateCursorRects(for: tv)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: NoteTextView
        /// Set while the delegate itself is rewriting the note — the `list`
        /// keyword, a task or list carrying on — so the text-did-change those
        /// trigger cannot re-trigger the keyword mid-rewrite.
        private var applyingRewrite = false

        init(_ p: NoteTextView) { parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if !applyingRewrite { applyListKeywordIfTyped(tv) }
            NoteTextView.restyle(tv, ink: parent.ink, size: parent.fontSize)
            parent.text = tv.string
        }

        /// Typing a line that says just "list" turns the note into a tasklist
        /// (or strips it back to prose when it already is one). One edit, so one
        /// ⌘Z undoes the whole conversion.
        private func applyListKeywordIfTyped(_ tv: NSTextView) {
            guard let result = Tasks.listTransform(text: tv.string,
                                                   caret: tv.selectedRange().location) else { return }
            applyingRewrite = true
            let full = NSRange(location: 0, length: (tv.string as NSString).length)
            if tv.shouldChangeText(in: full, replacementString: result.text) {
                tv.textStorage?.replaceCharacters(in: full, with: result.text)
                tv.didChangeText()
                let end = (result.text as NSString).length
                let caret = NSRange(location: min(result.caret, end), length: 0)
                tv.setSelectedRange(caret)
                tv.scrollRangeToVisible(caret)
            }
            applyingRewrite = false
        }

        /// Return on a task line starts the next task; on an empty one, ends the
        /// list. Plain lists — bullets and numbered items — carry themselves on
        /// the same way, numbers counting up. An opening bracket types together
        /// with its closing half.
        func textView(_ tv: NSTextView, shouldChangeTextIn range: NSRange,
                      replacementString replacement: String?) -> Bool {
            if pairBracketIfTyped(tv, range: range, replacement: replacement) { return false }

            guard replacement == "\n" else { return true }
            let ns = tv.string as NSString
            guard range.location <= ns.length else { return true }
            let line = ns.lineRange(for: NSRange(location: range.location, length: 0))
            let text = ns.substring(with: line)

            if Tasks.isTask(text) {
                if Tasks.stripped(text.trimmingCharacters(in: .newlines)).isEmpty {
                    let clear = NSRange(location: line.location,
                                        length: min(line.length, ns.length - line.location))
                    applyingRewrite = true
                    defer { applyingRewrite = false }
                    if tv.shouldChangeText(in: clear, replacementString: "") {
                        tv.textStorage?.replaceCharacters(in: clear, with: "")
                        tv.didChangeText()
                    }
                    return false
                }
                applyingRewrite = true
                defer { applyingRewrite = false }
                tv.insertText("\n" + Tasks.openPrefix, replacementRange: range)
                return false
            }

            if carryListIfTyped(tv, range: range) {
                return false
            }
            return true
        }

        /// An opening bracket arrives together with its closing half, the caret
        /// left between the two — `(` becomes `()` with the cursor inside. Skipped
        /// when a selection is being replaced rather than a pair opened, and where
        /// the pair would corrupt Markdown image syntax. Returns true when it
        /// handled the keystroke.
        private func pairBracketIfTyped(_ tv: NSTextView, range: NSRange,
                                        replacement: String?) -> Bool {
            guard Settings.autoPairBrackets, range.length == 0,
                  let typed = replacement, typed.count == 1,
                  let close = Lists.closingBracket(for: Character(typed)) else { return false }
            let ns = tv.string as NSString
            guard range.location <= ns.length else { return false }
            let before = ns.substring(to: range.location)
            guard !Lists.breaksImageSyntax(beforeCaret: before, typed: Character(typed)) else { return false }

            tv.insertText(typed + String(close), replacementRange: range)
            tv.setSelectedRange(NSRange(location: range.location + 1, length: 0))
            return true
        }

        /// Return on a plain list line — a bullet or a numbered item — carries its
        /// prefix onto the next line, splitting the text at the caret, numbers
        /// counting up and the lines after a mid-list split renumbering to match.
        /// Return on an emptied item ends the list instead: the marker comes off
        /// and the line keeps its indent. A selection goes first, replaced by the
        /// Return the way a plain newline would replace it. The whole thing lands
        /// as one edit, so one ⌘Z takes it all back. Returns false when the line
        /// opens as ordinary prose and Return should behave normally.
        private func carryListIfTyped(_ tv: NSTextView, range: NSRange) -> Bool {
            let fullText = tv.string as NSString
            guard range.location <= fullText.length else { return false }
            let whole = range.length > 0
                ? fullText.replacingCharacters(in: range, with: "")
                : tv.string
            let ns = whole as NSString
            let line = ns.lineRange(for: NSRange(location: range.location, length: 0))
            guard let item = Lists.item(
                ns.substring(with: line).trimmingCharacters(in: .newlines)) else { return false }
            var lines = whole.components(separatedBy: "\n")
            let li = min(whole.prefix(line.location).filter { $0 == "\n" }.count,
                         lines.count - 1)
            let destination: Int

            if item.isBlank {
                lines[li] = item.indent                       // list over; indent stays
                destination = line.location + (item.indent as NSString).length
            } else {
                let body = item.body as NSString
                let at = max(0, min(range.location - line.location - (item.prefix as NSString).length,
                                    body.length))
                lines[li] = item.prefix + body.substring(with: NSRange(location: 0, length: at))
                lines.insert(item.nextPrefix + body.substring(from: at), at: li + 1)
                lines = Lists.renumbered(lines, around: li + 1)
                // The caret waits at the end of the new line's prefix, which the
                // renumbering may have rewritten.
                let newPrefix = Lists.item(lines[li + 1])?.prefix ?? item.nextPrefix
                destination = line.location + (lines[li] as NSString).length + 1
                    + (newPrefix as NSString).length
            }

            let joined = lines.joined(separator: "\n")
            guard joined != whole else { return false }
            let full = NSRange(location: 0, length: ns.length)
            applyingRewrite = true
            defer { applyingRewrite = false }
            if tv.shouldChangeText(in: full, replacementString: joined) {
                tv.textStorage?.replaceCharacters(in: full, with: joined)
                tv.didChangeText()
                let caretRange = NSRange(location: min(destination, (joined as NSString).length),
                                         length: 0)
                tv.setSelectedRange(caretRange)
                tv.scrollRangeToVisible(caretRange)
            }
            return true
        }
    }
}

// MARK: - Editor

struct NoteEditorView: View {
    let note: Note
    @ObservedObject var deck: DeckModel
    unowned let controller: DeckController
    var edge: DeckEdge = .bottom

    @State private var text = ""
    @State private var saveWork: DispatchWorkItem?
    @State private var savedAt: Date?
    @FocusState private var findFocused: Bool
    @FocusState private var titleFocused: Bool

    private var pal: NoteColor { note.palette }
    private var onRight: Bool { edge == .right }

    var body: some View {
        Group {
            if edge.isBottom {
                // The sheet runs to the screen edge; its own tab trails along as
                // a strip at the far end, the way it does on a side dock.
                VStack(spacing: 0) { gutter; sheet }
            } else if onRight {
                HStack(spacing: 0) { gutter; sheet }
            } else {
                HStack(spacing: 0) { sheet; gutter }
            }
        }
        .background(
            noteShape
                .fill(LinearGradient(colors: [pal.paper, pal.paper.opacity(0.88)],
                                     startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.34), radius: 28,
                        x: edge == .right ? -12 : (edge == .left ? 12 : 0),
                        y: edge.isBottom ? -12 : 12)
        )
        .clipShape(noteShape)
        .overlay(noteShape.strokeBorder(Color.black.opacity(0.07), lineWidth: 0.5))
        .onAppear {
            text = note.body
            savedAt = note.modified
        }
        .onChange(of: text) { _, v in scheduleSave(v) }
        .onChange(of: note.body) { old, incoming in
            if text == old {
                saveWork?.cancel()
                text = incoming
                savedAt = note.modified
            }
        }
        .onChange(of: deck.findQuery) { _, q in
            if q != nil { findFocused = true } else { deck.bridge.focusText() }
        }
        .onDisappear { flush() }
    }

    /// Rounded where it leaves the deck, square where it meets the screen edge.
    private var noteShape: UnevenRoundedRectangle { edgeTabShape(edge: edge, radius: 14) }

    // MARK: The note itself

    private var sheet: some View {
        VStack(spacing: 0) {
            header
            if deck.findQuery != nil { findBar }
            NoteTextView(text: $text, ink: NSColor(pal.ink),
                         bridge: deck.bridge, autofocus: deck.renamingID == nil,
                         fontSize: deck.fontSize)
            if !Photos.names(in: text).isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Photos.names(in: text), id: \.self) { name in
                            Button { NSWorkspace.shared.open(Paths.support.appendingPathComponent(name)) } label: {
                                if let image = Photos.thumbnail(name) {
                                    Image(nsImage: image).resizable().scaledToFit().frame(width: 100, height: 76)
                                } else {
                                    Label("Missing photo", systemImage: "photo").frame(width: 100, height: 76)
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Open photo. Delete its link from the note to remove the attachment.")
                            .accessibilityLabel("Open attached photo")
                        }
                    }.padding(.horizontal, 14)
                }.frame(height: 84)
            }
            footer
        }
    }

    /// The note's own tab, carried along so it reads as growing out of the deck.
    ///
    /// `rotationEffect` is a render transform, not a layout one: a rotated label
    /// still *measures* at its unrotated width, so the tint has to be sized on its
    /// own and the label clipped into it, or the background bleeds across the note.
    private var gutter: some View {
        Group {
            if edge.isBottom {
                Rectangle()
                    .fill(pal.dash.opacity(0.20))
                    .frame(height: DeckGeom.gutterWidth)
                    .overlay {
                        Text(note.displayTitle)
                            .font(Ink.tabFont)
                            .tracking(Ink.tabTracking)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(pal.ink.opacity(0.7))
                            .frame(width: DeckGeom.editorWidth - 44)
                    }
                    .clipped()
                    .overlay(alignment: .bottom) {
                        EdgeLine(horizontal: true)
                            .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                            .foregroundStyle(pal.ink.opacity(0.22))
                            .frame(height: 1)
                    }
            } else {
                Rectangle()
                    .fill(pal.dash.opacity(0.20))
                    .frame(width: DeckGeom.gutterWidth)
                    .overlay {
                        Text(note.displayTitle)
                            .font(Ink.tabFont)
                            .tracking(Ink.tabTracking)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(pal.ink.opacity(0.7))
                            .frame(width: DeckGeom.editorHeight - 44)
                            .rotationEffect(.degrees(onRight ? 90 : -90))
                    }
                    .clipped()
                    .overlay(alignment: onRight ? .trailing : .leading) {
                        EdgeLine()
                            .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                            .foregroundStyle(pal.ink.opacity(0.22))
                            .frame(width: 1)
                    }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if deck.renamingID == note.id {
                TextField("New note", text: $deck.renameDraft)
                    .textFieldStyle(.plain)
                    .font(Ink.titleFont)
                    .foregroundStyle(pal.ink)
                    .focused($titleFocused)
                    .onSubmit { controller.commitRename() }
                    .onAppear { titleFocused = true }
                    .onChange(of: titleFocused) { _, on in
                        if !on { controller.commitRename() }
                    }
            } else {
                Text(note.displayTitle)
                    .font(Ink.titleFont)
                    .foregroundStyle(pal.ink.opacity(0.92))
                    .lineLimit(1)
                    .onTapGesture(count: 2) { controller.beginRename(note.id) }
                    .help("Double-click to rename")
            }
            Spacer(minLength: 6)
            Text(savedAt.map { "Saved · \(Fmt.ago($0))" } ?? "Not saved")
                .font(.system(size: 10))
                .foregroundStyle(pal.ink.opacity(0.42))
            Button { NoteStore.shared.togglePin(id: note.id) } label: {
                Image(systemName: note.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(note.pinned ? 0 : 32))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pal.ink.opacity(note.pinned ? 0.85 : 0.4))
            .help(note.pinned ? "Unpin — ⌘P" : "Pin so it stays open  ⌘P")

            Button { (deck.bridge.textView as? TaskTextView)?.choosePhotos() } label: {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(pal.ink.opacity(0.5))
            .help("Add photos")
            .accessibilityLabel("Add photos")

            Button { deck.bridge.toggleTaskLine() } label: {
                Image(systemName: "checklist")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pal.ink.opacity(0.5))
            .help("Task  ⌘T")
            Button { deck.findQuery = deck.findQuery == nil ? "" : nil } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pal.ink.opacity(0.5))
            .help("Find  ⌘F")
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
    }

    private var findBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10)).foregroundStyle(pal.ink.opacity(0.45))
            TextField("Find in note", text: Binding(
                get: { deck.findQuery ?? "" },
                set: { deck.findQuery = $0; deck.bridge.recount($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(pal.ink)
                .focused($findFocused)
                .onSubmit { deck.bridge.findNext(deck.findQuery ?? "") }
            Text(deck.bridge.matchCount == 0 ? "—" : "\(deck.bridge.matchCount)")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(pal.ink.opacity(0.45))
            Button { deck.bridge.findNext(deck.findQuery ?? "", forward: false) } label: {
                Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
            }.buttonStyle(.plain).foregroundStyle(pal.ink.opacity(0.55))
            Button { deck.bridge.findNext(deck.findQuery ?? "") } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }.buttonStyle(.plain).foregroundStyle(pal.ink.opacity(0.55))
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(pal.dash.opacity(0.12))
    }

    private var footer: some View {
        HStack(spacing: 7) {
            ForEach(Array(NoteColor.all.enumerated()), id: \.offset) { idx, c in
                Button { NoteStore.shared.setColor(id: note.id, color: idx) } label: {
                    Circle()
                        .fill(c.dash)
                        .frame(width: 11, height: 11)
                        .overlay(
                            Circle().strokeBorder(pal.ink.opacity(0.55),
                                                  lineWidth: idx == note.color ? 1.5 : 0)
                                .padding(-2.5)
                        )
                        .padding(2)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(c.name)
            }
            Spacer(minLength: 8)
            footerButton("Archive") {
                NoteStore.shared.setArchived(id: note.id, true)
                controller.collapse()
            }
            footerButton("Delete") {
                NoteStore.shared.delete(id: note.id)
                controller.collapse()
            }
            footerButton("Close") { controller.collapse() }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private func footerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(pal.ink.opacity(0.72))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(pal.ink.opacity(0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Autosave — 250 ms after typing stops

    private func scheduleSave(_ value: String) {
        TaskSync.shared.beginDraft(noteID: note.id)
        saveWork?.cancel()
        let work = DispatchWorkItem {
            NoteStore.shared.updateBody(id: note.id, body: value)
            TaskSync.shared.endDraft(noteID: note.id)
            savedAt = Date()
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func flush() {
        saveWork?.cancel()
        NoteStore.shared.updateBody(id: note.id, body: text)
        TaskSync.shared.endDraft(noteID: note.id)
    }
}
