import Foundation
import SwiftUI
import AppKit
import CryptoKit
import CoreText

// MARK: - Paths

enum Paths {
    static let support: URL = {
        if let directory = ProcessInfo.processInfo.environment["NOTY_SUPPORT_DIR"], !directory.isEmpty {
            let isolated = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
            return isolated
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Noty", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
    static var db: URL { support.appendingPathComponent("notes.db") }
    static var key: URL { support.appendingPathComponent("note.key") }
}

// MARK: - Crypto (AES-GCM for note bodies)

enum Crypto {
    private static let key: SymmetricKey = {
        if let d = try? Data(contentsOf: Paths.key), d.count == 32 {
            return SymmetricKey(data: d)
        }
        let k = SymmetricKey(size: .bits256)
        let d = k.withUnsafeBytes { Data($0) }
        try? d.write(to: Paths.key, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Paths.key.path)
        return k
    }()

    static func seal(_ text: String) -> Data {
        guard let box = try? AES.GCM.seal(Data(text.utf8), using: key),
              let combined = box.combined else { return Data() }
        return combined
    }

    static func open(_ data: Data) -> String {
        guard !data.isEmpty,
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return "" }
        return String(decoding: plain, as: UTF8.self)
    }
}

// MARK: - Palette

struct NoteColor {
    let name: String
    let paper: Color      // note body background
    let dash: Color       // edge dash / colour bar
    let ink: Color        // text colour on paper

    /// One monochrome ramp: every note is a shade of grey, from near-white
    /// paper down to charcoal. The dash — the pill mark, the chip, the colour
    /// bar — is a step darker than its paper so it reads both on the note and
    /// on the dark pill at rest, while the ink stays near-black on every shade.
    static let all: [NoteColor] = [
        NoteColor(name: "Paper",     paper: hex(0xF5F5F5), dash: hex(0xA8A8A8), ink: hex(0x2D2D2D)),
        NoteColor(name: "Mist",      paper: hex(0xEDEDED), dash: hex(0x9E9E9E), ink: hex(0x2A2A2A)),
        NoteColor(name: "Silver",    paper: hex(0xE3E3E3), dash: hex(0x929292), ink: hex(0x272727)),
        NoteColor(name: "Ash",       paper: hex(0xD9D9D9), dash: hex(0x868686), ink: hex(0x242424)),
        NoteColor(name: "Dove",      paper: hex(0xCFCFCF), dash: hex(0x7A7A7A), ink: hex(0x212121)),
        NoteColor(name: "Steel",     paper: hex(0xC2C2C2), dash: hex(0x6E6E6E), ink: hex(0x1E1E1E)),
        NoteColor(name: "Graphite",  paper: hex(0xB4B4B4), dash: hex(0x616161), ink: hex(0x1B1B1B)),
        NoteColor(name: "Charcoal",  paper: hex(0xA2A2A2), dash: hex(0x545454), ink: hex(0x181818)),
    ]

    /// A touch darker at the foot of the sheet, the way paper catches light.
    var paperShade: Color { paper.opacity(1) }

    static func at(_ i: Int) -> NoteColor { all[((i % all.count) + all.count) % all.count] }

    private static func hex(_ v: UInt32) -> Color {
        Color(.sRGB,
              red:   Double((v >> 16) & 0xFF) / 255,
              green: Double((v >> 8) & 0xFF) / 255,
              blue:  Double(v & 0xFF) / 255,
              opacity: 1)
    }
}

// MARK: - Type

/// One entry per face offered for note bodies.
struct NoteFace {
    let name: String          // shown in the menu
    let body: String          // PostScript name, "" for the system font
    let tab: String           // heavier cut used on the tab labels
    let bump: CGFloat         // size nudge so faces look the same size as each other
}

enum Ink {
    /// PostScript names of the faces bundled in Resources/Fonts and registered
    /// at launch (see FontLoader), so the app never depends on the user having
    /// them installed.
    static let plexBody = "IBMPlexMono-Regular"
    static let plexTab = "IBMPlexMono-SemiBold"
    static let departure = "DepartureMono-Regular"

