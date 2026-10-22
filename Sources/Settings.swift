import Foundation
import ServiceManagement

/// Thin UserDefaults wrapper for the handful of togglable preferences.
enum Settings {
    private static let d = UserDefaults.standard

    static var showOverFullScreen: Bool {
        get { d.object(forKey: "showOverFullScreen") as? Bool ?? false }
        set { d.set(newValue, forKey: "showOverFullScreen") }
    }

    /// Which screen edge the deck is docked to. Defaults to the bottom; the old
    /// left-edge boolean migrates, and anything else lands on the bottom edge.
    static var deckEdge: DeckEdge {
        get {
            if let raw = d.string(forKey: "deckEdge"), let edge = DeckEdge(rawValue: raw) {
                return edge
            }
            if d.object(forKey: "deckOnLeftEdge") as? Bool == true { return .left }
            return .bottom
        }
        set { d.set(newValue.rawValue, forKey: "deckEdge") }
    }

    /// Max tabs the fan shows before collapsing the remainder into "+N".
    /// Five keeps every tab at full size instead of squeezing the deck.
    static let fanLimit = 5

    /// Body text size inside a note.
    static let fontSizes: [(name: String, size: Double)] = [
        ("Small", 12), ("Medium", 13.5), ("Large", 15.5), ("Extra Large", 18)
    ]

    static let fontRange: ClosedRange<Double> = 10...30

    static var noteFontSize: Double {
        get {
            let v = d.double(forKey: "noteFontSize")
            return fontRange.contains(v) ? v : 13.5
        }
        set { d.set(min(max(newValue, fontRange.lowerBound), fontRange.upperBound),
                    forKey: "noteFontSize") }
    }

    /// PostScript name of the face note bodies are set in; empty means the
    /// system font. This fork migrates existing installs to bundled IBM Plex
    /// Mono once; choices made through the font menu after that are preserved.
    static var noteFontName: String {
        get {
            if !d.bool(forKey: "didMigrateToPlexBody") {
                d.set(true, forKey: "didMigrateToPlexBody")
                d.set(Ink.plexBody, forKey: "noteFontName")
                return Ink.plexBody
            }
            return d.string(forKey: "noteFontName") ?? Ink.plexBody
        }
        set { d.set(newValue, forKey: "noteFontName") }
    }

    /// Type an opening bracket and its closing half appears after the caret.
    /// On by default, the way ezwrite ships it.
    static var autoPairBrackets: Bool {
        get { d.object(forKey: "autoPairBrackets") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoPairBrackets") }
    }

    /// How long the deck may sit untouched before it tidies itself away.
    static let fanIdleTimeout: TimeInterval = 4
    static let noteIdleTimeout: TimeInterval = 60

    /// Labelled tabs, or bare colour chips that barely touch the screen.
    static var deckStyle: DeckStyle {
        get { DeckStyle(rawValue: d.string(forKey: "deckStyle") ?? "") ?? .tabs }
        set { d.set(newValue.rawValue, forKey: "deckStyle") }
    }

    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Noty: launch-at-login toggle failed — \(error.localizedDescription)")
            }
        }
    }
}