    /// Faces that suit a note. Filtered to what is actually installed, so the
    /// menu never offers something that would silently fall back. The two
    /// bundled monos lead; the hands follow.
    static let allFaces: [NoteFace] = [
        NoteFace(name: "IBM Plex Mono",  body: plexBody,  tab: plexTab,    bump: -1),
        NoteFace(name: "Departure Mono", body: departure, tab: departure, bump: 0),
        NoteFace(name: "System",       body: "",                     tab: "",                     bump: 0),
        NoteFace(name: "Noteworthy",   body: "Noteworthy-Light",     tab: "Noteworthy-Bold",      bump: 1.5),
        NoteFace(name: "Bradley Hand", body: "BradleyHandITCTT-Bold", tab: "BradleyHandITCTT-Bold", bump: 1.5),
        NoteFace(name: "Marker Felt",  body: "MarkerFelt-Thin",      tab: "MarkerFelt-Wide",      bump: 1),
        NoteFace(name: "Chalkboard",   body: "ChalkboardSE-Light",   tab: "ChalkboardSE-Bold",    bump: 0),
        NoteFace(name: "Avenir Next",  body: "AvenirNext-Regular",   tab: "AvenirNext-DemiBold",  bump: 0),
        NoteFace(name: "New York",     body: "NewYork-Regular",      tab: "NewYork-Semibold",     bump: 0),
        NoteFace(name: "Georgia",      body: "Georgia",              tab: "Georgia-Bold",         bump: 0),
        NoteFace(name: "Menlo",        body: "Menlo-Regular",        tab: "Menlo-Bold",           bump: -1),
    ]

    static var faces: [NoteFace] {
        allFaces.filter { $0.body.isEmpty || NSFont(name: $0.body, size: 12) != nil }
    }

    static var face: NoteFace {
        let want = Settings.noteFontName
        return faces.first { $0.body == want } ?? faces[0]
    }

    /// The hand (or face) note bodies are set in.
    static func body(_ size: CGFloat) -> NSFont {
        let f = face
        guard !f.body.isEmpty, let font = NSFont(name: f.body, size: size + f.bump) else {
            return .systemFont(ofSize: size)
        }
        return font
    }

    // Tab labels use the same face a shade bolder, so they hold up turned on
    // their side at this size.
    static let tabSize: CGFloat = 9.5
    static let tabTracking: CGFloat = 0.1

    /// For measuring — layout sizes each tab's strip to the longest label.
    static var tabNSFont: NSFont {
        let f = face
        guard !f.tab.isEmpty, let font = NSFont(name: f.tab, size: tabSize + f.bump) else {
            return .systemFont(ofSize: 9, weight: .semibold)
        }
        return font
    }

    static var tabFont: Font {
        let f = face
        guard !f.tab.isEmpty, NSFont(name: f.tab, size: tabSize) != nil else {
            return .system(size: 9, weight: .semibold)
        }
        return .custom(f.tab, size: tabSize + f.bump)
    }

    /// Chrome title on the open note — always Departure, same as `#` headers.
    static let titleSize: CGFloat = 12.5
    static var titleFont: Font {
        if NSFont(name: departure, size: titleSize) != nil {
            return .custom(departure, size: titleSize)
        }
        return .system(size: titleSize, weight: .semibold)
    }

    /// Header lines (a leading #, see `Headers`) are always set in Departure
    /// Mono whatever the body face is, a step larger per level, so structure
    /// reads at a glance.
    static func headerFont(level: Int, size: CGFloat) -> NSFont {
        let scale: CGFloat = level == 1 ? 1.45 : (level == 2 ? 1.28 : 1.12)
        if let font = NSFont(name: departure, size: size * scale) { return font }
        return .systemFont(ofSize: size * scale, weight: .bold)
    }
}

// MARK: - Bundled fonts

/// Registers the faces shipped in Resources/Fonts with this process, so IBM
/// Plex Mono and Departure Mono render even on a machine without them
/// installed. Process scope: nothing leaks into the system font list.
enum FontLoader {
    static func registerBundled(bundle: Bundle = .main) {
        guard let dir = bundle.resourceURL?.appendingPathComponent("Fonts", isDirectory: true),
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for url in urls where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                NSLog("Noty: could not register bundled font \(url.lastPathComponent)")
            }
        }
    }
}

// MARK: - Model

struct Note: Identifiable, Hashable {
    var id: String = UUID().uuidString
    var title: String = ""
    var body: String = ""
    var color: Int = 0
    var created: Date = Date()
    var modified: Date = Date()
    var archived: Bool = false
    var pinned: Bool = false
    var titleCustom: Bool = false
    var order: Double = 0

    var palette: NoteColor { NoteColor.at(color) }

    /// Double-click rename. A blank value drops back to the first line of the body.
    mutating func applyTypedTitle(_ typed: String) {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            titleCustom = false
            title = Self.derivedTitle(from: body)
        } else {
            titleCustom = true
            title = t
        }
    }

    /// Body edits refresh the tab label only when the title was never set by hand.
    mutating func applyBody(_ newBody: String) {
        body = newBody
        if !titleCustom { title = Self.derivedTitle(from: newBody) }
    }

    /// Title shown in the fan / lists, derived from the first non-empty line.
    static func derivedTitle(from body: String) -> String {
        let line = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        var clean = line.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
        clean = Tasks.stripped(clean)
        if clean.isEmpty { return "" }
        return clean.count > 60 ? String(clean.prefix(60)) + "…" : clean
    }

    var displayTitle: String { title.isEmpty ? "New note" : title }

    /// Completed / total, or nil when the note holds no tasks.
    var taskProgress: (done: Int, total: Int)? {
        var done = 0, total = 0
        for line in body.split(whereSeparator: \.isNewline) {
            switch Tasks.marker(of: line) {
            case Tasks.done: done += 1; total += 1
            case Tasks.open: total += 1
            default: break
            }
        }
        return total > 0 ? (done, total) : nil
    }

    /// Second line onwards, collapsed — used as list subtitle.
    var preview: String {
        let lines = body.split(whereSeparator: \.isNewline).map(String.init)
        let rest = lines.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return rest.count > 120 ? String(rest.prefix(120)) + "…" : rest
    }
}

// MARK: - Headers

/// Lines that start with one to six '#' — followed by a space or nothing, the
/// way Markdown writes them — are headers. The hashes stay in the text (a note
/// is plain text, and exports as Markdown), but the line is drawn in the header
/// face, a step larger per level. Typing `#` at the start of a line is the
/// shortcut: the line becomes a header as you type.
enum Headers {
    static let maxLevel = 6

    static func level(of line: some StringProtocol) -> Int? {
        var n = 0
        for ch in line {
            guard ch == "#" else { break }
            n += 1
        }
        guard (1...maxLevel).contains(n) else { return nil }
        let after = line.dropFirst(n)
        return after.isEmpty || after.first == " " ? n : nil
    }
}

// MARK: - Tasks

/// Checkbox tasks are stored inline in the note body as ☐ / ☑ line prefixes, so a
/// note is still plain text and exports cleanly to Markdown task syntax.
enum Tasks {
    static let open: Character = "\u{2610}"    // ☐
    static let done: Character = "\u{2611}"    // ☑
    static let openPrefix = "\u{2610} "
    static let donePrefix = "\u{2611} "

    static func marker(of line: some StringProtocol) -> Character? {
        guard let f = line.first, f == open || f == done else { return nil }
        return f
    }

    static func isTask(_ line: some StringProtocol) -> Bool { marker(of: line) != nil }

    /// Strip the marker for display in lists and titles.
    static func stripped(_ line: some StringProtocol) -> String {
        guard isTask(line) else { return String(line) }
        return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    /// Markdown task syntax in, ☐/☑ out. `(?m)` so a task on any line is
    /// read back, not only the first — without it `^` matches just the start
    /// of the string and the rest of the list imports as prose.
    static func fromMarkdown(_ text: String) -> String {
        text.replacingOccurrences(of: "(?m)^(\\s*)[-*]\\s+\\[[ ]\\]\\s+",
                                  with: "$1" + openPrefix,
                                  options: [.regularExpression])
            .replacingOccurrences(of: "(?m)^(\\s*)[-*]\\s+\\[[xX]\\]\\s+",
                                  with: "$1" + donePrefix,
                                  options: [.regularExpression])
    }

    /// ☐/☑ out, Markdown task syntax in.
    static func toMarkdown(_ text: String) -> String {
        text.replacingOccurrences(of: openPrefix, with: "- [ ] ")
            .replacingOccurrences(of: donePrefix, with: "- [x] ")
    }

    // MARK: The `list` keyword

    /// Typing a line that says just "list" (either case) turns the note into a
    /// tasklist: every other non-empty line gains a checkbox. When the note
    /// already is one long tasklist the same keyword strips the checkboxes back
    /// off. The keyword line itself is consumed.
    static let listKeyword = "list"

    /// Pure transform — nil when the caret is not sitting on a `list` line.
    /// Returns the rewritten note and a caret offset to land on.
    static func listTransform(text: String, caret: Int) -> (text: String, caret: Int)? {
        guard !text.isEmpty, !text.unicodeScalars.contains("\r") else { return nil }
        let ns = text as NSString
        let c = min(max(0, caret), ns.length)
        let line = ns.lineRange(for: NSRange(location: c, length: 0))
        let onLine = ns.substring(with: line)
        guard onLine.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(listKeyword) == .orderedSame else { return nil }

        let parts = text.components(separatedBy: "\n")
        guard !parts.isEmpty else { return nil }
        let trigger = min(text.prefix(c).filter { $0 == "\n" }.count, parts.count - 1)
        var rest = parts
        rest.remove(at: trigger)

        let nonEmpty = rest.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let alreadyList = !nonEmpty.isEmpty && nonEmpty.allSatisfy { isTask($0) }

        let out: [String]
        if alreadyList {
            out = rest.map { isTask($0) ? stripped($0) : $0 }
        } else if nonEmpty.isEmpty {
            out = [openPrefix]                     // fresh note: one task, ready to type
        } else {
            out = rest.map { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.isEmpty || isTask(t) ? t : openPrefix + t
            }
        }

        let joined = out.joined(separator: "\n")
        // Land at the end of the first non-empty line so typing carries straight
        // on; at the end of the note when there is none.
        var offset = 0
        var placed = (joined as NSString).length
        for line in out {
            let len = (line as NSString).length
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                placed = offset + len
                break
            }
            offset += len + 1
        }
        return (joined, placed)
    }
}

// MARK: - Lists

/// Plain-text lists that populate themselves as you type, the way ezwrite's do:
/// a line opening with a bullet (`-`, `*`, `>`) or a numbered item (`1.` / `1/`)
/// carries its prefix onto the next line when Return is pressed — numbers
/// counting up as the list grows — and a Return on an emptied item ends the
/// list instead. A split mid-list renumbers the lines after it so the count
/// stays true.
enum Lists {

    /// One list line, parsed.
    struct Item {
        let indent: String          // leading whitespace, kept on both halves of a split
        let prefix: String          // indent + marker + one space, exactly as typed
        let nextPrefix: String      // the prefix the following line carries
        let body: String            // everything after the prefix
        let number: Int?            // the item's own number, when numbered
        let separator: Character?   // "." or "/", when numbered

        /// A Return on an item with nothing typed after the marker ends the list.
        var isBlank: Bool { body.trimmingCharacters(in: .whitespaces).isEmpty }
        var isNumbered: Bool { number != nil }

        /// The prefix rewritten to carry `n`.
        func prefix(number n: Int) -> String {
            indent + "\(n)" + (separator.map(String.init) ?? "") + " "
        }
    }

    /// Parses a line into a list item, or nil when it opens as ordinary prose.
    /// A marker needs one space after it, so `1.5` and dashes inside sentences
    /// stay prose.
    static func item(_ line: String) -> Item? {
        var i = line.startIndex
        while i < line.endIndex, line[i] == " " || line[i] == "\t" {
            i = line.index(after: i)
        }
        guard i < line.endIndex else { return nil }
        let indent = String(line[..<i])
        let marker = line[i]
        let afterMarker = line.index(after: i)

        if marker == "-" || marker == "*" || marker == ">" {
            guard afterMarker < line.endIndex, line[afterMarker] == " " else { return nil }
            return Item(indent: indent,
                        prefix: String(line[...afterMarker]),
                        nextPrefix: indent + String(marker) + " ",
                        body: String(line[line.index(after: afterMarker)...]),
                        number: nil, separator: nil)
        }

        guard marker.isASCII, marker.isNumber else { return nil }
        var j = afterMarker
        while j < line.endIndex, line[j].isASCII, line[j].isNumber {
            j = line.index(after: j)
        }
        guard j < line.endIndex, line[j] == "." || line[j] == "/" else { return nil }
        let afterMark = line.index(after: j)
        guard afterMark < line.endIndex, line[afterMark] == " " else { return nil }
        guard let n = Int(line[i..<j]) else { return nil }   // an absurd digit run is prose
        return Item(indent: indent,
                    prefix: String(line[...afterMark]),
                    nextPrefix: indent + "\(n + 1)" + String(line[j]) + " ",
                    body: String(line[line.index(after: afterMark)...]),
                    number: n, separator: line[j])
    }

    /// Renumbers the numbered block around `anchor` so the count stays true
    /// after a line lands mid-list: walking out from the anchor, every run of
    /// numbered lines counts on from the block's first number at each indent
    /// depth. Bullets and prose break a block and are left untouched.
    static func renumbered(_ lines: [String], around anchor: Int) -> [String] {
        guard lines.indices.contains(anchor), item(lines[anchor])?.isNumbered == true else {
            return lines
        }
        var start = anchor
        while start > 0, item(lines[start - 1])?.isNumbered == true { start -= 1 }
        var end = anchor
        while end < lines.count - 1, item(lines[end + 1])?.isNumbered == true { end += 1 }

        var out = lines
        var counters: [String: Int] = [:]   // indent -> last number written at that depth
        var openIndents: [String] = []      // depths in play, outermost first
        for i in start...end {
            guard let it = item(out[i]), it.isNumbered else { continue }
            while let deepest = openIndents.last, deepest.count > it.indent.count {
                counters[deepest] = nil
                openIndents.removeLast()
            }
            if counters[it.indent] == nil {
                openIndents.append(it.indent)
                counters[it.indent] = (it.number ?? 1) - 1   // a block's first number anchors it
            }
            let next = counters[it.indent]! + 1
            counters[it.indent] = next
            out[i] = it.prefix(number: next) + it.body
        }
        return out
    }

    // MARK: Bracket pairing

    /// The closing half an opening bracket types along with, or nil for
    /// characters that stand alone.
    static func closingBracket(for typed: Character) -> Character? {
        switch typed {
        case "(": return ")"
        case "[": return "]"
        case "{": return "}"
        case "\"": return "\""
        default: return nil
        }
    }

    /// True when an auto-pair would land inside Markdown image syntax — a `!`
    /// right behind the caret asking for `[alt]`, or a `(` after the alt of one.
    static func breaksImageSyntax(beforeCaret text: String, typed: Character) -> Bool {
        switch typed {
        case "[": return text.hasSuffix("!")
        case "(": return text.range(of: "!\\[[^\\]]*\\]$", options: .regularExpression) != nil
        default: return false
        }
    }
}

// MARK: - Formatting

enum Fmt {
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    static func ago(_ d: Date) -> String {
        if Date().timeIntervalSince(d) < 60 { return "just now" }
        return relative.localizedString(for: d, relativeTo: Date())
    }
}
